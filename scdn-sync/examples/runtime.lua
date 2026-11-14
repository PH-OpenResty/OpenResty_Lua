-- Business workers receive no node decryption key or request-signing key from this config.
return {
    node_id = 'node-a', scope_id = 'edge', data_dir = '/var/lib/scdn-sync-node',
    control_token = require('scdn_sync.config').read('/etc/scdn-sync/keys/control-token'):gsub('%s+$', ''),
    static_roots = { '/srv/sites' }, max_snapshot_bytes = 4 * 1024 * 1024, max_sites = 1000,
}
