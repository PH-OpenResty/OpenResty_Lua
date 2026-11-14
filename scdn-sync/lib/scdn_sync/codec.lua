-- Strict, bounded JSON parsing: rejects duplicate (including escaped) keys.
-- cjson is used only for scalar string escaping/unescaping and numbers.
local cjson = require 'cjson.safe'
local u = require 'scdn_sync.util'
local M = { null = cjson.null }
local array_mt, object_mt = {}, {}
function M.array(value) return setmetatable(value or {}, array_mt) end
function M.object(value) return setmetatable(value or {}, object_mt) end
function M.is_array(value) return type(value) == 'table' and getmetatable(value) == array_mt end

function M.decode(text, limit)
    u.check(type(text) == 'string' and #text <= (limit or u.MAX_BYTES), 'json_size', 413)
    local pos, count = 1, 0
    local function ws()
        while text:sub(pos, pos):match('[ \t\r\n]') and pos <= #text do pos = pos + 1 end
    end
    local function quoted()
        local start = pos
        u.check(text:sub(pos, pos) == '"', 'invalid_json')
        pos = pos + 1
        while pos <= #text do
            local byte = text:byte(pos)
            if byte == 34 then
                pos = pos + 1
                return u.check(cjson.decode(text:sub(start, pos - 1)), 'invalid_json_string')
            end
            u.check(byte >= 32, 'invalid_json_string')
            if byte == 92 then pos = pos + 1 end
            pos = pos + 1
        end
        u.fail('invalid_json_string')
    end
    local parse
    parse = function(depth)
        count = count + 1
        u.check(depth <= 32 and count <= 100000, 'json_complexity', 413)
        ws()
        local ch = text:sub(pos, pos)
        if ch == '"' then return quoted() end
        if ch == '{' or ch == '[' then
            pos = pos + 1
            ws()
            local is_array = ch == '['
            local out = is_array and M.array() or M.object()
            local close = is_array and ']' or '}'
            if text:sub(pos, pos) == close then pos = pos + 1; return out end
            local seen = {}
            while true do
                ws()
                local key
                if is_array then key = #out + 1
                else
                    key = quoted()
                    u.check(not seen[key], 'duplicate_json_key')
                    seen[key] = true
                    ws()
                    u.check(text:sub(pos, pos) == ':', 'invalid_json')
                    pos = pos + 1
                end
                out[key] = parse(depth + 1)
                ws()
                local separator = text:sub(pos, pos)
                pos = pos + 1
                if separator == close then return out end
                u.check(separator == ',', 'invalid_json')
            end
        end
        for literal, value in pairs({ ['true'] = true, ['false'] = false, ['null'] = cjson.null }) do
            if text:sub(pos, pos + #literal - 1) == literal then pos = pos + #literal; return value end
        end
        local first, last = text:find('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
        local token = first and text:sub(first, last)
        u.check(token and #token > 0, 'invalid_json')
        local integer, rest = token:match('^(-?%d+)(.*)$')
        local unsigned = integer:gsub('^-', '')
        u.check(#unsigned == 1 or unsigned:sub(1, 1) ~= '0', 'invalid_json_number')
        if rest:sub(1, 1) == '.' then
            local fractional = rest:match('^%.%d+')
            u.check(fractional, 'invalid_json_number'); rest = rest:sub(#fractional + 1)
        end
        u.check(rest == '' or rest:match('^[eE][+-]?%d+$'), 'invalid_json_number')
        local number = cjson.decode(token)
        u.check(type(number) == 'number' and number == number and math.abs(number) < math.huge, 'invalid_json_number')
        pos = pos + #token
        return number
    end
    local value = parse(0)
    ws()
    u.check(pos == #text + 1, 'invalid_json')
    return value
end

function M.encode(value)
    local active = {}
    local function encode(v, depth)
        u.check(depth <= 32, 'json_complexity')
        if v == cjson.null then return 'null' end
        local typ = type(v)
        if typ == 'table' then
            u.check(not active[v], 'json_cycle')
            active[v] = true
            local out = {}
            if M.is_array(v) or #v > 0 then
                for i = 1, #v do out[i] = encode(v[i], depth + 1) end
                for k in pairs(v) do u.check(u.integer(k, 1, #v), 'invalid_array') end
                active[v] = nil
                return '[' .. table.concat(out, ',') .. ']'
            end
            local keys = {}
            for k in pairs(v) do u.check(type(k) == 'string', 'invalid_object_key'); keys[#keys + 1] = k end
            table.sort(keys)
            for _, key in ipairs(keys) do out[#out + 1] = cjson.encode(key) .. ':' .. encode(v[key], depth + 1) end
            active[v] = nil
            return '{' .. table.concat(out, ',') .. '}'
        end
        u.check(typ == 'string' or typ == 'boolean' or (typ == 'number' and v == v and math.abs(v) < math.huge), 'invalid_json_value')
        if typ == 'number' and v == math.floor(v) and math.abs(v) <= 9007199254740991 then
            return string.format('%.0f', v)
        end
        return u.check(cjson.encode(v), 'invalid_json_value')
    end
    return encode(value, 0)
end

function M.b64(value)
    return (ngx.encode_base64(value):gsub('%+', '-'):gsub('/', '_'):gsub('=', ''))
end
function M.unb64(value, limit)
    u.check(type(value) == 'string' and #value <= (limit or u.MAX_BYTES) * 2
        and value:match('^[A-Za-z0-9_-]*$') and #value % 4 ~= 1, 'invalid_base64')
    local decoded = ngx.decode_base64(value:gsub('-', '+'):gsub('_', '/') .. string.rep('=', (4 - #value % 4) % 4))
    u.check(decoded and M.b64(decoded) == value and #decoded <= (limit or u.MAX_BYTES), 'invalid_base64')
    return decoded
end

return M
