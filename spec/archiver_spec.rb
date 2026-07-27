# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'zlib'

RSpec.describe Observatory::Archiver do
  let(:db) { build_db }
  let(:july1) { Time.utc(2026, 7, 1).to_i }

  def read_ndjson(dir, name)
    Zlib::GzipReader.open(File.join(dir, "#{name}.ndjson.gz")) do |gz|
      gz.each_line.map { |line| JSON.parse(line) }
    end
  end

  before do
    db.upsert_node(address: '1.1.1.1', port: 8333, network: 'ipv4', seen_at: july1)
    db.upsert_node(address: '2.2.2.2', port: 8333, network: 'ipv4', seen_at: july1)
    @a, @b = db.db.execute('SELECT id FROM nodes ORDER BY id').flatten
    db.upsert_geo(node_id: @a, asn: 'AS1', asn_name: 'One', country: 'US', resolved_at: july1)

    # In July: node a succeeds, node b fails
    s = db.create_snapshot(network_class: :clearnet, started_at: july1 + 100,
                           candidates: 2, crawler_ver: '0.1.0', params_hash: 'abcd1234')
    db.record_results(s, [
                        { node_id: @a, success: true, user_agent: '/Satoshi:30.0.0/',
                          protocol_version: 70_016, services: 1033, start_height: 900_000, rtt_ms: 20 },
                        { node_id: @b, success: false, fail_reason: 'timeout' }
                      ], finished_at: july1 + 200)

    # In August (must not be included in the July archive)
    aug = Time.utc(2026, 8, 1).to_i
    s2 = db.create_snapshot(network_class: :clearnet, started_at: aug + 100,
                            candidates: 1, crawler_ver: '0.1.0', params_hash: 'abcd1234')
    db.record_results(s2, [{ node_id: @a, success: true, user_agent: '/Satoshi:30.0.0/',
                             protocol_version: 70_016, services: 1033, start_height: 900_001, rtt_ms: 21 }],
                      finished_at: aug + 200)
  end

  it 'dumps only the requested month as gzipped NDJSON with meta.json' do
    Dir.mktmpdir do |tmp|
      dir = described_class.new(build_config, db).write_month('2026-07', out_dir: tmp)
      expect(dir).to eq(File.join(tmp, 'raw-2026-07'))

      snapshots = read_ndjson(dir, 'snapshots')
      expect(snapshots.size).to eq(1)
      expect(snapshots.first['network_class']).to eq('clearnet')

      observations = read_ndjson(dir, 'observations')
      expect(observations.size).to eq(2)
      expect(observations.map { |o| o['success'] }).to contain_exactly(0, 1)

      nodes = read_ndjson(dir, 'nodes')
      expect(nodes.map { |n| n['address'] }).to contain_exactly('1.1.1.1', '2.2.2.2')

      geo = read_ndjson(dir, 'geo')
      expect(geo).to eq([{ 'node_id' => @a, 'asn' => 'AS1', 'asn_name' => 'One',
                           'country' => 'US', 'resolved_at' => july1 }])

      meta = JSON.parse(File.read(File.join(dir, 'meta.json')))
      expect(meta['month']).to eq('2026-07')
      expect(meta['row_counts']).to eq({ 'snapshots' => 1, 'observations' => 2,
                                         'nodes' => 2, 'geo' => 1 })
    end
  end

  it 'returns nil for months without snapshots' do
    Dir.mktmpdir do |tmp|
      expect(described_class.new(build_config, db).write_month('2020-01', out_dir: tmp)).to be_nil
      expect(File).not_to exist(File.join(tmp, 'raw-2020-01'))
    end
  end

  it 'rejects malformed month strings' do
    expect { described_class.new(build_config, db).write_month('2026-7') }
      .to raise_error(ArgumentError)
  end
end
