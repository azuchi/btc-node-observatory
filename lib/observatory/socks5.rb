# frozen_string_literal: true

require 'socket'

module Observatory
  # Minimal SOCKS5 client for connections via Tor (RFC 1928, no auth, CONNECT only).
  # Onion addresses are passed as domain names (ATYP=0x03) without DNS resolution.
  module Socks5
    class Error < StandardError
      attr_reader :reply_code

      def initialize(message, reply_code: nil)
        super(message)
        @reply_code = reply_code
      end
    end

    REPLY_MESSAGES = {
      0x01 => 'general SOCKS server failure',
      0x02 => 'connection not allowed by ruleset',
      0x03 => 'network unreachable',
      0x04 => 'host unreachable',
      0x05 => 'connection refused',
      0x06 => 'TTL expired',
      0x07 => 'command not supported',
      0x08 => 'address type not supported'
    }.freeze

    module_function

    # Connect to the SOCKS5 server and return a socket with an established CONNECT to target.
    def connect(socks_host, socks_port, target_host, target_port)
      sock = ::Socket.tcp(socks_host, socks_port)
      begin
        negotiate(sock, target_host, target_port)
      rescue StandardError
        sock.close
        raise
      end
      sock
    end

    def negotiate(sock, target_host, target_port)
      sock.write("\x05\x01\x00".b) # VER=5, NMETHODS=1, NO AUTH
      ver, method = read_exact(sock, 2).unpack('C2')
      raise Error, "unexpected greeting: ver=#{ver} method=#{method}" unless ver == 5 && method.zero?

      req = "\x05\x01\x00\x03".b + [target_host.bytesize].pack('C') + target_host.b + [target_port].pack('n')
      sock.write(req)
      ver, rep, _rsv, atyp = read_exact(sock, 4).unpack('C4')
      raise Error, "unexpected reply version: #{ver}" unless ver == 5

      unless rep.zero?
        raise Error.new(REPLY_MESSAGES.fetch(rep, "reply code #{rep}"), reply_code: rep)
      end

      # Discard BND.ADDR + BND.PORT
      case atyp
      when 0x01 then read_exact(sock, 4 + 2)
      when 0x03 then read_exact(sock, read_exact(sock, 1).unpack1('C') + 2)
      when 0x04 then read_exact(sock, 16 + 2)
      else raise Error, "unknown ATYP: #{atyp}"
      end
      sock
    end

    def read_exact(sock, len)
      buf = +''.b
      while buf.bytesize < len
        chunk = sock.read(len - buf.bytesize)
        raise Error, 'connection closed during SOCKS negotiation' if chunk.nil? || chunk.empty?

        buf << chunk
      end
      buf
    end
  end
end
