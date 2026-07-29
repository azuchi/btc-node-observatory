# frozen_string_literal: true

require 'sqlite3'
require 'fileutils'
require 'time'

module Observatory
  # Primary storage in SQLite. Schema follows spec §4.
  class Database
    CLEARNET_NETWORKS = %w[ipv4 ipv6].freeze
    SCHEMA = <<~SQL
      CREATE TABLE IF NOT EXISTS snapshots (
        id            INTEGER PRIMARY KEY,
        network_class TEXT NOT NULL,      -- 'clearnet' | 'onion'
        started_at    INTEGER NOT NULL,   -- unix epoch
        finished_at   INTEGER,
        candidates    INTEGER NOT NULL,   -- number of probed candidates
        reachable     INTEGER,            -- number of successful handshakes
        crawler_ver   TEXT NOT NULL,      -- for methodology tracking
        params_hash   TEXT NOT NULL       -- hash of the config parameters (change detection)
      );

      CREATE TABLE IF NOT EXISTS nodes (
        id           INTEGER PRIMARY KEY,
        address      TEXT NOT NULL,
        port         INTEGER NOT NULL,
        network      TEXT NOT NULL,       -- 'ipv4'|'ipv6'|'onion'|'i2p'|'cjdns'
        first_seen   INTEGER NOT NULL,
        last_seen    INTEGER,             -- last time seen in addrman / probed
        last_success INTEGER,
        fail_streak  INTEGER DEFAULT 0,
        UNIQUE(address, port)
      );

      CREATE TABLE IF NOT EXISTS observations (
        snapshot_id      INTEGER NOT NULL REFERENCES snapshots(id),
        node_id          INTEGER NOT NULL REFERENCES nodes(id),
        success          INTEGER NOT NULL,  -- 0|1
        fail_reason      TEXT,
        protocol_version INTEGER,
        user_agent       TEXT,
        services         INTEGER,
        start_height     INTEGER,
        rtt_ms           INTEGER,
        PRIMARY KEY (snapshot_id, node_id)
      );

      CREATE TABLE IF NOT EXISTS geo (
        node_id     INTEGER PRIMARY KEY REFERENCES nodes(id),
        asn         TEXT,
        asn_name    TEXT,
        country     TEXT,
        resolved_at INTEGER
      );

      CREATE INDEX IF NOT EXISTS idx_nodes_network ON nodes(network);
      CREATE INDEX IF NOT EXISTS idx_observations_node ON observations(node_id);
      CREATE INDEX IF NOT EXISTS idx_snapshots_class_time ON snapshots(network_class, started_at);
    SQL

    attr_reader :db

    def initialize(path)
      FileUtils.mkdir_p(File.dirname(path))
      @db = SQLite3::Database.new(path)
      @db.busy_timeout = 30_000
      @db.execute('PRAGMA journal_mode = WAL')
      @db.execute('PRAGMA synchronous = NORMAL')
      @db.execute('PRAGMA foreign_keys = ON')
      @db.execute_batch(SCHEMA)
    end

    def close = @db.close

    def transaction(&) = @db.transaction(&)

    # --- nodes -------------------------------------------------------------

    # Register an addrman-sourced address. If it already exists, only advance last_seen.
    def upsert_node(address:, port:, network:, seen_at:)
      @db.execute(<<~SQL, [address, port, network, seen_at, seen_at])
        INSERT INTO nodes (address, port, network, first_seen, last_seen)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(address, port) DO UPDATE SET last_seen = MAX(COALESCE(last_seen, 0), excluded.last_seen)
      SQL
    end

    # Candidate selection.
    # - fail_streak below the threshold: always eligible
    # - at/above the threshold: exponential backoff (base * 2^(streak - threshold), capped at 2^max_exponent)
    # Nothing is ever removed (records are kept). candidate_limit caps the set,
    # preferring nodes with a success track record.
    def candidates(network_class, now:, limit:, threshold:, base_interval:, max_exponent:)
      networks = network_class.to_s == 'clearnet' ? CLEARNET_NETWORKS : [network_class.to_s]
      placeholders = networks.map { '?' }.join(',')
      @db.execute(<<~SQL, networks + [threshold, base_interval, threshold, max_exponent, now, limit])
        SELECT id, address, port, network FROM nodes
        WHERE network IN (#{placeholders})
          AND (
            fail_streak < ?
            OR COALESCE(last_seen, 0) + ? * (1 << MIN(fail_streak - ?, ?)) <= ?
          )
        ORDER BY (last_success IS NULL), last_success DESC, first_seen DESC
        LIMIT ?
      SQL
    end

    def node_count(network = nil)
      if network
        @db.get_first_value('SELECT COUNT(*) FROM nodes WHERE network = ?', [network])
      else
        @db.get_first_value('SELECT COUNT(*) FROM nodes')
      end
    end

    # Known addresses per network (the observer's addrman mirror).
    def node_counts_by_network
      @db.execute('SELECT network, COUNT(*) FROM nodes GROUP BY network').to_h
    end

    # Addresses currently in exponential backoff, per network.
    def backed_off_counts(threshold)
      @db.execute(<<~SQL, [threshold]).to_h
        SELECT network, COUNT(*) FROM nodes WHERE fail_streak >= ? GROUP BY network
      SQL
    end

    # --- snapshots / observations -----------------------------------------

    def create_snapshot(network_class:, started_at:, candidates:, crawler_ver:, params_hash:)
      @db.execute(<<~SQL, [network_class.to_s, started_at, candidates, crawler_ver, params_hash])
        INSERT INTO snapshots (network_class, started_at, candidates, crawler_ver, params_hash)
        VALUES (?, ?, ?, ?, ?)
      SQL
      @db.last_insert_row_id
    end

    # Bulk write of probe results. Observation inserts and node state updates run
    # in a single transaction (SQLite has a single writer, so we batch the writes).
    def record_results(snapshot_id, results, finished_at:)
      @db.transaction do
        obs = @db.prepare(<<~SQL)
          INSERT INTO observations
            (snapshot_id, node_id, success, fail_reason, protocol_version, user_agent, services, start_height, rtt_ms)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        ok = @db.prepare(<<~SQL)
          UPDATE nodes SET last_seen = ?, last_success = ?, fail_streak = 0 WHERE id = ?
        SQL
        ng = @db.prepare(<<~SQL)
          UPDATE nodes SET last_seen = ?, fail_streak = fail_streak + 1 WHERE id = ?
        SQL
        results.each do |r|
          obs.execute(snapshot_id, r[:node_id], r[:success] ? 1 : 0, r[:fail_reason],
                      r[:protocol_version], r[:user_agent], r[:services], r[:start_height], r[:rtt_ms])
          if r[:success]
            ok.execute(finished_at, finished_at, r[:node_id])
          else
            ng.execute(finished_at, r[:node_id])
          end
        end
        [obs, ok, ng].each(&:close)
        reachable = results.count { |r| r[:success] }
        @db.execute('UPDATE snapshots SET finished_at = ?, reachable = ? WHERE id = ?',
                    [finished_at, reachable, snapshot_id])
      end
    end

    # --- aggregation queries ----------------------------------------------

    def snapshots_on(date_str)
      from = Time.strptime("#{date_str} +0000", '%Y-%m-%d %z').to_i
      @db.execute(<<~SQL, [from, from + 86_400]).map { |row| row_to_snapshot(row) }
        SELECT id, network_class, started_at, finished_at, candidates, reachable, crawler_ver, params_hash
        FROM snapshots
        WHERE started_at >= ? AND started_at < ? AND finished_at IS NOT NULL
        ORDER BY started_at
      SQL
    end

    # KIT-style: union of nodes with at least one successful handshake within
    # the 24 hours preceding the given point in time.
    def union_24h(network_class, at:)
      @db.get_first_value(<<~SQL, [network_class.to_s, at - 86_400, at])
        SELECT COUNT(DISTINCT o.node_id)
        FROM observations o
        JOIN snapshots s ON o.snapshot_id = s.id
        WHERE o.success = 1 AND s.network_class = ? AND s.started_at > ? AND s.started_at <= ?
      SQL
    end

    def success_count_by(snapshot_id, column)
      sql = case column
            when :network
              <<~SQL
                SELECT n.network, COUNT(*) FROM observations o
                JOIN nodes n ON n.id = o.node_id
                WHERE o.snapshot_id = ? AND o.success = 1
                GROUP BY n.network ORDER BY COUNT(*) DESC
              SQL
            when :user_agent
              <<~SQL
                SELECT o.user_agent, COUNT(*) FROM observations o
                WHERE o.snapshot_id = ? AND o.success = 1
                GROUP BY o.user_agent ORDER BY COUNT(*) DESC
              SQL
            when :country
              <<~SQL
                SELECT COALESCE(g.country, 'unknown'), COUNT(*) FROM observations o
                LEFT JOIN geo g ON g.node_id = o.node_id
                WHERE o.snapshot_id = ? AND o.success = 1
                GROUP BY 1 ORDER BY COUNT(*) DESC
              SQL
            when :asn
              <<~SQL
                SELECT COALESCE(g.asn, 'unknown'), COUNT(*) FROM observations o
                LEFT JOIN geo g ON g.node_id = o.node_id
                WHERE o.snapshot_id = ? AND o.success = 1
                GROUP BY 1 ORDER BY COUNT(*) DESC
              SQL
            else
              raise ArgumentError, column.to_s
            end
      @db.execute(sql, [snapshot_id]).to_h
    end

    def unresolved_clearnet_nodes(limit = 10_000)
      @db.execute(<<~SQL, [limit])
        SELECT n.id, n.address FROM nodes n
        LEFT JOIN geo g ON g.node_id = n.id
        WHERE n.network IN ('ipv4', 'ipv6') AND g.node_id IS NULL AND n.last_success IS NOT NULL
        LIMIT ?
      SQL
    end

    # --- retention ---------------------------------------------------------

    # Deletes observations belonging to snapshots started before the cutoff.
    # Snapshot rows themselves are kept (tiny, and they retain the aggregate
    # reachable/candidates counts). Archive the affected months first —
    # pruned observations survive only in the archives.
    def prune_observations(before:)
      @db.execute(<<~SQL, [before])
        DELETE FROM observations
        WHERE snapshot_id IN (SELECT id FROM snapshots WHERE started_at < ?)
      SQL
      @db.changes
    end

    # Reclaims disk space after pruning. Needs free space up to the size of the
    # remaining data while it rewrites the database file.
    def vacuum = @db.execute('VACUUM')

    def upsert_geo(node_id:, asn:, asn_name:, country:, resolved_at:)
      @db.execute(<<~SQL, [node_id, asn, asn_name, country, resolved_at])
        INSERT INTO geo (node_id, asn, asn_name, country, resolved_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(node_id) DO UPDATE SET
          asn = excluded.asn, asn_name = excluded.asn_name,
          country = excluded.country, resolved_at = excluded.resolved_at
      SQL
    end

    private

    def row_to_snapshot(row)
      {
        id: row[0], network_class: row[1], started_at: row[2], finished_at: row[3],
        candidates: row[4], reachable: row[5], crawler_ver: row[6], params_hash: row[7]
      }
    end
  end
end
