# frozen_string_literal: true

require 'bitcoin'

Bitcoin.chain_params = :mainnet

# Bitcoin P2P network observation infrastructure.
# Performs version handshakes against candidate addresses (sourced from our own
# node's addrman) and records reachable nodes into SQLite.
module Observatory
  VERSION = '0.1.0'
  USER_AGENT = "/btc-node-observatory:#{VERSION}/"

  autoload :Config,          'observatory/config'
  autoload :Database,        'observatory/database'
  autoload :RpcClient,       'observatory/rpc_client'
  autoload :AddressImporter, 'observatory/address_importer'
  autoload :Socks5,          'observatory/socks5'
  autoload :Prober,          'observatory/prober'
  autoload :Crawler,         'observatory/crawler'
  autoload :Exporter,        'observatory/exporter'
  autoload :Archiver,        'observatory/archiver'
  autoload :Geo,             'observatory/geo'
end
