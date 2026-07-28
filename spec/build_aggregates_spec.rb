# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'fileutils'
require 'open3'

RSpec.describe 'btc-node-data/scripts/build_aggregates.rb' do
  let(:script) { File.expand_path('../../btc-node-data/scripts/build_aggregates.rb', __dir__) }

  before do
    skip 'btc-node-data is not checked out next to this repository' unless File.exist?(script)
  end

  def write_daily(repo, date, snapshots)
    year, month, = date.split('-')
    dir = File.join(repo, 'daily', year, month)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "#{date}.json"), JSON.generate({ 'date' => date, 'snapshots' => snapshots }))
  end

  def snapshot(ts, network_class, inst, union)
    base = { 'ts' => ts, 'network_class' => network_class, 'candidates' => 1000,
             'instantaneous' => inst, 'union_24h' => union, 'by_network' => {},
             'by_user_agent' => { '/Satoshi:30.0.0/' => inst }, 'crawler_ver' => '0.1.0',
             'params_hash' => 'abcd1234' }
    base['by_country'] = { 'US' => inst / 2, 'DE' => inst / 4 } if network_class == 'clearnet'
    base
  end

  it 'builds per-granularity aggregates from daily files (clearnet/onion kept separate)' do
    Dir.mktmpdir do |tmp|
      repo = File.join(tmp, 'repo')
      FileUtils.mkdir_p(File.join(repo, 'scripts'))
      FileUtils.cp(script, File.join(repo, 'scripts'))

      base = Time.utc(2026, 7, 20).to_i
      # 3 days × 2 snapshots each + one onion snapshot per day
      3.times do |d|
        day = base + d * 86_400
        date = Time.at(day).utc.strftime('%Y-%m-%d')
        write_daily(repo, date, [
                      snapshot(day + 100, 'clearnet', 7000 + d, 9000 + d),
                      snapshot(day + 40_000, 'clearnet', 7100 + d, 9100 + d),
                      snapshot(day + 200, 'onion', 3000 + d, 3500 + d)
                    ])
      end

      out, status = Open3.capture2e('ruby', File.join(repo, 'scripts', 'build_aggregates.rb'))
      expect(status).to be_success, out

      all = JSON.parse(File.read(File.join(repo, 'aggregates', 'all.json')))
      expect(all['resolution']).to eq('daily')
      expect(all['series'].keys).to contain_exactly('clearnet', 'onion')
      expect(all['series']['clearnet'].size).to eq(3) # aggregated per day
      # daily aggregation: instantaneous is averaged, union_24h is the max
      first_day = all['series']['clearnet'].first
      expect(first_day[1]).to eq(7050) # (7000+7100)/2
      expect(first_day[2]).to eq(9100)

      week = JSON.parse(File.read(File.join(repo, 'aggregates', 'week.json')))
      expect(week['resolution']).to eq('snapshot')
      expect(week['series']['clearnet'].size).to eq(6) # all snapshots within 7 days

      day_agg = JSON.parse(File.read(File.join(repo, 'aggregates', 'day.json')))
      expect(day_agg['series']['clearnet'].size).to eq(4) # last 2 days only

      %w[month quarter year].each do |g|
        expect(File).to exist(File.join(repo, 'aggregates', "#{g}.json"))
      end

      # latest.json: newest snapshot per network class with full breakdowns
      latest = JSON.parse(File.read(File.join(repo, 'aggregates', 'latest.json')))
      expect(latest['date']).to eq('2026-07-22')
      clearnet = latest['networks']['clearnet']
      expect(clearnet['instantaneous']).to eq(7102) # last snapshot of the last day
      expect(clearnet['by_country']).to eq({ 'US' => 3551, 'DE' => 1775 })
      expect(clearnet['by_user_agent']).to eq({ '/Satoshi:30.0.0/' => 7102 })
      expect(latest['networks']['onion']).not_to have_key('by_country')
    end
  end
end
