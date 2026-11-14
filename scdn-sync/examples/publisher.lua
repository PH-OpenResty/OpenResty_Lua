local read = require('scdn_sync.config').read
return {
    data_dir = '/var/lib/scdn-sync-master',
    signing_key_id = 'master-2026',
    signing_private_key = read('/etc/scdn-sync/keys/master-ed25519.pem'),
    nodes = dofile('/etc/scdn-sync/nodes.lua'),
}
