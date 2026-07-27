# frozen_string_literal: true

module Observatory
  # ASN / country resolution via MaxMind GeoLite2.
  # Not applied to onion (the geo table stays NULL).
  # Requires the maxmind-db gem and GeoLite2 mmdb files (free license key).
  class Geo
    def initialize(country_db:, asn_db:)
      require 'maxmind/db'
      @country = MaxMind::DB.new(country_db, mode: MaxMind::DB::MODE_MEMORY)
      @asn = MaxMind::DB.new(asn_db, mode: MaxMind::DB::MODE_MEMORY)
    end

    def self.from_config(conf)
      raise ArgumentError, 'missing geoip settings (set geoip: in the config)' unless conf

      new(country_db: conf['country_db'], asn_db: conf['asn_db'])
    end

    # Resolve and store unresolved clearnet nodes (those with at least one successful handshake).
    # @return [Integer] number of resolved nodes
    def resolve_all(database, now: Time.now.to_i)
      count = 0
      database.unresolved_clearnet_nodes.each do |(node_id, address)|
        country = lookup_country(address)
        asn, asn_name = lookup_asn(address)
        next unless country || asn

        database.upsert_geo(node_id: node_id, asn: asn, asn_name: asn_name,
                            country: country, resolved_at: now)
        count += 1
      end
      count
    end

    def lookup_country(address)
      record = @country.get(address)
      record&.dig('country', 'iso_code')
    rescue IPAddr::InvalidAddressError
      nil
    end

    def lookup_asn(address)
      record = @asn.get(address)
      return [nil, nil] unless record

      ["AS#{record['autonomous_system_number']}", record['autonomous_system_organization']]
    rescue IPAddr::InvalidAddressError
      [nil, nil]
    end
  end
end
