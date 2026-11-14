local u = require 'scdn_sync.util'
local json = require 'scdn_sync.codec'
local M = {}
function M.read(path, limit)
    local file = u.check(io.open(path, 'rb'), 'configuration_file_unavailable', 503)
    local bytes = file:read((limit or 65536) + 1); file:close()
    return u.check(bytes and #bytes <= (limit or 65536) and bytes, 'configuration_file_size')
end
function M.load(path)
    -- This is an operator-owned local Lua config, never downloaded from Master.
    local loader = u.check(loadfile(path), 'configuration_unavailable', 503)
    local ok, settings = pcall(loader)
    u.check(ok and type(settings) == 'table', 'configuration_invalid', 503)
    return settings
end
function M.bootstrap(settings, store)
    local raw = store:read('applied.json')
    if not raw then return nil end
    local applied = json.decode(raw)
    u.check(u.id(applied.revision_id) and u.seq(applied.desired_seq), 'invalid_applied_state')
    local bytes = u.check(store:read('releases/' .. applied.revision_id .. '/runtime.json'), 'applied_snapshot_missing')
    u.check(u.hex(applied.snapshot_sha256) and require('scdn_sync.crypto').sha256(bytes) == applied.snapshot_sha256,
        'applied_snapshot_digest')
    local snapshot = json.decode(bytes)
    u.check(snapshot.revision_id == applied.revision_id and snapshot.node_id == settings.node_id
        and snapshot.scope_id == settings.scope_id and snapshot.desired_seq == applied.desired_seq, 'invalid_applied_state')
    return snapshot
end
return M
