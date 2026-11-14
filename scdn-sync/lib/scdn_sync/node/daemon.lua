local u = require 'scdn_sync.util'
local json = require 'scdn_sync.codec'
local auth = require 'scdn_sync.auth'
local http = require 'scdn_sync.http'
local M = {}
function M.run(settings, store)
    u.check(u.id(settings.node_id) and u.id(settings.scope_id) and settings.master_endpoint.scheme == 'https'
        and settings.master_endpoint.client_cert and settings.master_endpoint.client_key, 'node_config')
    local tls_ok = pcall(function()
        require 'resty.openssl.include.ssl'
        require 'resty.openssl.auxiliary.nginx_c'
        require 'resty.openssl.ssl'
    end)
    u.check(tls_ok, 'tls_probe_dependency_unavailable', 503)
    local lock = store:lock('node.lock')
    local outbox = require('scdn_sync.node.outbox').new(store, settings.node_id, settings.outbox_capacity)
    local function control(action, input)
        return http.request(settings.control_endpoint, action == 'status' and 'GET' or 'POST',
            '/__scdn_sync/v1/' .. action, { ['x-scdn-control'] = settings.control_token,
                ['content-type'] = 'application/json' }, input and json.encode(input), u.MAX_BYTES)
    end
    local applier = require('scdn_sync.node.apply').new(store, settings, control, outbox, ngx.time, ngx.sleep,
        require('scdn_sync.node.probe').new(settings.probe))
    local function send(path, body)
        local endpoint = settings.master_endpoint
        local headers = auth.sign_request(endpoint.authority, path, body, settings.request_identity, ngx.time())
        return http.request(endpoint, 'POST', path, headers, body, 65536)
    end
    local function jitter(seconds)
        local n = require('scdn_sync.crypto').random(2)
        return seconds * (0.8 + (n:byte(1) * 256 + n:byte(2)) / 65535 * 0.4)
    end
    -- Restore a previous durable transaction before sending any newer heartbeat/report.
    while true do
        local ok, err = pcall(applier.recover, applier)
        if ok then break end
        ngx.log(ngx.WARN, 'scdn recovery pending: ', (u.error_code(err)))
        ngx.sleep(jitter(5))
    end
    local reporter = ngx.thread.spawn(function()
        while not ngx.worker.exiting() do
            local ok, err = pcall(function() outbox:flush(send, 8) end)
            if not ok then ngx.log(ngx.WARN, 'scdn report pending: ', (u.error_code(err))) end
            ngx.sleep(ok and 1 or jitter(5))
        end
    end)
    local heartbeat = ngx.thread.spawn(function()
        while not ngx.worker.exiting() do
            local event
            local ok = pcall(function()
                local applied = applier:read('applied.json')
                event = outbox:reserve('/_scdn_sync/v1/heartbeat')
                outbox:enqueue(event, { applied_revision = applied and applied.revision_id })
            end)
            if not ok then
                if event then outbox:cancel(event) end
                ngx.log(ngx.WARN, 'scdn heartbeat deferred')
            end
            ngx.sleep(jitter(settings.heartbeat_seconds or 10))
        end
    end)
    local backoff = settings.poll_seconds or 5
    while not ngx.worker.exiting() do
        local ok, err = pcall(function()
            local applied = applier:recover()
            if not outbox:available() then return end
            local headers = applied and { ['if-none-match'] = '"' .. applied.digest .. '"' } or {}
            local response = http.request(settings.master_endpoint, 'GET', '/_scdn_sync/v1/desired', headers)
            u.check(response.status == 200 or response.status == 304, 'master_unavailable', 503)
            if response.status == 200 then
                applier:apply(response.body, function(sha)
                    local object = http.request(settings.master_endpoint, 'GET', '/_scdn_sync/v1/objects/' .. sha)
                    u.check(object.status == 200, 'object_unavailable', 503)
                    return object.body
                end)
            end
        end)
        if ok then backoff = settings.poll_seconds or 5
        else backoff = math.min(backoff * 2, 60); ngx.log(ngx.WARN, 'scdn sync deferred: ', (u.error_code(err))) end
        ngx.sleep(jitter(backoff))
    end
    ngx.thread.kill(reporter); ngx.thread.kill(heartbeat); lock:release()
end
return M
