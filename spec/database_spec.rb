# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Observatory::Database do
  let(:db) { build_db }
  let(:now) { 1_785_000_000 }

  def add_node(address, network: 'ipv4', port: 8333, seen_at: now)
    db.upsert_node(address: address, port: port, network: network, seen_at: seen_at)
    db.db.get_first_value('SELECT id FROM nodes WHERE address = ? AND port = ?', [address, port])
  end

  def select_candidates(limit: 100_000, at: now)
    db.candidates(:clearnet, now: at, limit: limit, threshold: 30, base_interval: 900, max_exponent: 10)
  end

  it 'upsert keeps first_seen and only advances last_seen' do
    add_node('1.1.1.1', seen_at: 100)
    add_node('1.1.1.1', seen_at: 200)
    first_seen, last_seen = db.db.execute('SELECT first_seen, last_seen FROM nodes').first
    expect(first_seen).to eq(100)
    expect(last_seen).to eq(200)
  end

  describe '#candidates' do
    it 'returns only ipv4/ipv6 for clearnet and only onion for onion' do
      add_node('1.1.1.1', network: 'ipv4')
      add_node('::1', network: 'ipv6')
      add_node('abc.onion', network: 'onion')
      add_node('xyz.i2p', network: 'i2p') # recorded only, never probed
      expect(select_candidates.map { |c| c[3] }).to contain_exactly('ipv4', 'ipv6')
      onion = db.candidates(:onion, now: now, limit: 100, threshold: 30, base_interval: 900, max_exponent: 10)
      expect(onion.map { |c| c[1] }).to eq(['abc.onion'])
    end

    it 'is always eligible while the fail streak is below the threshold' do
      id = add_node('1.1.1.1')
      db.db.execute('UPDATE nodes SET fail_streak = 29, last_seen = ? WHERE id = ?', [now, id])
      expect(select_candidates.map(&:first)).to include(id)
    end

    it 'applies exponential backoff at/above the threshold (excluded until the interval passes, then returns)' do
      id = add_node('1.1.1.1')
      # streak 32 → wait 900 * 2^2 = 3600 s
      db.db.execute('UPDATE nodes SET fail_streak = 32, last_probed = ? WHERE id = ?', [now, id])
      expect(select_candidates(at: now + 3599).map(&:first)).not_to include(id)
      expect(select_candidates(at: now + 3600).map(&:first)).to include(id)
    end

    # The 2026-08-07 bug: backoff keyed off last_seen, which the addrman import
    # rewrites to `now` every 15 min, so an address still in the addrman never
    # became eligible again once it crossed the threshold.
    it 'is not delayed by re-imports between probes' do
      id = add_node('1.1.1.1')
      db.db.execute('UPDATE nodes SET fail_streak = 32, last_probed = ? WHERE id = ?', [now, id])
      # the addrman keeps reporting it, right up to the moment it comes due
      (1..4).each { |i| add_node('1.1.1.1', seen_at: now + (i * 900)) }
      expect(select_candidates(at: now + 3600).map(&:first)).to include(id)
    end
    it 'caps the set via candidate_limit, preferring nodes with a success record' do
      stale = add_node('9.9.9.9')
      fresh = add_node('1.1.1.1')
      db.db.execute('UPDATE nodes SET last_success = ? WHERE id = ?', [now - 60, fresh])
      selected = select_candidates(limit: 1)
      expect(selected.size).to eq(1)
      expect(selected.first.first).to eq(fresh)
      expect(db.node_count).to eq(2) # never removed, records are kept
      _ = stale
    end
  end

  describe 'write contention' do
    # 2026-08-09: a 3h52m onion round was discarded because its write waited out
    # the busy timeout while the clearnet round and the address import held the
    # lock back to back for five minutes.
    it 'retries a write that lost the race for the lock, without duplicating it' do
      ok = add_node('1.1.1.1')
      ng = add_node('2.2.2.2')
      sid = db.create_snapshot(network_class: :clearnet, started_at: now, candidates: 2,
                               crawler_ver: 'test', params_hash: 'deadbeef')
      results = [{ node_id: ok, success: true }, { node_id: ng, success: false, fail_reason: 'timeout' }]

      calls = 0
      allow(db).to receive(:write_results).and_wrap_original do |orig, *args, **kwargs|
        calls += 1
        raise SQLite3::BusyException, 'database is locked' if calls == 1

        orig.call(*args, **kwargs)
      end

      expect { db.record_results(sid, results, finished_at: now + 10) }.not_to raise_error
      expect(calls).to eq(2)
      # the failed attempt rolled back, so the retry is the only writer
      expect(db.db.get_first_value('SELECT COUNT(*) FROM observations WHERE snapshot_id = ?', [sid])).to eq(2)
      expect(db.db.get_first_value('SELECT fail_streak FROM nodes WHERE id = ?', [ng])).to eq(1)
    end

    it 'gives up after the retry budget rather than looping forever' do
      allow(db).to receive(:write_results).and_raise(SQLite3::BusyException, 'database is locked')
      sid = db.create_snapshot(network_class: :clearnet, started_at: now, candidates: 0,
                               crawler_ver: 'test', params_hash: 'deadbeef')
      expect { db.record_results(sid, [], finished_at: now + 10) }.to raise_error(SQLite3::BusyException)
    end
  end

  describe '#record_results / #union_24h' do
    it 'stamps last_probed on both success and failure' do
      ok = add_node('1.1.1.1')
      ng = add_node('2.2.2.2')
      sid = db.create_snapshot(network_class: :clearnet, started_at: now, candidates: 2,
                               crawler_ver: 'test', params_hash: 'deadbeef')
      db.record_results(sid, [{ node_id: ok, success: true }, { node_id: ng, success: false, fail_reason: 'timeout' }],
                        finished_at: now + 10)
      probed = db.db.execute('SELECT id, last_probed, last_success, fail_streak FROM nodes ORDER BY id').to_h do |r|
        [r[0], r[1..]]
      end
      expect(probed[ok]).to eq([now + 10, now + 10, 0])
      expect(probed[ng]).to eq([now + 10, nil, 1])
    end

    it 'resets fail_streak on success, increments on failure; union_24h is the 24h window union' do
      a = add_node('1.1.1.1')
      b = add_node('2.2.2.2')
      db.db.execute('UPDATE nodes SET fail_streak = 5 WHERE id = ?', [a])

      s1 = db.create_snapshot(network_class: :clearnet, started_at: now,
                              candidates: 2, crawler_ver: '0.1.0', params_hash: 'aaaaaaaa')
      db.record_results(s1, [
                          { node_id: a, success: true, user_agent: '/Satoshi:30.0.0/', protocol_version: 70016,
                            services: 1033, start_height: 900_000, rtt_ms: 42 },
                          { node_id: b, success: false, fail_reason: 'timeout' }
                        ], finished_at: now + 60)

      streak_a, last_success_a = db.db.execute('SELECT fail_streak, last_success FROM nodes WHERE id = ?', [a]).first
      streak_b = db.db.get_first_value('SELECT fail_streak FROM nodes WHERE id = ?', [b])
      expect(streak_a).to eq(0)
      expect(last_success_a).to eq(now + 60)
      expect(streak_b).to eq(1)
      expect(db.db.get_first_value('SELECT reachable FROM snapshots WHERE id = ?', [s1])).to eq(1)

      # Round 2: only b succeeds → union is a+b = 2
      s2 = db.create_snapshot(network_class: :clearnet, started_at: now + 900,
                              candidates: 2, crawler_ver: '0.1.0', params_hash: 'aaaaaaaa')
      db.record_results(s2, [
                          { node_id: a, success: false, fail_reason: 'refused' },
                          { node_id: b, success: true, user_agent: '/Satoshi:29.0.0/', protocol_version: 70016,
                            services: 1033, start_height: 900_001, rtt_ms: 10 }
                        ], finished_at: now + 960)

      expect(db.union_24h('clearnet', at: now + 960)).to eq(2)
      # After more than 24 hours, s1's success falls out of the window
      expect(db.union_24h('clearnet', at: now + 900 + 86_401)).to eq(0)
      # Never mixed with the onion series
      expect(db.union_24h('onion', at: now + 960)).to eq(0)
    end
  end

  describe '#prune_observations' do
    it 'deletes only observations of snapshots before the cutoff, keeping snapshots and nodes' do
      a = add_node('1.1.1.1')

      old_s = db.create_snapshot(network_class: :clearnet, started_at: now - 100_000,
                                 candidates: 1, crawler_ver: '0.1.0', params_hash: 'aaaaaaaa')
      db.record_results(old_s, [{ node_id: a, success: true, user_agent: '/S/', protocol_version: 70_016,
                                  services: 0, start_height: 1, rtt_ms: 1 }], finished_at: now - 99_000)

      new_s = db.create_snapshot(network_class: :clearnet, started_at: now,
                                 candidates: 1, crawler_ver: '0.1.0', params_hash: 'aaaaaaaa')
      db.record_results(new_s, [{ node_id: a, success: true, user_agent: '/S/', protocol_version: 70_016,
                                  services: 0, start_height: 2, rtt_ms: 1 }], finished_at: now + 60)

      deleted = db.prune_observations(before: now - 1000)
      expect(deleted).to eq(1)
      remaining = db.db.execute('SELECT snapshot_id FROM observations').flatten
      expect(remaining).to eq([new_s])
      # snapshot rows (aggregate counts) and node records are retained
      expect(db.db.get_first_value('SELECT COUNT(*) FROM snapshots')).to eq(2)
      expect(db.node_count).to eq(1)
      db.vacuum
    end
  end
end
