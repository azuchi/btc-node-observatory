# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Observatory::AddressImporter do
  let(:db) { build_db }
  let(:importer) { described_class.new(db) }
  let(:now) { 1_785_000_000 }

  def entries(count, network: 'ipv4', offset: 0)
    Array.new(count) do |i|
      n = i + offset
      { 'address' => "10.#{n / 65_536 % 256}.#{n / 256 % 256}.#{n % 256}", 'port' => 8333, 'network' => network }
    end
  end

  it 'records only the networks it knows about' do
    counts = importer.import([
                               { 'address' => '1.1.1.1', 'port' => 8333, 'network' => 'ipv4' },
                               { 'address' => 'abc.onion', 'port' => 8333, 'network' => 'onion' },
                               { 'address' => '9.9.9.9', 'port' => 8333, 'network' => 'cjdns' },
                               { 'address' => 'nope', 'port' => 8333, 'network' => 'martian' }
                             ], now: now)
    expect(counts).to eq({ 'ipv4' => 1, 'onion' => 1, 'cjdns' => 1 })
    expect(db.node_count).to eq(3)
  end

  # The import is committed in batches so it does not hold the write lock for
  # the minutes a full addrman or harvest import takes.
  it 'imports correctly across batch boundaries' do
    total = (Observatory::Database::IMPORT_BATCH_SIZE * 2) + 7
    counts = importer.import(entries(total), now: now)
    expect(counts['ipv4']).to eq(total)
    expect(db.node_count).to eq(total)
  end

  it 'is idempotent, so a re-import only advances last_seen' do
    importer.import(entries(3), now: now)
    importer.import(entries(3), now: now + 900)
    expect(db.node_count).to eq(3)
    expect(db.db.execute('SELECT DISTINCT first_seen, last_seen FROM nodes')).to eq([[now, now + 900]])
  end

  # The trade-off batching buys: a failure part way through leaves the earlier
  # batches committed. That is acceptable only because the upserts are
  # idempotent — a partial import is a smaller import, never a wrong one.
  it 'keeps the batches it already committed if a later one fails' do
    batch = Observatory::Database::IMPORT_BATCH_SIZE
    calls = 0
    allow(db).to receive(:upsert_node).and_wrap_original do |orig, **kwargs|
      calls += 1
      raise SQLite3::BusyException, 'database is locked' if calls == batch + 1

      orig.call(**kwargs)
    end

    expect { importer.import(entries(batch * 2), now: now) }.to raise_error(SQLite3::BusyException)
    expect(db.node_count).to eq(batch)
  end
end
