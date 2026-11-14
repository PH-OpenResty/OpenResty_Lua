-- 轻量流量统计: log 阶段累加到共享内存, /metrics 输出 Prometheus 文本格式
local _M = {}
local DICT = "metrics_dict"

function _M.record()
    local d = ngx.shared[DICT]
    if not d then return end
    local site = (ngx.ctx.site and ngx.ctx.site.name) or "_unknown"
    local status = ngx.status or 0
    local class = math.floor(status / 100) .. "xx"
    local bytes = tonumber(ngx.var.bytes_sent) or 0
    local cache = ngx.var.upstream_cache_status
    if not cache or cache == "" then cache = "none" end

    d:incr("req|" .. site, 1, 0)
    d:incr("bytes|" .. site, bytes, 0)
    d:incr("status|" .. site .. "|" .. class, 1, 0)
    d:incr("cache|" .. site .. "|" .. cache, 1, 0)
end

local function esc(s)
    return (s:gsub('\\', '\\\\'):gsub('"', '\\"'))
end

function _M.render()
    local d = ngx.shared[DICT]
    local lines = {
        "# HELP nginx_http_requests_total Total HTTP requests per vhost",
        "# TYPE nginx_http_requests_total counter",
    }
    local keys = d:get_keys(0)
    table.sort(keys)
    for _, k in ipairs(keys) do
        local site = k:match("^req|(.+)$")
        if site then
            lines[#lines + 1] = string.format('nginx_http_requests_total{site="%s"} %d', esc(site), d:get(k))
        end
    end
    lines[#lines + 1] = "# HELP nginx_http_bytes_total Bytes sent per vhost"
    lines[#lines + 1] = "# TYPE nginx_http_bytes_total counter"
    for _, k in ipairs(keys) do
        local site = k:match("^bytes|(.+)$")
        if site then
            lines[#lines + 1] = string.format('nginx_http_bytes_total{site="%s"} %d', esc(site), d:get(k))
        end
    end
    lines[#lines + 1] = "# HELP nginx_http_responses_total Responses by status class"
    lines[#lines + 1] = "# TYPE nginx_http_responses_total counter"
    for _, k in ipairs(keys) do
        local site, class = k:match("^status|([^|]+)|(.+)$")
        if site then
            lines[#lines + 1] = string.format('nginx_http_responses_total{site="%s",class="%s"} %d', esc(site), class, d:get(k))
        end
    end
    lines[#lines + 1] = "# HELP nginx_cache_requests_total Requests by cache status"
    lines[#lines + 1] = "# TYPE nginx_cache_requests_total counter"
    for _, k in ipairs(keys) do
        local site, st = k:match("^cache|([^|]+)|(.+)$")
        if site then
            lines[#lines + 1] = string.format('nginx_cache_requests_total{site="%s",status="%s"} %d', esc(site), st, d:get(k))
        end
    end
    ngx.header["Content-Type"] = "text/plain; version=0.0.4"
    ngx.print(table.concat(lines, "\n"), "\n")
end

return _M
