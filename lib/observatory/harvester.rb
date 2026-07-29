# frozen_string_literal: true

require 'async'
require 'async/barrier'
require 'async/semaphore'
require 'set'
require 'json'
require 'bitcoin/message/network_addr'
require 'bitcoin/message/addr'
require 'bitcoin/message/addr_v2'
require 'bitcoin/message/get_addr'
require 'bitcoin/message/send_addr_v2'

module Observatory
  # Recursive address discovery (getaddr crawl).
  #
  # Complements the observer node's addrman, which is capped at roughly 82k
  # entries: ask reachable peers for their own address books and accumulate the
  # union. This only COLLECTS candidate addresses — reachability is measured
  # separately by Crawler, so a harvest run never produces observations.
  #
  # Intended to run somewhere other than the measurement host (e.g. a machine at
  # home): it is far lighter than a measurement round (tens of concurrent
  # connections, once a day) and its output is fed to `import --file`.
  class Harvester
    Result = Struct.new(:addresses, :asked, :answered, :rounds, keyword_init: true)

    # Maps BIP-155 network ids to the network names used by the nodes table.
    NET_NAMES = {
      Bitcoin::Message::NETWORK_ID[:ipv4] => 'ipv4',
      Bitcoin::Message::NETWORK_ID[:ipv6] => 'ipv6',
      Bitcoin::Message::NETWORK_ID[:tor_v2] => 'onion',
      Bitcoin::Message::NETWORK_ID[:tor_v3] => 'onion',
      Bitcoin::Message::NETWORK_ID[:i2p] => 'i2p',
      Bitcoin::Message::NETWORK_ID[:cjdns] => 'cjdns'
    }.freeze

    # Networks we can ask directly (no SOCKS proxy in this tool).
    ASKABLE = %w[ipv4 ipv6].freeze

    def initialize(config, logger: nil)
      @config = config
      @params = config.harvest
      @logger = logger
    end

    # @param seeds [Array<Array>] [[address, port, network], ...] to start from
    # @return [Result]
    def run(seeds)
      known = {}   # "addr:port" => entry hash
      asked = Set.new
      frontier = seeds.select { |(_a, _p, net)| ASKABLE.include?(net) }
      total_answered = 0
      round = 0

      while round < @params['max_rounds'] && !frontier.empty?
        round += 1
        batch = frontier.first(@params['peers_per_round'])
        log "harvest round #{round}: asking #{batch.size} peers (known=#{known.size})"
        batch.each { |(a, p, _n)| asked << "#{a}:#{p}" }

        answers = ask_all(batch)
        total_answered += answers.count { |a| a[:ok] }
        fresh = merge_addresses(known, answers)
        log "  +#{fresh.size} new addresses (total #{known.size})"

        # Next frontier: newly learned, askable, not yet asked
        frontier = fresh
                   .select { |e| ASKABLE.include?(e['network']) }
                   .reject { |e| asked.include?("#{e['address']}:#{e['port']}") }
                   .map { |e| [e['address'], e['port'], e['network']] }
                   .shuffle
      end

      Result.new(addresses: known.values, asked: asked.size,
                 answered: total_answered, rounds: round)
    end

    # Writes the harvested set in the format accepted by `import --file`.
    def write(result, path)
      File.write(path, JSON.generate(result.addresses) + "\n")
      path
    end

    private

    def ask_all(peers)
      results = []
      Sync do
        semaphore = Async::Semaphore.new(@params['concurrency'])
        barrier = Async::Barrier.new(parent: semaphore)
        peers.each do |(address, port, _network)|
          barrier.async do
            results << ask(address, port)
          end
        end
        barrier.wait
      ensure
        barrier&.stop
      end
      results
    end

    def ask(address, port, task: Async::Task.current)
      sock = task.with_timeout(@params['connect_timeout']) { ::Socket.tcp(address, port) }
      begin
        addrs = collect_addrs(sock, task)
        { ok: !addrs.empty?, addrs: addrs }
      ensure
        sock.close rescue nil
      end
    rescue StandardError
      # Unreachable or uncooperative peers are simply skipped: this tool
      # collects candidates, it does not measure reachability.
      { ok: false, addrs: [] }
    end

    # Handshake, ask for the peer's address book, and read replies until the
    # peer stops sending. Peers keep the connection open after answering, so
    # hitting the timeout is the normal exit — whatever arrived by then is kept.
    def collect_addrs(sock, task)
      prober = Prober.new(user_agent: @config.user_agent,
                          protocol_version: @config.protocol_version,
                          connect_timeout: @params['connect_timeout'],
                          handshake_timeout: @params['getaddr_timeout'])
      collected = []
      begin
        task.with_timeout(@params['getaddr_timeout']) do
          # announce_addrv2 makes BIP-155 peers include onion/i2p/cjdns entries
          prober.send(:handshake, sock, announce_addrv2: true)
          sock.write(Bitcoin::Message::GetAddr.new.to_pkt)

          while collected.size < @params['max_addrs_per_peer']
            command, payload = prober.send(:read_message, sock)
            case command
            when 'addr'
              collected.concat(Bitcoin::Message::Addr.parse_from_payload(payload).addrs)
            when 'addrv2'
              collected.concat(Bitcoin::Message::AddrV2.parse_from_payload(payload).addrs)
            when 'ping'
              # Peers disconnect unanswered pings, and getaddr replies take
              # tens of seconds to arrive, so keep the connection alive
              sock.write(Bitcoin::Message::Pong.new(payload.unpack1('Q')).to_pkt) rescue nil
            end
          end
        end
      rescue Async::TimeoutError, IO::TimeoutError, StandardError
        # Timeout is the expected end of a successful exchange; protocol errors
        # mid-stream still leave the addresses received so far usable.
      end
      collected
    end

    # @return [Array<Hash>] entries new in this batch
    def merge_addresses(known, answers)
      fresh = []
      answers.each do |answer|
        answer[:addrs].each do |na|
          entry = to_entry(na)
          next unless entry

          key = "#{entry['address']}:#{entry['port']}"
          next if known.key?(key)

          known[key] = entry
          fresh << entry
        end
      end
      fresh
    end

    def to_entry(network_addr)
      network = NET_NAMES[network_addr.net]
      return nil unless network

      # addr_string returns an IPAddr for ipv4 and a String for the other networks
      address = network_addr.addr_string.to_s
      return nil if address.empty?
      return nil if address.end_with?('.internal') # BIP-155 internal addresses

      { 'address' => address, 'port' => network_addr.port,
        'network' => network, 'time' => network_addr.time }
    rescue StandardError
      nil # malformed address entries are dropped
    end

    def log(msg)
      @logger&.info(msg) || warn("[#{Time.now.utc.iso8601}] #{msg}")
    end
  end
end
