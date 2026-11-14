local u = require 'scdn_sync.util'
local json = require 'scdn_sync.codec'
local crypto = require 'scdn_sync.crypto'
local web = require 'scdn_sync.web'
local http = require 'scdn_sync.http'
local x509 = require 'resty.openssl.x509'
local M = {}
local config, index, certificates, identities
function M.configure(settings)
    config, index = settings, nil
    certificates = require('resty.lrucache').new(1024)
    identities = {}
    for id, node in pairs(config.nodes) do
        u.check(u.id(id) and node.node_id == id and u.hex(node.tls_certificate_sha256)
            and not identities[node.tls_certificate_sha256], 'duplicate_or_invalid_node_identity')
        identities[node.tls_certificate_sha256] = id
    end
end
local function identity()
    u.check(ngx.var.ssl_client_verify == 'SUCCESS', 'client_certificate_required', 401)
    local pem = ngx.var.ssl_client_raw_cert
    u.check(type(pem) == 'string' and #pem < 32768, 'client_certificate_required', 401)
    local fingerprint = certificates:get(pem)
    if not fingerprint then
        local cert = u.check(x509.new(pem), 'invalid_client_certificate', 401)
        local bytes = u.check(cert:digest('sha256'), 'invalid_client_certificate', 401)
        fingerprint = (bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end))
        certificates:set(pem, fingerprint)
    end
    local id = u.check(identities[fingerprint], 'node_forbidden', 403)
    local node = config.nodes[id]
    u.check(node.enabled ~= false and node.revoked ~= true, 'node_forbidden', 403)
    return id
end
local function refresh()
    local response = http.request(config.writer_endpoint, 'GET', '/internal/index',
        { ['x-scdn-internal'] = config.internal_token }, nil, u.MAX_BYTES)
    u.check(response.status == 200, 'writer_unavailable', 503)
    local value = json.decode(response.body)
    u.check(value.protocol == u.PROTOCOL and type(value.nodes) == 'table', 'invalid_index', 503)
    index = value.nodes
end
function M.init_worker()
    local function tick(premature)
        if premature then return end
        local ok = pcall(refresh)
        if not ok then ngx.log(ngx.WARN, 'scdn sync index refresh unavailable') end
        local scheduled = ngx.timer.at(1, tick)
        if not scheduled then ngx.log(ngx.ERR, 'scdn sync index timer stopped') end
    end
    u.check(ngx.timer.at(0, tick), 'timer_failed', 500)
end
function M.handle()
    return web.handle(function()
        local id = identity()
        u.check(ngx.var.args == nil, 'query_not_allowed')
        local method, path = ngx.req.get_method(), ngx.var.uri
        if method == 'POST' then
            u.check(path == '/_scdn_sync/v1/reports' or path == '/_scdn_sync/v1/heartbeat', 'route_not_found', 404)
            local headers = web.headers()
            u.check(headers.signature and headers['signature-input'], 'missing_credentials', 401)
            local request = { node_id = id, method = method, path = path,
                authority = ngx.var.http_host, headers = headers, body = web.body(65536) }
            local response = http.request(config.writer_endpoint, 'POST', '/internal/accept',
                { ['x-scdn-internal'] = config.internal_token, ['content-type'] = 'application/json' },
                json.encode(request), 65536)
            return web.reply(response.status, response.body)
        end
        u.check(method == 'GET', 'method_not_allowed', 405)
        local node = index and index[id]
        u.check(node, 'publication_unavailable', 503)
        local revision, file, sha
        if path == '/_scdn_sync/v1/desired' then
            revision, file, sha = node.desired.revision_id, 'manifest.jws', node.desired.sha256
            if ngx.var.http_if_none_match == '"' .. sha .. '"' then
                ngx.header['ETag'] = '"' .. sha .. '"'
                ngx.header['Cache-Control'] = 'no-store'
                return ngx.exit(304)
            end
        else
            local object = path:match('^/_scdn_sync/v1/objects/([a-f0-9]+)$')
            u.check(u.hex(object), 'route_not_found', 404)
            for _, release in ipairs(node.releases) do
                for _, digest in ipairs(release.objects) do
                    if digest == object then revision, file, sha = release.revision_id, 'objects/' .. object .. '.jwe', object end
                end
            end
            u.check(revision, 'object_forbidden', 403)
        end
        u.check(u.id(id) and u.id(revision) and u.hex(sha), 'invalid_index', 503)
        ngx.var.scdn_sync_etag = '"' .. sha .. '"'
        return ngx.exec('/_scdn_sync_files/' .. id .. '/releases/' .. revision .. '/' .. file)
    end)
end
return M
