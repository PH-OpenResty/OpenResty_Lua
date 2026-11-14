local u = require 'scdn_sync.util'
local json = require 'scdn_sync.codec'
local web = require 'scdn_sync.web'
local auth = require 'scdn_sync.auth'
local M = {}
function M.configure(settings, bootstrap)
    local data, state = ngx.shared.scdn_sync_data, ngx.shared.scdn_sync_state
    M.settings = settings
    M.engine = require('scdn_sync.runtime.engine').new(data, state, 'scdn_sync_locks', settings,
        require('ngx.ssl'), ngx.worker, ngx.now)
    -- Called in init_by_lua before workers start; startup IO is handled by the loader.
    if bootstrap and not state:get('active') then
        local encoded = json.encode(bootstrap)
        u.check(data:safe_set('snapshot:' .. bootstrap.revision_id, encoded), 'runtime_capacity', 507)
        u.check(state:safe_set('active', bootstrap.revision_id), 'runtime_capacity', 507)
        u.check(state:safe_set('highest', json.encode({ desired_seq = bootstrap.desired_seq,
            revision_id = bootstrap.revision_id, sha256 = require('scdn_sync.crypto').sha256(encoded) })), 'runtime_capacity', 507)
    end
end
function M.init_worker()
    -- A new identity per actual Worker, even when worker IDs are reused after a respawn.
    M.engine.boot = require('scdn_sync.crypto').sha256(require('scdn_sync.crypto').random(16)):sub(1, 24)
    M.settings.yield_prepare = function() ngx.sleep(0) end
    local function tick(premature)
        if premature then return end
        local ok = pcall(M.engine.tick, M.engine)
        if not ok then ngx.log(ngx.ERR, 'scdn runtime tick failed') end
        u.check(ngx.timer.at(0.1, tick), 'timer_failed', 500)
    end
    u.check(ngx.timer.at(0, tick), 'timer_failed', 500)
end
function M.lookup(host) return M.engine:lookup(host, ngx.ctx) end
function M.hosts()
    local current = M.engine:current()
    return current and current.host_list or json.array()
end
function M.set_cert()
    local ssl = require 'ngx.ssl'
    local host = ssl.server_name()
    local ok = host and pcall(M.engine.set_certificate, M.engine, host:lower())
    if not ok then return ngx.exit(ngx.ERROR) end
end
function M.probe()
    return web.handle(function()
        local current = M.engine:current(ngx.ctx)
        local site = current and current.hosts[ngx.var.host]
        if not site then return ngx.exit(403) end
        ngx.header['X-Scdn-Revision'] = current.revision_id
        return ngx.exit(204)
    end)
end
function M.handle()
    return web.handle(function()
        auth.local_authorize(ngx.var.http_x_scdn_control, M.settings.control_token)
        u.check(ngx.var.args == nil, 'query_not_allowed')
        local path = ngx.var.uri
        if path == '/__scdn_sync/v1/status' and ngx.req.get_method() == 'GET' then
            return web.reply(200, M.engine:status())
        end
        u.check(ngx.req.get_method() == 'POST', 'method_not_allowed', 405)
        local actions = { ['/__scdn_sync/v1/stage'] = 'stage', ['/__scdn_sync/v1/commit'] = 'commit',
            ['/__scdn_sync/v1/rollback'] = 'rollback', ['/__scdn_sync/v1/finalize'] = 'finalize' }
        local action = u.check(actions[path], 'route_not_found', 404)
        local input = json.decode(web.body(u.MAX_BYTES))
        return web.reply(200, M.engine[action](M.engine, input))
    end)
end
return M
