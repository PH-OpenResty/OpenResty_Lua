local u = require 'scdn_sync.util'
local json = require 'scdn_sync.codec'
local crypto = require 'scdn_sync.crypto'
local M = {}; M.__index = M
function M.new(store, node_id, capacity)
    return setmetatable({ store = store, node_id = node_id, capacity = capacity or 256, reserved = {} }, M)
end
function M:entries()
    local entries = {}
    for _, name in ipairs(self.store:list('reports', self.capacity + 64)) do
        if name:match('^[a-f0-9]+%.json$') then
            local raw = self.store:read('reports/' .. name, 65536)
            if raw then entries[#entries + 1] = { name = name, value = json.decode(raw, 65536) } end
        end
    end
    table.sort(entries, function(a, b) return u.compare(a.value.sequence, b.value.sequence) < 0 end)
    return entries
end
function M:available()
    local count = #self:entries()
    for _ in pairs(self.reserved) do count = count + 1 end
    return count < self.capacity
end
function M:reserve(path)
    u.check(path == '/_scdn_sync/v1/reports' or path == '/_scdn_sync/v1/heartbeat', 'outbox_route')
    u.check(self:available(), 'outbox_full', 503)
    local raw = self.store:read('outbound-sequence')
    local seq = u.increment(raw or '0')
    self.store:write('outbound-sequence', seq)
    local reservation = { path = path, sequence = seq, request_id = crypto.sha256(crypto.random(16)):sub(1, 32) }
    self.reserved[reservation.request_id] = true
    return reservation
end
function M:cancel(reservation)
    self.reserved[reservation.request_id] = nil
end
function M:enqueue(reservation, fields)
    local input = { protocol = u.PROTOCOL, node_id = self.node_id, request_id = reservation.request_id }
    for key, value in pairs(fields) do input[key] = value end
    if reservation.path == '/_scdn_sync/v1/reports' then input.report_seq = reservation.sequence
    else input.heartbeat_seq = reservation.sequence end
    local entry = { path = reservation.path, sequence = reservation.sequence, body = json.encode(input) }
    local path = 'reports/' .. reservation.request_id .. '.json'
    local old = self.store:read(path, 65536)
    local bytes = json.encode(entry)
    u.check(not old or old == bytes, 'outbox_conflict', 409)
    u.check(old or #self:entries() < self.capacity, 'outbox_full', 503)
    self.store:write(path, bytes)
    self.reserved[reservation.request_id] = nil
    return entry
end
function M:flush(send, maximum)
    local sent = 0
    for _, entry in ipairs(self:entries()) do
        if sent >= (maximum or 8) then break end
        -- Visibility alone is insufficient after an ambiguous rename/fsync failure.
        self.store:write('reports/' .. entry.name, json.encode(entry.value))
        local result = send(entry.value.path, entry.value.body)
        u.check(result.status == 200, 'report_not_acknowledged', 503)
        local ack = json.decode(result.body, 65536)
        local original = json.decode(entry.value.body, 65536)
        u.check(ack.accepted == true and ack.request_id == original.request_id, 'invalid_report_ack', 503)
        self.store:remove('reports/' .. entry.name)
        sent = sent + 1
    end
    return sent
end
return M
