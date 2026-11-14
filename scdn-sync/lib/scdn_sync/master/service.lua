-- Run inside a separate, one-worker OpenResty instance. Disk stalls stay here.
local u = require 'scdn_sync.util'
local auth = require 'scdn_sync.auth'
local json = require 'scdn_sync.codec'
local web = require 'scdn_sync.web'
local M = {}
function M.configure(settings, store)
    M.settings = settings
    M.ingest = require('scdn_sync.master.ingest').new(store, settings)
end
function M.handle()
    return web.handle(function()
        auth.local_authorize(ngx.var.http_x_scdn_internal, M.settings.internal_token)
        local path, method = ngx.var.uri, ngx.req.get_method()
        u.check(ngx.var.args == nil, 'query_not_allowed')
        if path == '/internal/index' and method == 'GET' then return web.reply(200, M.ingest:index(ngx.time())) end
        u.check(path == '/internal/accept' and method == 'POST', 'route_not_found', 404)
        local request = json.decode(web.body(131072), 131072)
        return web.reply(200, M.ingest:accept(request, ngx.time()))
    end)
end
return M
