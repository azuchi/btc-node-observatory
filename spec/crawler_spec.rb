# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Observatory::Crawler do
  it 'completes a snapshot against fake nodes, recording instantaneous and union_24h' do
    port_ok = start_fake_node(user_agent: '/Satoshi:30.0.0/')
    port_ng = start_fake_node(behavior: :garbage) # invalid response → handshake_error

    db = build_db
    now = Time.now.to_i
    db.upsert_node(address: '127.0.0.1', port: port_ok, network: 'ipv4', seen_at: now)
    db.upsert_node(address: '127.0.0.1', port: port_ng, network: 'ipv4', seen_at: now)

    config = build_config({ 'clearnet' => { 'concurrency' => 10, 'connect_timeout' => 2,
                                            'handshake_timeout' => 2 } })
    summary = described_class.new(config, db, logger: Logger.new(File::NULL)).run(:clearnet)

    expect(summary[:candidates]).to eq(2)
    expect(summary[:instantaneous]).to eq(1)
    expect(summary[:union_24h]).to eq(1)

    snapshot = db.db.execute('SELECT network_class, reachable, candidates, crawler_ver, params_hash FROM snapshots').first
    expect(snapshot).to eq(['clearnet', 1, 2, Observatory::VERSION, config.params_hash(:clearnet)])

    observations = db.db.execute(<<~SQL)
      SELECT o.success, o.fail_reason, o.user_agent FROM observations o ORDER BY o.success DESC
    SQL
    expect(observations.size).to eq(2)
    expect(observations[0]).to eq([1, nil, '/Satoshi:30.0.0/'])
    expect(observations[1][0]).to eq(0)
    expect(observations[1][1]).to eq('handshake_error')
  end

  it 'aborts an onion snapshot when the SOCKS5 proxy is unreachable (no fake zero measurement)' do
    db = build_db
    db.upsert_node(address: 'abc.onion', port: 8333, network: 'onion', seen_at: Time.now.to_i)
    allow(::Socket).to receive(:tcp).and_raise(Errno::ECONNREFUSED)

    crawler = described_class.new(build_config, db, logger: Logger.new(File::NULL))
    expect { crawler.run(:onion) }.to raise_error(/SOCKS5 proxy .* not reachable/)
    # No snapshot row must be recorded
    expect(db.db.get_first_value('SELECT COUNT(*) FROM snapshots')).to eq(0)
  end
end
