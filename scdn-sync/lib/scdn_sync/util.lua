local bit = require 'bit'
local M = { VERSION = '0.2.0', PROTOCOL = 'scdn.sync.v1', MAX_BYTES = 4 * 1024 * 1024 }

function M.fail(code, status)
    error({ code = code, status = status or 400 }, 0)
end

function M.check(value, code, status)
    if not value then M.fail(code, status) end
    return value
end

function M.id(value)
    return type(value) == 'string' and #value > 0 and #value <= 96
        and value:match('^[A-Za-z0-9][A-Za-z0-9_-]*$') ~= nil
end

function M.hex(value)
    return type(value) == 'string' and #value == 64 and value:match('^[a-f0-9]+$') ~= nil
end

function M.seq(value)
    return type(value) == 'string' and #value <= 32
        and (value == '0' or value:match('^[1-9][0-9]*$') ~= nil)
end

function M.compare(a, b)
    M.check(M.seq(a) and M.seq(b), 'invalid_sequence')
    if #a ~= #b then return #a < #b and -1 or 1 end
    if a == b then return 0 end
    return a < b and -1 or 1
end

function M.increment(value)
    M.check(M.seq(value), 'invalid_sequence')
    local out, carry = {}, 1
    for i = #value, 1, -1 do
        local n = value:byte(i) - 48 + carry
        carry = n >= 10 and 1 or 0
        out[i] = string.char(48 + n % 10)
    end
    local result = (carry == 1 and '1' or '') .. table.concat(out)
    return M.check(M.seq(result) and result, 'sequence_exhausted')
end

function M.equal(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' or #a ~= #b then return false end
    local difference = 0
    for i = 1, #a do difference = bit.bor(difference, bit.bxor(a:byte(i), b:byte(i))) end
    return difference == 0
end

function M.keys(value, allowed)
    M.check(type(value) == 'table', 'expected_object')
    for key in pairs(value) do M.check(allowed[key], 'unknown_field') end
end

function M.fields(names)
    local out = {}
    for name in names:gmatch('%S+') do out[name] = true end
    return out
end

function M.integer(value, minimum, maximum)
    return type(value) == 'number' and value == math.floor(value)
        and value >= minimum and value <= maximum
end

function M.decimal(value)
    M.check(M.integer(value, 0, 9007199254740991), 'invalid_integer')
    return string.format('%.0f', value)
end

function M.error_code(err)
    if type(err) == 'table' and type(err.code) == 'string' then return err.code, err.status or 400 end
    return 'internal_error', 500
end

function M.try(fn, ...)
    local result = { pcall(fn, ...) }
    if not result[1] then return nil, result[2] end
    return unpack(result, 2)
end

return M
