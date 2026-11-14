local read = require('scdn_sync.config').read
return {
    data_dir = '/var/lib/scdn-sync-master',
    internal_token = read('/etc/scdn-sync/keys/internal-token'):gsub('%s+$', ''),
    nodes = dofile('/etc/scdn-sync/nodes.lua'),
    max_replays_per_node = 2048,
}
