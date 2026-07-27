# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe Observatory::Exporter do
  let(:db) { build_db }
  let(:date) { '2026-07-25' }
  let(:day_start) { Time.strptime("#{date} +0000", '%Y-%m-%d %z').to_i }

  def seed_node(address, network:, port: 8333)
    db.upsert_node(address: address, port: port, network: network, seen_at: day_start)
    db.db.get_first_value('SELECT id FROM nodes WHERE address = ?', [address])
  end

  before do
    a = seed_node('1.1.1.1', network: 'ipv4')
    b = seed_node('::2', network: 'ipv6')
    c = seed_node('3.3.3.3', network: 'ipv4')
    o = seed_node('abc.onion', network: 'onion')

    db.upsert_geo(node_id: a, asn: 'AS16509', asn_name: 'Amazon', country: 'US', resolved_at: day_start)
    db.upsert_geo(node_id: b, asn: 'AS24940', asn_name: 'Hetzner', country: 'DE', resolved_at: day_start)

    s1 = db.create_snapshot(network_class: :clearnet, started_at: day_start + 100,
                            candidates: 3, crawler_ver: '0.1.0', params_hash: 'abcd1234')
    db.record_results(s1, [
                        { node_id: a, success: true, user_agent: '/Satoshi:30.0.0/', protocol_version: 70_016,
                          services: 1033, start_height: 900_000, rtt_ms: 20 },
                        { node_id: b, success: true, user_agent: '/Satoshi:29.1.0/', protocol_version: 70_016,
                          services: 1033, start_height: 900_000, rtt_ms: 30 },
                        { node_id: c, success: false, fail_reason: 'timeout' }
                      ], finished_at: day_start + 200)

    s2 = db.create_snapshot(network_class: :onion, started_at: day_start + 300,
                            candidates: 1, crawler_ver: '0.1.0', params_hash: 'ffff0000')
    db.record_results(s2, [
                        { node_id: o, success: true, user_agent: '/Satoshi:30.0.0/', protocol_version: 70_016,
                          services: 1033, start_height: 900_000, rtt_ms: 800 }
                      ], finished_at: day_start + 400)
  end

  it 'generates the daily JSON in the spec §5.3 format (clearnet/onion separated)' do
    data = described_class.new(build_config, db).daily(date)
    expect(data['date']).to eq(date)
    expect(data['snapshots'].size).to eq(2)

    clearnet = data['snapshots'].find { |s| s['network_class'] == 'clearnet' }
    expect(clearnet['candidates']).to eq(3)
    expect(clearnet['instantaneous']).to eq(2)
    expect(clearnet['union_24h']).to eq(2)
    expect(clearnet['by_network']).to eq({ 'ipv4' => 1, 'ipv6' => 1 })
    expect(clearnet['by_country']).to eq({ 'US' => 1, 'DE' => 1 })
    expect(clearnet['by_asn']).to eq({ 'AS16509' => 1, 'AS24940' => 1 })
    expect(clearnet['by_user_agent']).to eq({ '/Satoshi:30.0.0/' => 1, '/Satoshi:29.1.0/' => 1 })
    expect(clearnet['params_hash']).to eq('abcd1234')

    onion = data['snapshots'].find { |s| s['network_class'] == 'onion' }
    expect(onion['instantaneous']).to eq(1)
    # onion has no country/ASN (geo stays NULL and is excluded from the aggregation)
    expect(onion).not_to have_key('by_country')
    expect(onion).not_to have_key('by_asn')
    expect(onion['by_network']).to eq({ 'onion' => 1 })
  end

  it 'sums breakdown entries beyond top_n into other' do
    config = build_config({ 'export' => { 'top_n' => 1 } })
    data = described_class.new(config, db).daily(date)
    clearnet = data['snapshots'].find { |s| s['network_class'] == 'clearnet' }
    expect(clearnet['by_user_agent'].keys.size).to eq(2) # top1 + other
    expect(clearnet['by_user_agent']['other']).to eq(1)
  end

  it 'writes to daily/YYYY/MM/YYYY-MM-DD.json' do
    out_dir = Dir.mktmpdir
    path = described_class.new(build_config, db).write_daily(date, out_dir: out_dir)
    expect(path).to eq(File.join(out_dir, 'daily', '2026', '07', '2026-07-25.json'))
    reread = JSON.parse(File.read(path))
    expect(reread['date']).to eq(date)
  end

  it 'returns nil for days without snapshots' do
    expect(described_class.new(build_config, db).daily('2000-01-01')).to be_nil
  end
end
