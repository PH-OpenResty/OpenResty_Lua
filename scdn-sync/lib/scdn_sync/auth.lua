-- RFC 9421 / RFC 9530 fixed profile; key ownership is pinned by the mTLS identity.
local u = require 'scdn_sync.util'
local crypto = require 'scdn_sync.crypto'
local json = require 'scdn_sync.codec'
local M = {}
local covered = '("@method" "@authority" "@path" "content-type" "content-digest")'
local routes = { ['/_scdn_sync/v1/reports'] = true, ['/_scdn_sync/v1/heartbeat'] = true }

local function authority(value)
    return type(value) == 'string' and #value <= 255 and value:match('^[A-Za-z0-9%.:%[%]_-]+$') ~= nil
end
local function base(method, host, path, content_type, content_digest, params)
    return table.concat({ '"@method": ' .. method, '"@authority": ' .. host,
        '"@path": ' .. path, '"content-type": ' .. content_type,
        '"content-digest": ' .. content_digest, '"@signature-params": ' .. params }, '\n')
end
function M.sign_request(host, path, body, identity, now)
    u.check(authority(host) and routes[path] and type(body) == 'string' and #body <= 65536, 'invalid_request')
    u.check(u.id(identity.key_id) and u.integer(now, 0, 999999999999939), 'invalid_key_id')
    host = host:lower() -- RFC 9421 @authority is normalized to lowercase.
    local nonce = json.b64(crypto.random(16))
    local params = covered .. ';created=' .. now .. ';expires=' .. (now + 60)
        .. ';keyid="' .. identity.key_id .. '";alg="ed25519";nonce="' .. nonce .. '"'
    local digest = 'sha-256=:' .. ngx.encode_base64(crypto.sha256(body, true)) .. ':'
    local signature = crypto.sign(base('POST', host, path, 'application/json', digest, params), identity.private_key)
    return { ['content-type'] = 'application/json', ['content-digest'] = digest,
        ['signature-input'] = 'scdn=' .. params, ['signature'] = 'scdn=:' .. ngx.encode_base64(signature) .. ':' }
end

function M.verify_request(request, identity, now)
    u.check(identity and identity.enabled ~= false and identity.revoked ~= true, 'node_forbidden', 403)
    u.check(request.node_id == identity.node_id, 'node_identity_mismatch', 403)
    u.check(request.method == 'POST' and routes[request.path] and authority(request.authority)
        and not request.query, 'request_target', 405)
    local headers = request.headers
    u.check(type(headers) == 'table', 'missing_credentials', 401)
    for _, name in ipairs({ 'signature-input', 'signature', 'content-type', 'content-digest' }) do
        u.check(type(headers[name]) == 'string' and #headers[name] <= 2048, 'missing_credentials', 401)
    end
    u.check(headers['content-type'] == 'application/json', 'content_type', 415)
    local params = headers['signature-input']:match('^scdn=(.+)$')
    u.check(params and params:sub(1, #covered) == covered, 'signature_profile', 401)
    local tail = params:sub(#covered + 1)
    local values, pos = {}, 1
    while pos <= #tail do
        local name, raw, ending = tail:match('^;([a-z]+)=("[A-Za-z0-9_-]+")()', pos)
        if not name then name, raw, ending = tail:match('^;([a-z]+)=([0-9]+)()', pos) end
        u.check(name and not values[name], 'signature_profile', 401)
        local numeric = name == 'created' or name == 'expires'
        u.check((numeric and raw:match('^[0-9]+$') and #raw <= 15)
            or (not numeric and raw:sub(1, 1) == '"'), 'signature_profile', 401)
        values[name], pos = raw:gsub('^"', ''):gsub('"$', ''), ending
    end
    u.keys(values, u.fields('created expires keyid alg nonce'))
    u.check(values.alg == 'ed25519' and values.keyid == identity.key_id and u.id(values.keyid), 'signature_key', 401)
    local created, expires = tonumber(values.created), tonumber(values.expires)
    u.check(u.integer(created, 0, 9007199254740991) and u.integer(expires, 0, 9007199254740991)
        and expires > created and expires - created <= 60 and created <= now + 30 and expires >= now - 30,
        'signature_expired', 401)
    u.check(values.nonce and #json.unb64(values.nonce, 16) == 16, 'signature_nonce', 401)
    local encoded = headers.signature:match('^scdn=:([A-Za-z0-9+/=]+):$')
    local signature = encoded and ngx.decode_base64(encoded)
    u.check(signature and ngx.encode_base64(signature) == encoded, 'invalid_signature', 401)
    crypto.verify(base('POST', request.authority:lower(), request.path, headers['content-type'],
        headers['content-digest'], params), signature, identity.public_key)
    u.check(type(request.body) == 'string' and #request.body <= 65536, 'body_size', 413)
    local expected = 'sha-256=:' .. ngx.encode_base64(crypto.sha256(request.body, true)) .. ':'
    u.check(u.equal(headers['content-digest'], expected), 'body_digest', 401)
    return { node_id = identity.node_id, key_id = identity.key_id, nonce = values.nonce,
        replay_until = expires + 30, body_sha256 = crypto.sha256(request.body), path = request.path }
end

function M.local_authorize(token, expected)
    u.check(type(expected) == 'string' and #expected >= 43, 'control_not_configured', 503)
    u.check(u.equal(token, expected), 'control_unauthorized', 401)
    return true
end
return M
