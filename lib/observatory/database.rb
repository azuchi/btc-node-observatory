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
        last_seen    INTEGER,             -- last time seen anywhere (addrman / harvest / probe)
        last_probed  INTEGER,             -- last time WE probed it; backoff keys off this
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

    # How long a writer waits for the lock before giving up.
    BUSY_TIMEOUT_MS = 600_000

    # Rows per transaction for address imports. Small enough that the lock is
    # released regularly, large enough to keep SQLite's batching win.
    IMPORT_BATCH_SIZE = 2_000

    # Sentinel for #vacuum's free_bytes, meaning "measure the filesystem". A
    # plain nil default would collide with nil's own meaning there: that the
    # filesystem could not be measured at all.
    MEASURE = Object.new.freeze

    attr_reader :db, :path

    # backoff: the config's backoff section. Only the one-off last_probed
    # migration needs it; normal queries take these as arguments.
    def initialize(path, backoff: Observatory::Config::DEFAULTS['backoff'])
      FileUtils.mkdir_p(File.dirname(path))
      @path = path
      @db = SQLite3::Database.new(path)
      # Writers here hold the lock for minutes, not milliseconds: a clearnet
      # round writes tens of thousands of observations and the address imports
      # are larger still. 30 s was not enough for the onion crawl to find a gap —
      # on 2026-08-09 it waited out its timeout and threw away a 3h52m round.
      @db.busy_timeout = BUSY_TIMEOUT_MS
      @db.execute('PRAGMA journal_mode = WAL')
      @db.execute('PRAGMA synchronous = NORMAL')
      @db.execute('PRAGMA foreign_keys = ON')
      @db.execute_batch(SCHEMA)
      migrate_last_probed!(backoff)
    end

    # Number of rounds the one-off backlog release is spread over (96 = 24 h of
    # clearnet rounds). See migrate_last_probed!.
    RELEASE_ROUNDS = 96

    # 2026-08-07: backoff used to key off last_seen, which the addrman import
    # rewrites to `now` for every address it returns, every 15 min. An address
    # still present in the addrman was therefore never eligible again once its
    # fail_streak crossed the threshold — permanent exclusion rather than
    # exponential backoff. It hit 46k clearnet addresses, 296 of which had been
    # reachable within the previous week.
    #
    # last_probed is backfilled from the observation history, so every address
    # gets its real last probe time and the correctly-backing-off ones keep their
    # place in the rotation. Only the addresses that come out *already overdue*
    # (~97k) are rewritten, to fall due one round-worth at a time rather than all
    # at once: 97k extra candidates in a single round would have overrun the
    # 15 min interval, which has cost us rounds before (2026-07-31, 74k
    # candidates, 18.2 min, 2 rounds lost).
    def migrate_last_probed!(backoff)
      return if @db.execute('PRAGMA table_info(nodes)').any? { |c| c[1] == 'last_probed' }

      threshold = backoff['fail_streak_threshold']
      base = backoff['base_interval_sec']
      max_exp = backoff['max_exponent']
      now = Time.now.to_i

      @db.transaction do
        @db.execute('ALTER TABLE nodes ADD COLUMN last_probed INTEGER')
        @db.execute(<<~SQL)
          UPDATE nodes SET last_probed = (
            SELECT MAX(s.started_at) FROM observations o
            JOIN snapshots s ON s.id = o.snapshot_id
            WHERE o.node_id = nodes.id
          )
        SQL
        # An overdue row is made due again at `now + (id % 96) * 900`, which means
        # backdating last_probed by its own backoff interval from that point.
        # Rows below the threshold are left alone: the interval does not apply to
        # them, so rewriting last_probed would not delay them anyway.
        interval = "#{base} * (1 << MIN(fail_streak - #{threshold}, #{max_exp}))"
        @db.execute(<<~SQL, [now, now])
          UPDATE nodes
             SET last_probed = ? + (id % #{RELEASE_ROUNDS}) * #{base} - (#{interval})
           WHERE fail_streak >= #{threshold}
             AND COALESCE(last_probed, 0) + (#{interval}) <= ?
        SQL
      end
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
    # Nothing is ever removed (records are kept), so `nodes` grows without bound;
    # backoff is what keeps a round's workload flat, not pruning.
    #
    # `limit` (candidate_limit) caps THIS ROUND only, applied after the backoff
    # filter — it is not a cap on the stored set. The ORDER BY means a binding
    # limit drops never-successful nodes first, which is the least damaging
    # truncation but still silently understates reachability. A round that hit it
    # is only visible as `candidates` == the limit exactly, so keep the limit well
    # above the peak (85,749 on 2026-07-30 is the highest seen so far).
    def candidates(network_class, now:, limit:, threshold:, base_interval:, max_exponent:)
      networks = network_class.to_s == 'clearnet' ? CLEARNET_NETWORKS : [network_class.to_s]
      placeholders = networks.map { '?' }.join(',')
      @db.execute(<<~SQL, networks + [threshold, base_interval, threshold, max_exponent, now, limit])
        SELECT id, address, port, network FROM nodes
        WHERE network IN (#{placeholders})
          AND (
            fail_streak < ?
            OR COALESCE(last_probed, 0) + ? * (1 << MIN(fail_streak - ?, ?)) <= ?
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

    # Known addresses per network, across every candidate source.
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
    #
    # This transaction MUST NOT be split into chunks. `fail_streak = fail_streak + 1`
    # below is not idempotent, and fail_streak drives candidate selection, so a
    # chunk applied twice would corrupt backoff silently. Being a single
    # transaction is also what makes the retry safe: a failure rolls the whole
    # thing back, so the retry starts from nothing written. Chunk the address
    # imports instead — their upserts are idempotent.
    def record_results(snapshot_id, results, finished_at:)
      with_write_retry("record_results(snapshot #{snapshot_id})") do
        write_results(snapshot_id, results, finished_at: finished_at)
      end
    end

    # Retries a whole write transaction that lost the race for the lock. Only
    # safe for transactions that are atomic and self-contained; see the warning
    # on record_results.
    def with_write_retry(label, attempts: 3)
      tries = 0
      begin
        tries += 1
        yield
      rescue SQLite3::BusyException => e
        raise if tries >= attempts

        warn "#{label}: #{e.message}, retrying (#{tries}/#{attempts - 1})"
        retry
      end
    end

    def write_results(snapshot_id, results, finished_at:)
      @db.transaction do
        obs = @db.prepare(<<~SQL)
          INSERT INTO observations
            (snapshot_id, node_id, success, fail_reason, protocol_version, user_agent, services, start_height, rtt_ms)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        # last_probed drives backoff and must only ever be set here, by an actual
        # probe. Do not let address imports touch it (see migrate_last_probed!).
        ok = @db.prepare(<<~SQL)
          UPDATE nodes SET last_seen = ?, last_probed = ?, last_success = ?, fail_streak = 0 WHERE id = ?
        SQL
        ng = @db.prepare(<<~SQL)
          UPDATE nodes SET last_seen = ?, last_probed = ?, fail_streak = fail_streak + 1 WHERE id = ?
        SQL
        results.each do |r|
          obs.execute(snapshot_id, r[:node_id], r[:success] ? 1 : 0, r[:fail_reason],
                      r[:protocol_version], r[:user_agent], r[:services], r[:start_height], r[:rtt_ms])
          if r[:success]
            ok.execute(finished_at, finished_at, finished_at, r[:node_id])
          else
            ng.execute(finished_at, finished_at, r[:node_id])
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

    # Failure counts for one snapshot, keyed by reason.
    #
    # Unlike the success breakdowns this is never truncated to a top-N: the
    # reason set is closed and small (timeout / refused / unreachable /
    # handshake_error), so a published figure here is the whole picture. That
    # matters because the split between these reasons moves with how loaded the
    # observer is, not only with the network — a saturated crawler records a
    # would-be `unreachable` as `timeout` once the budget runs out.
    #
    # Every non-success row carries a reason, so the counts here plus
    # `reachable` add up to `candidates` for the snapshot.
    def fail_count_by_reason(snapshot_id)
      @db.execute(<<~SQL, [snapshot_id]).to_h
        SELECT COALESCE(fail_reason, 'unknown'), COUNT(*) FROM observations
        WHERE snapshot_id = ? AND success = 0
        GROUP BY 1 ORDER BY COUNT(*) DESC
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

    # Months (YYYY-MM, UTC) that still hold observations older than the cutoff --
    # the set a prune at that cutoff would actually delete data from, which is
    # what scripts/archive_month.sh demands an uploaded archive for.
    #
    # The EXISTS probe is an index seek, not a scan: `PRIMARY KEY (snapshot_id,
    # node_id)` gives observations an implicit index led by snapshot_id. A month
    # already emptied by an earlier prune drops out of the result, so the guard
    # stops asking for an archive of data that no longer exists anywhere here.
    def months_before(cutoff)
      @db.execute(<<~SQL, [cutoff]).flatten
        SELECT DISTINCT strftime('%Y-%m', s.started_at, 'unixepoch')
        FROM snapshots s
        WHERE s.started_at < ?
          AND EXISTS (SELECT 1 FROM observations o WHERE o.snapshot_id = s.id)
        ORDER BY 1
      SQL
    end

    # Tables whose row counts are compared before a compacted copy is swapped in.
    COMPACT_VERIFY_TABLES = %w[snapshots observations nodes geo].freeze

    # Rewrites the database into a compacted copy and swaps it in, as an escape
    # from VACUUM's two-copies-of-everything appetite: VACUUM INTO writes the
    # rebuilt database straight to its target, with no temporary rebuild and
    # nothing routed through the -wal, so it needs ONE copy of the live data.
    #
    # That difference is what makes it usable here at all. On 2026-10-13 the
    # database held 3.2GB live in a 6.5GB file with 6.3GB free: VACUUM wanted
    # 6.4GB and was refused every week, while VACUUM INTO wants 3.2GB. On a 19GB
    # disk the plain VACUUM can never fit again, because the file plus twice its
    # own live data plus the OS no longer leaves room.
    #
    # THE CALLER MUST STOP EVERY WRITER FIRST (see scripts/compact_db.sh).
    # VACUUM INTO snapshots the database as it stands; anything written between
    # that snapshot and the swap goes to the old file and is discarded with it.
    # Holding a lock is not enough -- a writer blocked on the lock still holds
    # the old inode open and would write into a file nothing points at any more.
    #
    # The original is kept as <path>.bak rather than overwritten, so a failure
    # that only shows up once the crawler reopens the database is recoverable.
    #
    # @return [Hash] byte sizes and the path the original was kept at
    def compact(target: "#{@path}.compact")
      # Before measuring anything, for the same reason #vacuum does it: until the
      # WAL is folded in, File.size reports a database file that does not yet
      # hold its own contents. Reading it first is how the 2026-09-02 prune came
      # to log "3924.2MB -> 3924.2MB" for a VACUUM that had reclaimed 200MB.
      @db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
      FileUtils.rm_f(target)
      # Interpolated, not bound: VACUUM is not a statement the driver prepares
      # with parameters on every SQLite build. Quote by doubling, as SQL wants.
      @db.execute("VACUUM INTO '#{target.gsub("'", "''")}'")

      before = table_counts(@db)
      verify_compacted!(target, before)

      size_before = File.size(@path)
      size_after = File.size(target)
      backup = "#{@path}.bak"

      @db.close
      # The -wal and -shm belong to the OLD file. Left in place they would be
      # replayed into the new one, which is a corrupted database, not a stale one.
      FileUtils.rm_f(["#{@path}-wal", "#{@path}-shm"])
      File.rename(@path, backup)
      File.rename(target, @path)

      @db = SQLite3::Database.new(@path)
      @db.busy_timeout = BUSY_TIMEOUT_MS
      @db.execute('PRAGMA journal_mode = WAL')
      @db.execute('PRAGMA synchronous = NORMAL')
      @db.execute('PRAGMA foreign_keys = ON')
      verify_counts!(table_counts(@db), before, 'swapped-in database')

      { size_before: size_before, size_after: size_after, backup: backup }
    end

    # Bytes of free filesystem space a VACUUM needs: TWICE the live data, not
    # once. VACUUM builds the rebuilt database as a temporary file and then, in
    # WAL mode, lands the result in the -wal before the checkpoint folds it into
    # the main file -- so two full copies exist alongside the original.
    #
    # This figure is measured, not assumed. The comment here used to say "up to
    # the size of the remaining data", and on 2026-10-04 a VACUUM with 3.5GB of
    # live data and 6.74GB free raised SQLite3::FullException, which is how the
    # factor of two was found.
    def vacuum_bytes_needed
      page_size = @db.execute('PRAGMA page_size').flatten.first
      pages = @db.execute('PRAGMA page_count').flatten.first
      free_pages = @db.execute('PRAGMA freelist_count').flatten.first
      (pages - free_pages) * page_size * 2
    end

    # Free bytes on the filesystem holding the database, or nil if df cannot say.
    def self.free_disk_bytes(path)
      dir = File.dirname(File.expand_path(path))
      line = IO.popen(['df', '-Pk', '--', dir], err: File::NULL, &:read).lines[1]
      line && (line.split[3].to_i * 1024)
    rescue SystemCallError
      nil
    end

    # Reclaims disk space after pruning, but only when the filesystem can take
    # it -- see vacuum_bytes_needed. Skipping is safe and cheap: the pages freed
    # by a prune stay on the freelist and are reused by subsequent writes, so the
    # file stops growing even when it does not shrink. Failing the VACUUM is not
    # cheap: it aborts the caller, which on 2026-10-04 left a staged prune with
    # its second stage unrun.
    #
    # A nil free-space reading (df missing or unparseable) proceeds rather than
    # skips: never vacuuming at all is the worse failure.
    #
    # The checkpoint is what makes the result visible: in WAL mode VACUUM writes
    # the rebuilt pages to the -wal file, so the database file keeps its old size
    # until a checkpoint folds them in. Without this the 2026-09-02 run reported
    # "3924.2MB -> 3924.2MB" for a VACUUM that had in fact reclaimed ~200MB.
    #
    # @return [Hash] :status is :done, :skipped or :unmeasured, with the
    #   :needed and :free byte counts the decision was made on.
    # free_bytes: the measurement to decide on. Defaults to reading the real
    # filesystem AFTER the checkpoint below; pass a number to force the decision,
    # or nil to say the filesystem could not be measured.
    def vacuum(free_bytes: MEASURE)
      # Fold the WAL into the database before measuring anything. The caller has
      # just deleted millions of rows, so the -wal still holds every page that
      # delete touched, and measuring free space against that is measuring the
      # worst moment of the whole run: on 2026-10-11 the check came up 604MB
      # short while the -wal was holding roughly that much. The checkpoint is not
      # extra work -- those pages get written back regardless.
      @db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
      free_bytes = self.class.free_disk_bytes(@path) if free_bytes == MEASURE

      needed = vacuum_bytes_needed
      return { status: :skipped, needed: needed, free: free_bytes } if free_bytes && free_bytes < needed

      @db.execute('VACUUM')
      @db.execute('PRAGMA wal_checkpoint(TRUNCATE)')
      { status: free_bytes ? :done : :unmeasured, needed: needed, free: free_bytes }
    end

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

    def table_counts(handle)
      COMPACT_VERIFY_TABLES.to_h { |t| [t, handle.get_first_value("SELECT COUNT(*) FROM #{t}")] }
    end

    # Checked before the swap, not after: once the original has been renamed
    # away, a bad copy is all there is.
    def verify_compacted!(target, expected)
      copy = SQLite3::Database.new(target)
      integrity = copy.get_first_value('PRAGMA integrity_check')
      raise "compacted copy failed integrity_check: #{integrity}" unless integrity == 'ok'

      verify_counts!(table_counts(copy), expected, 'compacted copy')
    ensure
      copy&.close
    end

    def verify_counts!(actual, expected, what)
      differing = expected.reject { |t, n| actual[t] == n }
      return if differing.empty?

      detail = differing.map { |t, n| "#{t}: #{n} -> #{actual[t]}" }.join(', ')
      raise "#{what} lost rows (#{detail})"
    end

    def row_to_snapshot(row)
      {
        id: row[0], network_class: row[1], started_at: row[2], finished_at: row[3],
        candidates: row[4], reachable: row[5], crawler_ver: row[6], params_hash: row[7]
      }
    end
  end
end
