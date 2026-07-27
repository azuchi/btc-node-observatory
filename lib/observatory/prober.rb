# frozen_string_literal: true

require 'socket'
require 'securerandom'
require 'async'

module Observatory
  # Version handshake probe against a single node.
  # TCP connect → send version → receive version/verack → disconnect immediately.
  # No persistent connections.
  #
  # Failure reason classification (fixed at v0.1.0; record changes in the CHANGELOG):
  #   timeout         - connect timeout / handshake timeout
  #   refused         - ECONNREFUSED (REP=0x05 via SOCKS5)
  #   unreachable     - no route / host unreachable (including SOCKS5 REP=0x03/0x04/0x06)
  #   handshake_error - protocol error, disconnect, or invalid message after TCP established
  class Prober
    MAX_PAYLOAD = 2 * 1024 * 1024 # guard against memory exhaustion via huge messages

    Result = Struct.new(:success, :fail_reason, :protocol_version, :user_agent,
                        :services, :start_height, :rtt_ms, keyword_init: true)

    class HandshakeError < StandardError; end

    def initialize(user_agent:, protocol_version:, connect_timeout:, handshake_timeout:,
                   socks5_host: nil, socks5_port: nil)
      @user_agent = user_agent
      @protocol_version = protocol_version
      @connect_timeout = connect_timeout
      @handshake_timeout = handshake_timeout
      @socks5_host = socks5_host
      @socks5_port = socks5_port
      @magic = Bitcoin.chain_params.magic_head.htb
    end

    # @return [Result]
    def probe(address, port, task: Async::Task.current)
      started = monotime
      sock = task.with_timeout(@connect_timeout) { open_socket(address, port) }
      begin
        remote = task.with_timeout(@handshake_timeout) { handshake(sock) }
        Result.new(success: true,
                   protocol_version: remote.version,
                   user_agent: remote.user_agent,
                   services: remote.services,
                   start_height: remote.start_height,
                   rtt_ms: ((monotime - started) * 1000).round)
      ensure
        sock.close rescue nil
      end
    rescue Async::TimeoutError, IO::TimeoutError
      Result.new(success: false, fail_reason: 'timeout')
    rescue Errno::ECONNREFUSED
      Result.new(success: false, fail_reason: 'refused')
    rescue Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL
      Result.new(success: false, fail_reason: 'unreachable')
    rescue Socks5::Error => e
      Result.new(success: false, fail_reason: socks_fail_reason(e))
    rescue HandshakeError, SystemCallError, IOError, EOFError, ArgumentError
      Result.new(success: false, fail_reason: 'handshake_error')
    rescue StandardError => e
      # A misbehaving peer must never be able to kill the whole snapshot
      # (an uncaught exception would propagate through barrier.wait and abort
      # the crawl): record anything unexpected as handshake_error.
      warn "probe #{address}:#{port}: #{e.class}: #{e.message}"
      Result.new(success: false, fail_reason: 'handshake_error')
    end

    private

    def open_socket(address, port)
      if @socks5_host
        Socks5.connect(@socks5_host, @socks5_port, address, port)
      else
        ::Socket.tcp(address, port)
      end
    end

    # @return [Bitcoin::Message::Version] the peer's version message
    def handshake(sock)
      sock.write(build_version.to_pkt)
      remote_version = nil
      verack = false
      until remote_version && verack
        command, payload = read_message(sock)
        case command
        when 'version'
          remote_version = parse_version(payload)
          # Answering the peer's version with a verack is basic courtesy
          # (Core sends its verack without waiting for ours)
          sock.write(Bitcoin::Message::VerAck.new.to_pkt)
        when 'verack'
          verack = true
        end
        # Skip everything else (wtxidrelay / sendaddrv2 / ping etc.)
      end
      remote_version
    end

    # Malformed version payloads from arbitrary peers are expected in the wild;
    # classify any parse failure as handshake_error rather than a crash.
    # (Requires bitcoinrb >= 1.12.1, which accepts the optional BIP-37 relay
    # byte being absent.)
    def parse_version(payload)
      Bitcoin::Message::Version.parse_from_payload(payload)
    rescue StandardError
      raise HandshakeError, 'unparseable version message'
    end

    def build_version
      Bitcoin::Message::Version.new(
        version: @protocol_version,
        user_agent: @user_agent,
        services: 0,       # explicitly an observer node offering nothing
        start_height: 0,
        relay: false,      # avoid having txs pushed to us before we disconnect
        nonce: SecureRandom.random_number(0xffffffffffffffff)
      )
    end

    def read_message(sock)
      header = read_exact(sock, 24)
      magic = header.byteslice(0, 4)
      raise HandshakeError, 'invalid magic' unless magic == @magic

      command = header.byteslice(4, 12).delete("\x00")
      length, = header.byteslice(16, 4).unpack('V')
      checksum = header.byteslice(20, 4)
      raise HandshakeError, "payload too large: #{length}" if length > MAX_PAYLOAD

      payload = length.positive? ? read_exact(sock, length) : ''.b
      raise HandshakeError, 'checksum mismatch' unless Bitcoin.double_sha256(payload)[0, 4] == checksum

      [command, payload]
    end

    def read_exact(sock, len)
      buf = +''.b
      while buf.bytesize < len
        chunk = sock.read(len - buf.bytesize)
        raise HandshakeError, 'connection closed' if chunk.nil? || chunk.empty?

        buf << chunk
      end
      buf
    end

    def socks_fail_reason(error)
      case error.reply_code
      when 0x05 then 'refused'
      when 0x03, 0x04, 0x06 then 'unreachable'
      else 'handshake_error'
      end
    end

    def monotime = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
