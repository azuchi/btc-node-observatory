# frozen_string_literal: true

require 'json'
require 'fileutils'

module Observatory
  # Generates the daily aggregate JSON (spec §5.3).
  # No raw node lists included. clearnet and onion are recorded separately, never combined.
  # by_country / by_asn / by_user_agent contain only the top_n entries, with the
  # remainder summed into "other" (top_n is a methodology parameter; changes go
  # into the CHANGELOG).
  class Exporter
    def initialize(config, database)
      @config = config
      @db = database
    end

    # @param date_str [String] "YYYY-MM-DD" (UTC)
    # @return [Hash, nil] the generated daily aggregate (nil if there are no snapshots)
    def daily(date_str)
      snapshots = @db.snapshots_on(date_str)
      return nil if snapshots.empty?

      top_n = @config.export['top_n']
      {
        'date' => date_str,
        'observer' => observer_entry,
        'snapshots' => snapshots.map { |s| snapshot_entry(s, top_n) }
      }
    end

    # Writes daily/YYYY/MM/YYYY-MM-DD.json.
    # @return [String, nil] the written file path
    def write_daily(date_str, out_dir: nil)
      data = daily(date_str)
      return nil unless data

      out_dir ||= @config.export['out_dir']
      year, month, = date_str.split('-')
      dir = File.join(out_dir, 'daily', year, month)
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "#{date_str}.json")
      File.write(path, JSON.pretty_generate(data) + "\n")
      path
    end

    private

    # The observer's own view: addrman-derived address counts at export time.
    # Aggregate counts only — raw addresses are never published. This describes
    # the vantage point, not the network itself.
    def observer_entry
      {
        'addrman' => @db.node_counts_by_network,
        'backed_off' => @db.backed_off_counts(@config.backoff['fail_streak_threshold'])
      }
    end

    def snapshot_entry(snapshot, top_n)
      id = snapshot[:id]
      onion = snapshot[:network_class] == 'onion'
      entry = {
        'ts' => snapshot[:started_at],
        'network_class' => snapshot[:network_class],
        'candidates' => snapshot[:candidates],
        'instantaneous' => snapshot[:reachable],
        'union_24h' => @db.union_24h(snapshot[:network_class], at: snapshot[:finished_at]),
        'by_network' => @db.success_count_by(id, :network),
        'by_user_agent' => top(@db.success_count_by(id, :user_agent), top_n),
        'crawler_ver' => snapshot[:crawler_ver],
        'params_hash' => snapshot[:params_hash]
      }
      unless onion
        # Country/ASN breakdowns are clearnet only (onion has no IP/ASN).
        entry['by_country'] = top(@db.success_count_by(id, :country), top_n)
        entry['by_asn'] = top(@db.success_count_by(id, :asn), top_n)
      end
      entry
    end

    def top(counts, n)
      sorted = counts.sort_by { |_k, v| -v }
      head = sorted.first(n).to_h
      rest = sorted.drop(n).sum { |_k, v| v }
      head['other'] = rest if rest.positive?
      head
    end
  end
end
