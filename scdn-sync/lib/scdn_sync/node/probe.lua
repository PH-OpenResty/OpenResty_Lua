local u = require 'scdn_sync.util'
local http = require 'scdn_sync.http'
local M = {}
function M.new(settings)
    u.check(u.integer(settings.http_port, 1, 65535) and u.integer(settings.https_port, 1, 65535), 'probe_ports')
    return function(snapshot)
        local deadline = ngx.now() + (settings.total_seconds or 30)
        local function request(endpoint)
            u.check(ngx.now() < deadline, 'health_deadline', 503)
            endpoint.total_ms = math.min(endpoint.total_ms or 3000, math.max(1, math.floor((deadline - ngx.now()) * 1000)))
            local response = http.request(endpoint, 'GET', '/__scdn_sync_probe', nil, nil, 1024)
            u.check(ngx.now() < deadline, 'health_deadline', 503)
            return response
        end
        local certificates = {}
        for _, cert in ipairs(snapshot.certificates) do certificates[cert.certificate_id .. ':' .. u.decimal(cert.version)] = cert end
        for _, site in ipairs(snapshot.sites) do
            if site.enabled then
                for _, host in ipairs(site.server_names) do
                    local endpoint = { scheme = 'http', host = '127.0.0.1', authority = host, port = settings.http_port,
                        connect_ms = 1000, read_ms = 1000, total_ms = 3000 }
                    local response = request(endpoint)
                    u.check(response.status == 204 and response.headers['X-Scdn-Revision'] == snapshot.revision_id,
                        'health_route_mismatch', 503)
                    if site.ssl.enabled then
                        local pair = certificates[site.ssl.certificate_id .. ':' .. u.decimal(site.ssl.certificate_version)]
                        endpoint.scheme, endpoint.port, endpoint.server_name = 'https', settings.https_port, host
                        endpoint.pinned_certificate_sha256 = pair.fingerprint
                        response = request(endpoint)
                        u.check(response.status == 204 and response.headers['X-Scdn-Revision'] == snapshot.revision_id,
                            'health_tls_route_mismatch', 503)
                    end
                end
            end
        end
        local unknown = request({ scheme = 'http', host = '127.0.0.1', authority = 'unknown.scdn.invalid',
            port = settings.http_port, total_ms = 3000 })
        u.check(unknown.status == 403, 'health_unknown_host', 503)
        return true
    end
end
return M
