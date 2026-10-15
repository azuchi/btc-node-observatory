# frozen_string_literal: true

module Observatory
  # CPU usage over a measurement round, recorded with the snapshot.
  #
  # This exists because the published data could not answer the one question
  # that matters when a round comes out low: was the observer starved, or was it
  # waiting? Both show up identically as timeouts. The answer is in the idle
  # share, and it has had to be dug out of sar after the fact every time --
  # 2026-09-04, 2026-09-17, 2026-10-13. In every one of those the host was
  # *idle*, which is what ruled out contention and pointed at Tor; sysstat keeps
  # only days of history, so a round examined later than that cannot be read at
  # all.
  #
  # Deliberately not recorded here: a count of Tor's "No more HSDir available to
  # query" log lines. It looked like the other missing signal, but it is already
  # published -- it tracks by_fail_reason.unreachable almost exactly (668 log
  # lines against ~666 unreachable on 2026-10-12, 60 against ~77 on 2026-10-13),
  # because that log line IS what makes a probe unreachable rather than a
  # timeout. Recording it again would add a journal-reading dependency, and a
  # permission to go with it, for a column that duplicates one we already have.
  module HostStats
    PROC_STAT = '/proc/stat'
    PROC_LOADAVG = '/proc/loadavg'

    # /proc/stat's cpu line, in jiffies. Fields past `steal` are guest time,
    # which is already counted inside user/nice, so summing them would
    # double-count.
    FIELDS = %i[user nice system idle iowait irq softirq steal].freeze

    # @return [Hash, nil] jiffy counters, or nil where /proc/stat is unreadable
    def self.sample
      line = File.read(PROC_STAT)[/^cpu\s+(.*)$/, 1] or return nil
      FIELDS.zip(line.split.first(FIELDS.size).map(&:to_i)).to_h
    rescue SystemCallError
      nil
    end

    # Percentages of wall-clock CPU between two samples, rounded to 0.01.
    #
    # @return [Hash] empty when either sample is missing or no time has passed,
    #   so a host without /proc simply records nothing rather than failing a round
    def self.between(first, last)
      return {} unless first && last

      total = FIELDS.sum { |f| last[f] - first[f] }
      return {} unless total.positive?

      pct = ->(f) { ((last[f] - first[f]) * 100.0 / total).round(2) }
      {
        cpu_user_pct: pct.call(:user),
        cpu_system_pct: pct.call(:system),
        cpu_idle_pct: pct.call(:idle),
        cpu_iowait_pct: pct.call(:iowait),
        cpu_steal_pct: pct.call(:steal)
      }
    end

    # 5-minute load average, the one that best describes a round rather than the
    # instant it ended.
    def self.loadavg5
      File.read(PROC_LOADAVG).split[1]&.to_f
    rescue SystemCallError
      nil
    end
  end
end
