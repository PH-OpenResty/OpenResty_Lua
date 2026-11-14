local settings = dofile('/etc/scdn-sync/publisher.lua')
settings.watch = {
    poll_seconds = 1,
    settle_seconds = 2,
    ttl_seconds = 3600,
    renew_before_seconds = 300,
    scopes = {
        {
            scope_id = 'edge',
            sites_dir = '/usr/local/openresty/lua_files/cluster/sites',
            node_ids = { 'node-a' },
            certificate_roots = { '/etc/scdn-sync/certificates' },
            -- Empty directories otherwise retain the last publication.
            allow_empty = false,
        },
    },
}
return settings
