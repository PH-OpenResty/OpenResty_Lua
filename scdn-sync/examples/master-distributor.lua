local read = require('scdn_sync.config').read
return {
    internal_token = read('/etc/scdn-sync/keys/internal-token'):gsub('%s+$', ''),
    nodes = dofile('/etc/scdn-sync/nodes.lua'),
    writer_endpoint = { unix = '/run/scdn-sync-master-writer/writer.sock', authority = 'localhost',
        connect_ms = 500, read_ms = 1500, total_ms = 2000 },
}
