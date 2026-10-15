# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Observatory::HostStats do
  def jiffies(user: 0, nice: 0, system: 0, idle: 0, iowait: 0, irq: 0, softirq: 0, steal: 0)
    { user: user, nice: nice, system: system, idle: idle,
      iowait: iowait, irq: irq, softirq: softirq, steal: steal }
  end

  describe '.between' do
    it 'reports the share of the round each state took' do
      first = jiffies(user: 100, idle: 100)
      last  = jiffies(user: 400, idle: 700)   # +300 user, +600 idle
      expect(described_class.between(first, last))
        .to include(cpu_user_pct: 33.33, cpu_idle_pct: 66.67)
    end

    it 'separates waiting from being starved, which is the whole point' do
      starved = described_class.between(jiffies, jiffies(user: 1000, idle: 10))
      waiting = described_class.between(jiffies, jiffies(user: 300, idle: 700))
      expect(starved[:cpu_idle_pct]).to be < 2
      expect(waiting[:cpu_idle_pct]).to be > 60
    end

    it 'records nothing rather than failing the round when /proc is unreadable' do
      expect(described_class.between(nil, jiffies(user: 1))).to eq({})
      expect(described_class.between(jiffies(user: 1), nil)).to eq({})
    end

    it 'records nothing when no time passed between the samples' do
      expect(described_class.between(jiffies(user: 5), jiffies(user: 5))).to eq({})
    end

    it 'ignores guest time, which is already counted inside user' do
      # A real /proc/stat line has guest and guest_nice after steal; counting
      # them would double them into the total and skew every share.
      allow(File).to receive(:read).with('/proc/stat')
                                   .and_return("cpu  10 0 0 10 0 0 0 0 5 5\ncpu0 1 2 3\n")
      expect(described_class.sample.values.sum).to eq(20)
    end
  end

  describe '.sample / .loadavg5' do
    it 'reads the real host' do
      expect(described_class.sample[:idle]).to be_positive
      expect(described_class.loadavg5).to be_a(Float)
    end
  end
end
