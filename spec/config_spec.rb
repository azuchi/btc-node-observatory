# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Observatory::Config do
  it 'has defaults matching the spec' do
    config = build_config
    expect(config.clearnet['concurrency']).to eq(500)
    expect(config.clearnet['connect_timeout']).to eq(5)
    expect(config.onion['connect_timeout']).to eq(30)
    expect(config.candidate_limit).to eq(100_000)
    expect(config.backoff['fail_streak_threshold']).to eq(30)
    expect(config.user_agent).to eq('/btc-node-observatory:0.1.0/')
  end

  it 'deep merges partial overrides' do
    config = build_config({ 'clearnet' => { 'concurrency' => 100 } })
    expect(config.clearnet['concurrency']).to eq(100)
    expect(config.clearnet['connect_timeout']).to eq(5) # default kept
  end

  describe '#params_hash' do
    it 'is stable for identical parameters' do
      expect(build_config.params_hash(:clearnet)).to eq(build_config.params_hash(:clearnet))
    end

    it 'changes when a measurement parameter changes' do
      a = build_config.params_hash(:clearnet)
      b = build_config({ 'clearnet' => { 'connect_timeout' => 10 } }).params_hash(:clearnet)
      expect(a).not_to eq(b)
    end

    it 'does not change with user_agent (it does not affect the methodology)' do
      a = build_config.params_hash(:clearnet)
      b = build_config({ 'user_agent' => '/other:1.0/' }).params_hash(:clearnet)
      expect(a).to eq(b)
    end

    it 'differs between clearnet and onion' do
      config = build_config
      expect(config.params_hash(:clearnet)).not_to eq(config.params_hash(:onion))
    end
  end
end
