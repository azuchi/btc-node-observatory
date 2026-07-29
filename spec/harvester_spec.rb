# frozen_string_literal: true

require 'spec_helper'
require 'json'

RSpec.describe Observatory::Harvester do
  let(:config) do
    build_config({ 'harvest' => { 'concurrency' => 5, 'connect_timeout' => 2,
                                  'getaddr_timeout' => 2, 'peers_per_round' => 10,
                                  'max_rounds' => 1, 'max_addrs_per_peer' => 100 } })
  end
  let(:harvester) { described_class.new(config, logger: Logger.new(File::NULL)) }

  it 'collects addresses from addr and addrv2 replies, tagged by network' do
    port = start_fake_node(behavior: :getaddr)
    result = harvester.run([['127.0.0.1', port, 'ipv4']])

    expect(result.asked).to eq(1)
    expect(result.answered).to eq(1)
    addrs = result.addresses
    expect(addrs.map { |a| a['address'] }).to include('5.5.5.5', '6.6.6.6')
    expect(addrs.map { |a| a['network'] }).to include('ipv4', 'onion')
    onion = addrs.find { |a| a['network'] == 'onion' }
    expect(onion['address']).to end_with('.onion')
    expect(addrs.first.keys).to contain_exactly('address', 'port', 'network', 'time')
  end

  it 'skips unreachable peers without failing the run' do
    allow(::Socket).to receive(:tcp).and_raise(Errno::ECONNREFUSED)
    result = harvester.run([['127.0.0.1', 1, 'ipv4']])
    expect(result.answered).to eq(0)
    expect(result.addresses).to be_empty
  end

  it 'ignores non-askable networks in the seed list' do
    result = harvester.run([['abc.onion', 8333, 'onion'], ['x.i2p', 8333, 'i2p']])
    expect(result.asked).to eq(0)
  end

  it 'writes a file that AddressImporter can read back' do
    port = start_fake_node(behavior: :getaddr)
    result = harvester.run([['127.0.0.1', port, 'ipv4']])

    Dir.mktmpdir do |tmp|
      path = harvester.write(result, File.join(tmp, 'harvest.json'))
      db = build_db
      counts = Observatory::AddressImporter.new(db).import_from_file(path)
      expect(counts['ipv4']).to eq(2)
      expect(counts['onion']).to eq(1)
      expect(db.node_count).to eq(3)
    end
  end
end
