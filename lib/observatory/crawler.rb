# frozen_string_literal: true

require 'async'
require 'async/barrier'
require 'async/semaphore'
require 'time'

module Observatory
  # One snapshot = candidate selection → concurrent probes → bulk write.
  class Crawler
    def initialize(config, database, logger: nil)
      @config = config
      @db = database
      @logger = logger
    end

    # @param network_class [:clearnet, :onion]
    # @return [Hash] snapshot summary
    def run(network_class)
      params = @config.network_params(network_class)
      backoff = @config.backoff
      now = Time.now.to_i

      preflight_socks!(params) if network_class.to_s == 'onion'

      candidates = @db.candidates(network_class,
                                  now: now,
                                  limit: @config.candidate_limit,
                                  threshold: backoff['fail_streak_threshold'],
                                  base_interval: backoff['base_interval_sec'],
                                  max_exponent: backoff['max_exponent'])
      log "#{network_class}: #{candidates.size} candidates"

      snapshot_id = @db.create_snapshot(
        network_class: network_class,
        started_at: now,
        candidates: candidates.size,
        crawler_ver: Observatory::VERSION,
        params_hash: @config.params_hash(network_class)
      )

      prober = build_prober(network_class, params)
      results = probe_all(prober, candidates, params['concurrency'])
      finished_at = Time.now.to_i
      @db.record_results(snapshot_id, results, finished_at: finished_at)

      reachable = results.count { |r| r[:success] }
      union = @db.union_24h(network_class, at: finished_at)
      summary = {
        snapshot_id: snapshot_id,
        network_class: network_class.to_s,
        candidates: candidates.size,
        instantaneous: reachable,
        union_24h: union,
        elapsed_sec: finished_at - now
      }
      log summary.inspect
      summary
    end

    private

    # A dead SOCKS proxy would record an all-zero snapshot ("0 onion nodes")
    # that is indistinguishable from a real measurement and would pollute the
    # series. Every declared proxy must answer: running with fewer Tor daemons
    # than configured would silently cut measurement capacity.
    def preflight_socks!(params)
      socks5_proxies(params).each do |(host, port)|
        ::Socket.tcp(host, port, connect_timeout: 5).close
      rescue SystemCallError, IO::TimeoutError => e
        raise "SOCKS5 proxy #{host}:#{port} is not reachable (#{e.class}); " \
              'aborting the onion snapshot (are all dedicated Tor daemons running?)'
      end
    end

    # Accepts both socks5_ports (list) and the older single socks5_port.
    def socks5_proxies(params)
      host = params['socks5_host']
      ports = params['socks5_ports'] || [params['socks5_port']].compact
      ports.map { |port| [host, port] }
    end

    def build_prober(network_class, params)
      opts = {
        user_agent: @config.user_agent,
        protocol_version: @config.protocol_version,
        connect_timeout: params['connect_timeout'],
        handshake_timeout: params['handshake_timeout']
      }
      opts[:socks5_proxies] = socks5_proxies(params) if network_class.to_s == 'onion'
      Prober.new(**opts)
    end

    def probe_all(prober, candidates, concurrency)
      results = []
      Sync do
        semaphore = Async::Semaphore.new(concurrency)
        barrier = Async::Barrier.new(parent: semaphore)
        candidates.each do |(node_id, address, port, _network)|
          barrier.async do
            r = prober.probe(address, port)
            results << { node_id: node_id, success: r.success, fail_reason: r.fail_reason,
                         protocol_version: r.protocol_version, user_agent: r.user_agent,
                         services: r.services, start_height: r.start_height, rtt_ms: r.rtt_ms }
          end
        end
        barrier.wait
      ensure
        barrier&.stop
      end
      results
    end

    def log(msg)
      @logger&.info(msg) || warn("[#{Time.now.utc.iso8601}] #{msg}")
    end
  end
end
