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
    # Committed in batches rather than as one transaction. A full addrman import
    # is ~52k rows and a harvest import ~88k, and holding the write lock for the
    # minutes that takes starves everything else — on 2026-08-09 it was part of a
    # 5-minute unbroken lock hold that cost the onion crawl a whole round.
    #
    # Batching is safe here precisely because upsert_node is idempotent (it only
    # advances last_seen via MAX), so a partial import is a smaller import, never
    # a wrong one. The next run is 15 minutes away and picks up the rest.
    def import(entries, now: Time.now.to_i)
      counts = Hash.new(0)
      entries.select { |e| KNOWN_NETWORKS.include?(e['network']) }
             .each_slice(Observatory::Database::IMPORT_BATCH_SIZE) do |batch|
        @db.transaction do
          batch.each do |e|
            @db.upsert_node(address: e['address'], port: e['port'], network: e['network'], seen_at: now)
            counts[e['network']] += 1
          end
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
