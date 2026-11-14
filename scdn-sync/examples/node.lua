local config = require 'scdn_sync.config'
local ssl = require 'ngx.ssl'
return {
    node_id = 'node-a', scope_id = 'edge', data_dir = '/var/lib/scdn-sync-node',
    decryption_key_id = 'decrypt-a',
    decryption_private_key = config.read('/etc/scdn-sync/keys/node-rsa.pem'),
    signing_public_keys = { ['master-2026'] = config.read('/etc/scdn-sync/public/master-ed25519.pem') },
    request_identity = { key_id = 'request-a', private_key = config.read('/etc/scdn-sync/keys/node-ed25519.pem') },
    master_endpoint = {
        scheme = 'https', host = 'sync.example.com', port = 8443, authority = 'sync.example.com:8443',
        client_cert = assert(ssl.parse_pem_cert(config.read('/etc/scdn-sync/pki/node.crt'))),
        client_key = assert(ssl.parse_pem_priv_key(config.read('/etc/scdn-sync/pki/node.key'))),
        connect_ms = 1000, read_ms = 5000, total_ms = 10000,
    },
    control_endpoint = { unix = '/run/scdn-sync-node/control.sock', authority = 'localhost', total_ms = 3000 },
    control_token = config.read('/etc/scdn-sync/keys/control-token'):gsub('%s+$', ''),
    static_roots = { '/srv/sites' }, verify_root = require('scdn_sync.fs').verify_directory,
    probe = { http_port = 80, https_port = 443 },
    poll_seconds = 5, heartbeat_seconds = 10, outbox_capacity = 256, prepare_seconds = 15,
}
