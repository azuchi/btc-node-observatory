# frozen_string_literal: true

require 'json'

module Observatory
  # Imports getnodeaddresses results into the nodes table.
  # Sources: bitcoind RPC (direct) or a JSON file containing the output of
  # `bitcoin-cli getnodeaddresses 0` (for setups where the Pi ships it via rsync/ssh).
  class AddressImporter
    # The network field from getnodeaddresses is stored as-is.
    # i2p / cjdns are recorded only (not probed for now; kept as future extension room).
    KNOWN_NETWORKS = %w[ipv4 ipv6 onion i2p cjdns].freeze

    def initialize(database)
      @db = database
    end

    # entries: [{ 'address' =>, 'port' =>, 'network' =>, 'time' => }, ...]
    # @return [Hash] import counts per network
    def import(entries, now: Time.now.to_i)
      counts = Hash.new(0)
      @db.transaction do
        entries.each do |e|
          network = e['network']
          next unless KNOWN_NETWORKS.include?(network)

          @db.upsert_node(address: e['address'], port: e['port'], network: network, seen_at: now)
          counts[network] += 1
        end
      end
      counts
    end

    def import_from_file(path, now: Time.now.to_i)
      import(JSON.parse(File.read(path)), now: now)
    end

    def import_from_rpc(rpc_client, now: Time.now.to_i)
      import(rpc_client.getnodeaddresses(0), now: now)
    end
  end
end
