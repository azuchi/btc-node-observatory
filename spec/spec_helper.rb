# frozen_string_literal: true

require 'observatory'
require 'tmpdir'
require 'socket'
require 'logger'

module SpecHelpers
  # Start a fake Bitcoin node speaking version/verack.
  # @return [Integer] the listen port
  def start_fake_node(user_agent: '/Satoshi:30.0.0/', start_height: 900_000, behavior: :handshake)
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    thread = Thread.new do
      loop do
        client = server.accept
        case behavior
        when :handshake
          read_bitcoin_message(client) # the client's version
          client.write(Bitcoin::Message::Version.new(
            user_agent: user_agent, start_height: start_height
          ).to_pkt)
          client.write(Bitcoin::Message::VerAck.new.to_pkt)
          read_bitcoin_message(client) rescue nil # the client's verack
        when :no_relay
          # An old node omitting the optional BIP-37 relay byte
          read_bitcoin_message(client)
          payload = Bitcoin::Message::Version.new(
            user_agent: user_agent, start_height: start_height
          ).to_payload[0..-2]
          client.write(build_pkt('version', payload))
          client.write(Bitcoin::Message::VerAck.new.to_pkt)
          read_bitcoin_message(client) rescue nil
        when :silent
          sleep 60
        when :garbage
          client.write("\x00" * 64)
        end
        client.close rescue nil
      end
    rescue IOError, Errno::EBADF
      # server closed
    end
    @fake_servers ||= []
    @fake_servers << [server, thread]
    port
  end

  def build_pkt(command, payload)
    Bitcoin.chain_params.magic_head.htb + [command].pack('a12') +
      [payload.bytesize].pack('V') + Bitcoin.double_sha256(payload)[0, 4] + payload
  end

  def read_bitcoin_message(sock)
    header = sock.read(24)
    raise IOError, 'closed' unless header&.bytesize == 24

    length = header.byteslice(16, 4).unpack1('V')
    sock.read(length) if length.positive?
    header.byteslice(4, 12).delete("\x00")
  end

  def stop_fake_nodes
    (@fake_servers || []).each do |server, thread|
      server.close rescue nil
      thread.kill
    end
    @fake_servers = []
  end

  def build_config(overrides = {})
    Observatory::Config.new(overrides, base_dir: Dir.mktmpdir)
  end

  def build_db
    Observatory::Database.new(File.join(Dir.mktmpdir, 'test.sqlite3'))
  end
end

RSpec.configure do |config|
  config.include SpecHelpers
  config.after { stop_fake_nodes }
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
