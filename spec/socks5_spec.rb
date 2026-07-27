# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Observatory::Socks5 do
  # Minimal fake SOCKS5 server. Responds according to reply_code.
  def start_socks_server(reply_code: 0x00)
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    received = {}
    thread = Thread.new do
      client = server.accept
      client.read(2) # VER, NMETHODS
      client.read(1) # METHODS
      client.write("\x05\x00".b)
      ver, cmd, _rsv, atyp = client.read(4).unpack('C4')
      len = client.read(1).unpack1('C')
      host = client.read(len)
      dst_port = client.read(2).unpack1('n')
      received.merge!(ver: ver, cmd: cmd, atyp: atyp, host: host, port: dst_port)
      client.write([0x05, reply_code, 0x00, 0x01].pack('C4') + "\x00\x00\x00\x00\x00\x00".b)
      sleep 0.5
      client.close rescue nil
    end
    @fake_servers ||= []
    @fake_servers << [server, thread]
    [port, received]
  end

  it 'CONNECTs to an onion address as a domain name' do
    port, received = start_socks_server
    target = 'abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuvwx.onion'
    sock = described_class.connect('127.0.0.1', port, target, 8333)
    sock.close
    expect(received[:ver]).to eq(5)
    expect(received[:cmd]).to eq(1)      # CONNECT
    expect(received[:atyp]).to eq(3)     # domain name (no DNS resolution)
    expect(received[:host]).to eq(target)
    expect(received[:port]).to eq(8333)
  end

  it 'raises an Error carrying the reply_code on failure replies' do
    port, = start_socks_server(reply_code: 0x04) # host unreachable
    expect do
      described_class.connect('127.0.0.1', port, 'example.onion', 8333)
    end.to raise_error(Observatory::Socks5::Error) { |e| expect(e.reply_code).to eq(0x04) }
  end
end
