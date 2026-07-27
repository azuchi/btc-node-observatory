# frozen_string_literal: true

require 'net/http'
require 'json'
require 'uri'

module Observatory
  # Minimal JSON-RPC client for bitcoind.
  # Supports rpc_user/rpc_password or cookie-file authentication.
  class RpcClient
    class Error < StandardError; end

    def initialize(rpc_url:, rpc_user: nil, rpc_password: nil, cookie_path: nil)
      @uri = URI.parse(rpc_url)
      if cookie_path
        @user, @password = File.read(cookie_path).strip.split(':', 2)
      else
        @user = rpc_user
        @password = rpc_password
      end
    end

    def self.from_config(conf)
      raise Error, 'missing bitcoind RPC settings (set bitcoind: in the config)' unless conf

      new(rpc_url: conf['rpc_url'], rpc_user: conf['rpc_user'],
          rpc_password: conf['rpc_password'], cookie_path: conf['cookie_path'])
    end

    # Fetch all addrman entries with getnodeaddresses 0.
    def getnodeaddresses(count = 0)
      call('getnodeaddresses', [count])
    end

    def call(method, params = [])
      req = Net::HTTP::Post.new(@uri.request_uri)
      req.basic_auth(@user, @password) if @user
      req['Content-Type'] = 'application/json'
      req.body = JSON.generate({ jsonrpc: '1.0', id: 'observatory', method: method, params: params })
      res = Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == 'https',
                                                  read_timeout: 120, open_timeout: 10) do |http|
        http.request(req)
      end
      body = JSON.parse(res.body)
      raise Error, "RPC error: #{body['error']}" if body['error']

      body['result']
    end
  end
end
