-- Parse operator site files as data. No loadfile, bytecode, globals or function calls.
-- Supported: return { ... }, string/boolean/decimal literals, arrays, named keys,
-- quoted keys, line/long comments and Lua string escapes.
local u = require 'scdn_sync.util'
local json = require 'scdn_sync.codec'
local M = {}
function M.decode(text)
    u.check(type(text) == 'string' and #text <= 262144 and text:byte(1) ~= 27, 'site_source_size')
    if text:sub(1, 3) == '\239\187\191' then text = text:sub(4) end
    local pos, count = 1, 0
    local function long_string()
        local equals = text:match('^%[(=*)%[', pos)
        if not equals then return nil end
        local start = pos + #equals + 2
        local first, last = text:find(']' .. equals .. ']', start, true)
        u.check(first, 'invalid_site_source')
        pos = last + 1
        return (text:sub(start, first - 1):gsub('^\r?\n', ''))
    end
    local function ws()
        while pos <= #text do
            if text:sub(pos, pos):match('%s') then pos = pos + 1
            elseif text:sub(pos, pos + 1) == '--' then
                pos = pos + 2
                if not long_string() then pos = (text:find('\n', pos, true) or #text) + 1 end
            else return end
        end
    end
    local escapes = { a = '\a', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t', v = '\v',
        ['\\'] = '\\', ['"'] = '"', ["'"] = "'" }
    local function quoted()
        local quote, out = text:sub(pos, pos), {}
        pos = pos + 1
        while pos <= #text do
            local ch = text:sub(pos, pos); pos = pos + 1
            if ch == quote then return table.concat(out) end
            u.check(ch ~= '\n' and ch ~= '\r', 'invalid_site_source')
            if ch == '\\' then
                ch = text:sub(pos, pos); pos = pos + 1
                if escapes[ch] then out[#out + 1] = escapes[ch]
                elseif ch:match('%d') then
                    local digits = text:match('^%d%d?%d?', pos - 1)
                    local n = tonumber(digits); u.check(n <= 255, 'invalid_site_source')
                    pos = pos + #digits - 1; out[#out + 1] = string.char(n)
                elseif ch == 'x' then
                    local digits = text:sub(pos, pos + 1)
                    u.check(digits:match('^%x%x$'), 'invalid_site_source')
                    pos = pos + 2; out[#out + 1] = string.char(tonumber(digits, 16))
                elseif ch == 'z' then
                    while text:sub(pos, pos):match('%s') and pos <= #text do pos = pos + 1 end
                elseif ch == '\n' or ch == '\r' then
                    if ch == '\r' and text:sub(pos, pos) == '\n' then pos = pos + 1 end
                    out[#out + 1] = '\n'
                else u.fail('invalid_site_source') end
            else out[#out + 1] = ch end
        end
        u.fail('invalid_site_source')
    end
    local function word() return text:match('^[A-Za-z_][A-Za-z0-9_]*', pos) end
    local parse
    parse = function(depth)
        count = count + 1
        u.check(depth <= 24 and count <= 20000, 'site_source_complexity', 413)
        ws()
        local ch = text:sub(pos, pos)
        if ch == '"' or ch == "'" then return quoted() end
        if ch == '[' then return u.check(long_string(), 'invalid_site_source') end
        if ch == '{' then
            pos = pos + 1; ws()
            local out, seen, mode = {}, {}, nil
            while text:sub(pos, pos) ~= '}' do
                local start, key = pos
                if text:sub(pos, pos) == '[' then
                    -- Only ["key"] / ['key'] are map keys; a long string is a value.
                    pos = pos + 1; ws()
                    if text:sub(pos, pos) == '"' or text:sub(pos, pos) == "'" then
                        key = quoted(); ws()
                        u.check(text:sub(pos, pos) == ']', 'invalid_site_source')
                        pos = pos + 1; ws()
                        u.check(text:sub(pos, pos) == '=', 'invalid_site_source')
                    else pos = start end
                else
                    local identifier = word()
                    if identifier then
                        pos = pos + #identifier; ws()
                        if text:sub(pos, pos) == '=' then key = identifier else pos = start end
                    end
                end
                if key then
                    u.check(mode ~= 'array' and not seen[key], 'invalid_site_source')
                    mode, seen[key] = 'object', true; pos = pos + 1
                    out[key] = parse(depth + 1)
                else
                    u.check(mode ~= 'object', 'invalid_site_source'); mode = 'array'
                    out[#out + 1] = parse(depth + 1)
                end
                ws()
                local separator = text:sub(pos, pos)
                if separator ~= '}' then
                    u.check(separator == ',' or separator == ';', 'invalid_site_source')
                    pos = pos + 1; ws()
                end
            end
            pos = pos + 1
            return mode == 'array' and json.array(out) or out
        end
        local literal = word()
        if literal == 'true' or literal == 'false' then pos = pos + #literal; return literal == 'true' end
        local first, last = text:find('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
        u.check(first and last >= first, 'invalid_site_source')
        local number = json.decode(text:sub(first, last)); pos = last + 1
        return number
    end
    ws(); u.check(word() == 'return', 'invalid_site_source'); pos = pos + 6
    local value = parse(0); ws()
    if text:sub(pos, pos) == ';' then pos = pos + 1; ws() end
    u.check(pos > #text and type(value) == 'table' and not json.is_array(value), 'invalid_site_source')
    return value
end
return M
