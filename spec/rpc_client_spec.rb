# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Observatory::RpcClient do
  # Minimal fake HTTP server returning a fixed response.
  def start_http_server(status_line, body)
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    thread = Thread.new do
      client = server.accept
      # read request headers + body (ignore content)
      client.readpartial(65_536)
      client.write("HTTP/1.1 #{status_line}\r\nContent-Length: #{body.bytesize}\r\n" \
                   "Connection: close\r\n\r\n#{body}")
      client.close rescue nil
    end
    @fake_servers ||= []
    @fake_servers << [server, thread]
    port
  end

  def client(port)
    described_class.new(rpc_url: "http://127.0.0.1:#{port}", rpc_user: 'u', rpc_password: 'p')
  end

  it 'returns the result field on success' do
    port = start_http_server('200 OK', JSON.generate({ result: [{ 'address' => '1.1.1.1' }], error: nil }))
    expect(client(port).getnodeaddresses).to eq([{ 'address' => '1.1.1.1' }])
  end

  it 'explains authentication failure on an empty 401 response' do
    port = start_http_server('401 Unauthorized', '')
    expect { client(port).getnodeaddresses }
      .to raise_error(Observatory::RpcClient::Error, /HTTP 401.*authentication failed/)
  end

  it 'explains rpcallowip rejection on an empty 403 response' do
    port = start_http_server('403 Forbidden', '')
    expect { client(port).getnodeaddresses }
      .to raise_error(Observatory::RpcClient::Error, /HTTP 403.*rpcallowip/)
  end

  it 'raises the RPC error contained in an HTTP 500 JSON body' do
    port = start_http_server('500 Internal Server Error',
                             JSON.generate({ result: nil, error: { 'code' => -32_601, 'message' => 'Method not found' } }))
    expect { client(port).getnodeaddresses }
      .to raise_error(Observatory::RpcClient::Error, /Method not found/)
  end

  it 'reports non-JSON responses with the HTTP status' do
    port = start_http_server('200 OK', '<html>proxy error</html>')
    expect { client(port).getnodeaddresses }
      .to raise_error(Observatory::RpcClient::Error, /non-JSON RPC response \(HTTP 200\)/)
  end
end
