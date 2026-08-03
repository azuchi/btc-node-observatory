#!/usr/bin/env ruby
# frozen_string_literal: true

# One-off diagnostic: are onion timeouts caused by our Tor capacity, or by the
# addresses being dead?
#
# A regular round runs every slot at the timeout limit (duration is exactly
# candidates * timeout / concurrency), so a saturated crawl cannot tell the two
# apart. This re-probes a random sample of addresses that timed out in the most
# recent onion snapshot, under no contention: low concurrency, generous timeout.
#
#   many successes -> capacity-bound; more Tor daemons would raise the count
#   few successes  -> the addresses are simply gone; more capacity buys nothing
#
# Results are printed only — nothing is written to the database.
#
# Usage: bundle exec ruby scripts/onion_recheck.rb [SAMPLE] [CONCURRENCY] [TIMEOUT]

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
require 'observatory'
require 'async'
require 'async/barrier'
require 'async/semaphore'

sample = (ARGV[0] || 500).to_i
concurrency = (ARGV[1] || 10).to_i
timeout = (ARGV[2] || 120).to_i

config = Observatory::Config.load(ENV.fetch('OBSERVATORY_CONFIG', nil))
db = Observatory::Database.new(config.db_path)

latest = db.db.get_first_value("SELECT MAX(id) FROM snapshots WHERE network_class = 'onion'")
abort 'no onion snapshot yet' unless latest

rows = db.db.execute(<<~SQL, [latest, sample])
  SELECT n.address, n.port FROM observations o
  JOIN nodes n ON n.id = o.node_id
  WHERE o.snapshot_id = ? AND o.fail_reason = 'timeout'
  ORDER BY RANDOM() LIMIT ?
SQL
abort 'no timed-out addresses in the latest snapshot' if rows.empty?

onion = config.onion
ports = onion['socks5_ports'] || [onion['socks5_port']].compact
proxies = ports.map { |p| [onion['socks5_host'], p] }

warn "re-probing #{rows.size} timed-out addresses from snapshot #{latest}"
warn "  concurrency=#{concurrency} timeout=#{timeout}s proxies=#{proxies.size}"

prober = Observatory::Prober.new(user_agent: config.user_agent,
                                 protocol_version: config.protocol_version,
                                 connect_timeout: timeout,
                                 handshake_timeout: timeout,
                                 socks5_proxies: proxies)

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
counts = Hash.new(0)
Sync do
  semaphore = Async::Semaphore.new(concurrency)
  barrier = Async::Barrier.new(parent: semaphore)
  rows.each do |(address, port)|
    barrier.async do
      result = prober.probe(address, port)
      counts[result.success ? 'success' : result.fail_reason] += 1
    end
  end
  barrier.wait
ensure
  barrier&.stop
end
elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round

success = counts['success']
puts JSON.generate({ snapshot_id: latest, sample: rows.size, concurrency: concurrency,
                     timeout_sec: timeout, elapsed_sec: elapsed,
                     success_rate: (success.to_f / rows.size).round(4), breakdown: counts })
