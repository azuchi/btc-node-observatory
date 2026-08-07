# frozen_string_literal: true

require 'yaml'
require 'json'
require 'digest'

module Observatory
  # Loads the YAML config file and manages defaults.
  # Derives params_hash from the parameters that affect the measurement
  # methodology, so methodology changes are machine-detectable per snapshot.
  class Config
    DEFAULTS = {
      'db_path' => 'db/observatory.sqlite3',
      'user_agent' => Observatory::USER_AGENT,
      'protocol_version' => 70016,
      'clearnet' => {
        'interval_sec' => 900,          # every 15 min (keep in sync with the systemd timer)
        'concurrency' => 500,
        'connect_timeout' => 5,
        'handshake_timeout' => 5
      },
      'onion' => {
        'interval_sec' => 86_400,       # once a day
        'concurrency' => 50,
        'connect_timeout' => 30,
        'handshake_timeout' => 30,
        'socks5_host' => '127.0.0.1',
        # One Tor daemon saturates its circuit queue well before the candidate
        # set is exhausted, so capacity comes from running several of them.
        # The count is part of the methodology (see params_hash).
        'socks5_ports' => [9050]
      },
      # Cap on how many addresses ONE round probes (see Database#candidates).
      # It does not bound the stored address set, which is never pruned.
      'candidate_limit' => 100_000,
      # Where candidate addresses come from. Part of the methodology, so it is
      # covered by params_hash: widening it changes what "reachable" is measured
      # against. 'addrman' = the observer node's address book, 'harvest' =
      # recursive getaddr discovery (see the harvest section below).
      'candidate_sources' => ['addrman'],
      'backoff' => {
        'fail_streak_threshold' => 30,  # exponential backoff beyond this many consecutive failures
        'base_interval_sec' => 900,
        'max_exponent' => 10            # 900s * 2^10 ≈ 10.6 days max interval
      },
      'export' => {
        'top_n' => 20,                  # top-N entries for by_country/by_asn/by_user_agent in daily JSON
        'out_dir' => '../btc-node-data'
      },
      'retention' => {
        'keep_days' => 60               # `prune` deletes observations older than this (archive first!)
      },
      # Recursive getaddr discovery (`harvest`). Collects candidate addresses only;
      # it never measures reachability, so it does not affect params_hash.
      'harvest' => {
        'concurrency' => 30,            # far lighter than a measurement round (home-network friendly)
        'connect_timeout' => 5,
        'getaddr_timeout' => 25,        # peers reply within seconds, then keep the connection open
        'peers_per_round' => 200,
        'max_rounds' => 5,
        'max_addrs_per_peer' => 5000
      },
      'bitcoind' => nil,                # { 'rpc_url' =>, 'rpc_user' =>, 'rpc_password' => } or { 'cookie_path' => }
      'geoip' => nil                    # { 'country_db' =>, 'asn_db' => }
    }.freeze

    attr_reader :raw, :base_dir

    def self.load(path = nil)
      path ||= ENV['OBSERVATORY_CONFIG'] || 'config/observatory.yml'
      raw = File.exist?(path) ? YAML.safe_load_file(path) || {} : {}
      new(raw, base_dir: File.expand_path('..', File.dirname(File.expand_path(path))))
    end

    def initialize(raw = {}, base_dir: Dir.pwd)
      @raw = deep_merge(DEFAULTS, raw)
      @base_dir = base_dir
    end

    def db_path = expand(@raw['db_path'])
    def user_agent = @raw['user_agent']
    def protocol_version = @raw['protocol_version']
    def clearnet = @raw['clearnet']
    def onion = @raw['onion']
    def candidate_limit = @raw['candidate_limit']
    def candidate_sources = Array(@raw['candidate_sources']).map(&:to_s).sort
    def backoff = @raw['backoff']
    def export = @raw['export']
    def retention = @raw['retention']
    def harvest = @raw['harvest']
    def bitcoind = @raw['bitcoind']
    def geoip = @raw['geoip']

    def network_params(network_class)
      @raw[network_class.to_s] or raise ArgumentError, "unknown network_class: #{network_class}"
    end

    # Hash (first 8 hex chars) over the parameters that define the measurement
    # methodology only. Changing user_agent or storage paths does not change it.
    #
    # Adding or renaming a key below rehashes EVERY network, including ones the
    # new key does not apply to (2026-07-31: adding socks5_instances moved the
    # clearnet hash even though its value is 0 there). Consumers read a changed
    # hash as a break in the series, so whenever this key set changes, record it
    # in the data repository's CHANGELOG as a definition change.
    def params_hash(network_class)
      np = network_params(network_class)
      canonical = {
        'network_class' => network_class.to_s,
        'interval_sec' => np['interval_sec'],
        'concurrency' => np['concurrency'],
        'connect_timeout' => np['connect_timeout'],
        'handshake_timeout' => np['handshake_timeout'],
        'candidate_limit' => candidate_limit,
        'candidate_sources' => candidate_sources,
        # onion throughput is bounded by how many Tor daemons back the probes
        'socks5_instances' => socks5_instances(np),
        'fail_streak_threshold' => backoff['fail_streak_threshold'],
        'base_interval_sec' => backoff['base_interval_sec'],
        'max_exponent' => backoff['max_exponent'],
        'protocol_version' => protocol_version
      }
      Digest::SHA256.hexdigest(JSON.generate(canonical))[0, 8]
    end

    private

    # 0 for direct (clearnet) probing, otherwise the number of SOCKS proxies.
    def socks5_instances(network_params)
      ports = network_params['socks5_ports'] || [network_params['socks5_port']].compact
      ports.size
    end

    def expand(path)
      File.absolute_path?(path) ? path : File.join(@base_dir, path)
    end

    def deep_merge(base, other)
      base.merge(other) do |_key, old, new|
        old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
      end
    end
  end
end
