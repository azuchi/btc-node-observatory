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

    def build_prober(network_class, params)
      opts = {
        user_agent: @config.user_agent,
        protocol_version: @config.protocol_version,
        connect_timeout: params['connect_timeout'],
        handshake_timeout: params['handshake_timeout']
      }
      if network_class.to_s == 'onion'
        opts[:socks5_host] = params['socks5_host']
        opts[:socks5_port] = params['socks5_port']
      end
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
