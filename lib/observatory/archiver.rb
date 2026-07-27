# frozen_string_literal: true

require 'zlib'
require 'json'
require 'fileutils'
require 'time'

module Observatory
  # Dumps one month of raw data (snapshots, observations, referenced nodes, geo)
  # into gzipped NDJSON files for upload to GitHub Releases (spec §5, tier 2).
  # Rows are streamed straight from SQLite into the gzip stream, so memory use
  # stays constant regardless of the month's size.
  #
  # Always archive a month BEFORE pruning it: once `prune` has run, these
  # archives are the only remaining copy of the raw observations.
  class Archiver
    SNAPSHOT_COLUMNS = %w[id network_class started_at finished_at candidates reachable
                          crawler_ver params_hash].freeze
    OBSERVATION_COLUMNS = %w[snapshot_id node_id success fail_reason protocol_version
                             user_agent services start_height rtt_ms].freeze
    NODE_COLUMNS = %w[id address port network first_seen].freeze
    GEO_COLUMNS = %w[node_id asn asn_name country resolved_at].freeze

    def initialize(config, database)
      @config = config
      @db = database.db
    end

    # Writes archives/raw-YYYY-MM/{meta.json, *.ndjson.gz} and returns the
    # directory path, or nil if the month has no finished snapshots.
    def write_month(month_str, out_dir: nil)
      raise ArgumentError, 'month must be YYYY-MM' unless month_str.match?(/\A\d{4}-\d{2}\z/)

      from, to = month_range(month_str)
      return nil if @db.get_first_value(<<~SQL, [from, to]).zero?
        SELECT COUNT(*) FROM snapshots WHERE started_at >= ? AND started_at < ?
      SQL

      dir = File.join(out_dir || File.join(@config.base_dir, 'archives'), "raw-#{month_str}")
      FileUtils.mkdir_p(dir)

      counts = {
        'snapshots' => dump(dir, 'snapshots', SNAPSHOT_COLUMNS, <<~SQL, [from, to]),
          SELECT id, network_class, started_at, finished_at, candidates, reachable,
                 crawler_ver, params_hash
          FROM snapshots WHERE started_at >= ? AND started_at < ? ORDER BY id
        SQL
        'observations' => dump(dir, 'observations', OBSERVATION_COLUMNS, <<~SQL, [from, to]),
          SELECT o.snapshot_id, o.node_id, o.success, o.fail_reason, o.protocol_version,
                 o.user_agent, o.services, o.start_height, o.rtt_ms
          FROM observations o JOIN snapshots s ON s.id = o.snapshot_id
          WHERE s.started_at >= ? AND s.started_at < ? ORDER BY o.snapshot_id, o.node_id
        SQL
        'nodes' => dump(dir, 'nodes', NODE_COLUMNS, <<~SQL, [from, to]),
          SELECT n.id, n.address, n.port, n.network, n.first_seen FROM nodes n
          WHERE n.id IN (
            SELECT DISTINCT o.node_id FROM observations o
            JOIN snapshots s ON s.id = o.snapshot_id
            WHERE s.started_at >= ? AND s.started_at < ?
          ) ORDER BY n.id
        SQL
        'geo' => dump(dir, 'geo', GEO_COLUMNS, <<~SQL, [from, to])
          SELECT g.node_id, g.asn, g.asn_name, g.country, g.resolved_at FROM geo g
          WHERE g.node_id IN (
            SELECT DISTINCT o.node_id FROM observations o
            JOIN snapshots s ON s.id = o.snapshot_id
            WHERE s.started_at >= ? AND s.started_at < ?
          ) ORDER BY g.node_id
        SQL
      }

      File.write(File.join(dir, 'meta.json'), JSON.pretty_generate({
        'month' => month_str, 'crawler_ver' => Observatory::VERSION,
        'created_at' => Time.now.utc.iso8601, 'row_counts' => counts
      }))
      dir
    end

    private

    def month_range(month_str)
      year, month = month_str.split('-').map(&:to_i)
      from = Time.utc(year, month, 1)
      to = month == 12 ? Time.utc(year + 1, 1, 1) : Time.utc(year, month + 1, 1)
      [from.to_i, to.to_i]
    end

    def dump(dir, name, columns, sql, params)
      count = 0
      Zlib::GzipWriter.open(File.join(dir, "#{name}.ndjson.gz")) do |gz|
        @db.execute(sql, params) do |row|
          gz.puts(JSON.generate(columns.zip(row).to_h))
          count += 1
        end
      end
      count
    end
  end
end
