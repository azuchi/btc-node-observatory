# frozen_string_literal: true

require 'spec_helper'
require 'async'

RSpec.describe Observatory::Prober do
  subject(:prober) do
    described_class.new(user_agent: Observatory::USER_AGENT, protocol_version: 70_016,
                        connect_timeout: 2, handshake_timeout: 2)
  end

  def probe(port)
    Sync { prober.probe('127.0.0.1', port) }
  end

  it 'completes the version/verack handshake and captures the peer metadata' do
    port = start_fake_node(user_agent: '/Satoshi:30.0.0/', start_height: 900_000)
    result = probe(port)
    expect(result.success).to be true
    expect(result.user_agent).to eq('/Satoshi:30.0.0/')
    expect(result.start_height).to eq(900_000)
    expect(result.protocol_version).to be > 0
    expect(result.rtt_ms).to be_a(Integer)
    expect(result.fail_reason).to be_nil
  end

  it 'classifies connection refused as refused' do
    # A real TCP ECONNREFUSED cannot be reproduced in the sandbox environment
    # (a transparent proxy completes every connection), so stub the connect-layer
    # exception to verify the classification
    allow(::Socket).to receive(:tcp).and_raise(Errno::ECONNREFUSED)
    result = probe(1)
    expect(result.success).to be false
    expect(result.fail_reason).to eq('refused')
  end

  it 'classifies no-route errors as unreachable' do
    allow(::Socket).to receive(:tcp).and_raise(Errno::EHOSTUNREACH)
    result = probe(1)
    expect(result.success).to be false
    expect(result.fail_reason).to eq('unreachable')
  end

  it 'classifies no response as timeout' do
    port = start_fake_node(behavior: :silent)
    result = probe(port)
    expect(result.success).to be false
    expect(result.fail_reason).to eq('timeout')
  end

  it 'classifies an invalid response as handshake_error' do
    port = start_fake_node(behavior: :garbage)
    result = probe(port)
    expect(result.success).to be false
    expect(result.fail_reason).to eq('handshake_error')
  end
end
