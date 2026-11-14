local u = require 'scdn_sync.util'
local M = {}
-- All network work yields through cosockets. The deadline also covers response headers.
function M.request(endpoint, method, path, headers, body, maximum)
    u.check(type(endpoint) == 'table', 'invalid_endpoint')
    u.check(method == 'GET' or method == 'POST', 'http_method')
    u.check(type(path) == 'string' and path:sub(1, 1) == '/' and not path:find('[%z\r\n ]'), 'http_path')
    u.check(endpoint.scheme == 'https' or endpoint.unix
        or (endpoint.scheme == 'http' and (endpoint.host == '127.0.0.1' or endpoint.host == '::1')), 'insecure_endpoint')
    if endpoint.unix then
        u.check(type(endpoint.unix) == 'string' and endpoint.unix:sub(1, 1) == '/'
            and not endpoint.unix:find('[%z\r\n]') and not endpoint.port and not endpoint.scheme, 'invalid_unix_endpoint')
    end
    local client
    local operation = ngx.thread.spawn(function()
        local ok, value = pcall(function()
        client = require('resty.http').new()
        client:set_timeouts(endpoint.connect_ms or 1000, endpoint.send_ms or 3000, endpoint.read_ms or 5000)
        local options = { scheme = endpoint.scheme, host = endpoint.unix and ('unix:' .. endpoint.unix) or endpoint.host,
            port = endpoint.port, ssl_verify = true, ssl_server_name = endpoint.server_name or endpoint.host,
            ssl_client_cert = endpoint.client_cert, ssl_client_priv_key = endpoint.client_key }
        if endpoint.pinned_certificate_sha256 then
            u.check(endpoint.scheme == 'https' and (endpoint.host == '127.0.0.1' or endpoint.host == '::1')
                and u.hex(endpoint.pinned_certificate_sha256), 'invalid_local_probe')
            options.ssl_verify = false -- Only this loopback health check uses an exact signed certificate pin.
            options.ssl_reused_session = false
        end
        u.check(client:connect(options), 'connect_failed', 503)
        if endpoint.pinned_certificate_sha256 then
            local tls = u.check(require('resty.openssl.ssl').from_socket(client.sock), 'health_tls', 503)
            local cert = u.check(tls:get_peer_certificate(), 'health_tls', 503)
            local bytes = u.check(cert:digest('sha256'), 'health_tls', 503)
            local fingerprint = (bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end))
            u.check(u.equal(fingerprint, endpoint.pinned_certificate_sha256), 'health_certificate_mismatch', 503)
        end
        headers = headers or {}
        headers.host = endpoint.authority or endpoint.host or 'localhost'
        headers.connection = 'close'
        local response = u.check(client:request({ method = method, path = path, headers = headers, body = body }), 'request_failed', 503)
        local size, chunks = 0, {}
        while true do
            local chunk, err = response.body_reader(32768)
            u.check(not err, 'response_failed', 503)
            if not chunk then break end
            size = size + #chunk
            u.check(size <= (maximum or u.MAX_BYTES * 2), 'response_size', 413)
            chunks[#chunks + 1] = chunk
        end
        client:close()
        return { status = response.status, headers = response.headers, body = table.concat(chunks) }
        end)
        return { ok = ok, value = value }
    end)
    local deadline = ngx.thread.spawn(function() ngx.sleep((endpoint.total_ms or 10000) / 1000); return false end)
    local ok, result = ngx.thread.wait(operation, deadline)
    ngx.thread.kill(operation)
    ngx.thread.kill(deadline)
    if client then pcall(client.close, client) end
    if not ok then
        if type(result) == 'table' and result.code then error(result, 0) end
        u.fail('network_failed', 503)
    end
    u.check(result ~= false, 'network_deadline', 503)
    if not result.ok then error(result.value, 0) end
    return result.value
end
return M
