local u = require 'scdn_sync.util'
local json = require 'scdn_sync.codec'
local M = {}
function M.reply(status, value)
    local body = type(value) == 'string' and value or json.encode(value)
    ngx.status = status
    ngx.header['Content-Type'] = 'application/json'
    ngx.header['Content-Length'] = #body
    ngx.header['Cache-Control'] = 'no-store'
    ngx.print(body)
    return ngx.exit(status)
end
function M.body(limit, seconds)
    -- Fixed HTTP/1.1 profile: a size limit and an absolute deadline, including slow sends.
    u.check(not ngx.var.http_transfer_encoding, 'transfer_encoding_not_allowed', 400)
    local length = tonumber(ngx.var.content_length)
    u.check(u.integer(length, 0, limit), 'body_size_or_length_required', length and 413 or 411)
    u.check(not ngx.req.get_body_file(), 'body_size', 413)
    local buffered = ngx.req.get_body_data()
    if buffered then return u.check(#buffered == length and buffered, 'body_size', 413) end
    if length == 0 then return '' end
    local socket = u.check(ngx.req.socket(), 'body_unavailable')
    local reading = ngx.thread.spawn(function()
        local ok, value = pcall(function()
            socket:settimeout((seconds or 5) * 1000)
            local chunks, size = {}, 0
            while size < length do
                local chunk = u.check(socket:receive(math.min(32768, length - size)), 'body_incomplete', 400)
                size = size + #chunk; chunks[#chunks + 1] = chunk
            end
            return table.concat(chunks)
        end)
        return { ok = ok, value = value }
    end)
    local deadline = ngx.thread.spawn(function() ngx.sleep(seconds or 5); return false end)
    local ok, result = ngx.thread.wait(reading, deadline)
    ngx.thread.kill(reading); ngx.thread.kill(deadline)
    u.check(ok and result ~= false, 'body_deadline', 408)
    if not result.ok then error(result.value, 0) end
    return result.value
end
function M.handle(fn)
    local ok, result = pcall(fn)
    if not ok then
        local code, status = u.error_code(result)
        if status == 400 or status == 408 or status == 411 or status == 413 then ngx.header['Connection'] = 'close' end
        return M.reply(status, { ok = false, error = code })
    end
    return result
end
function M.headers()
    local headers, err = ngx.req.get_headers(32)
    u.check(not err, 'header_size', 431)
    local out = {}
    for key, value in pairs(headers) do
        u.check(type(value) == 'string', 'duplicate_header')
        out[key:lower()] = value
    end
    return out
end
return M
