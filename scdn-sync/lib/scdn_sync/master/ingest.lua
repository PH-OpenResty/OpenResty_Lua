local u = require 'scdn_sync.util'
local json = require 'scdn_sync.codec'
local crypto = require 'scdn_sync.crypto'
local auth = require 'scdn_sync.auth'
local M = {}; M.__index = M
local phases = u.fields('applied failed rolled_back')
function M.new(store, settings) return setmetatable({ store = store, settings = settings }, M) end

function M:index(now)
    local nodes = {}
    for id, node in pairs(self.settings.nodes) do
        if node.enabled ~= false and node.revoked ~= true then
            local bytes = self.store:read('nodes/' .. id .. '/desired.json')
            if bytes then
                local desired = json.decode(bytes)
                local history = desired.recent
                desired.recent = nil
                local releases = json.array({ desired })
                -- The publisher commits this bounded history with desired; no per-poll directory scans.
                for _, old in ipairs(history or {}) do
                    if #releases >= 8 then break end
                    if old.expires_at > now then releases[#releases + 1] = old end
                end
                nodes[id] = { desired = desired, releases = releases }
            end
        end
    end
    return { protocol = u.PROTOCOL, nodes = nodes }
end

function M:accept(request, now)
    u.check(type(request) == 'table' and not json.is_array(request), 'invalid_ingest_request')
    u.keys(request, u.fields('node_id method authority path headers body query'))
    u.check(u.id(request.node_id), 'invalid_node_identity')
    local node = self.settings.nodes[request.node_id]
    local claims = auth.verify_request(request, node, now)
    return self.store:locked('nodes/' .. claims.node_id .. '/ingest.lock', function()
        local path = 'nodes/' .. claims.node_id .. '/state.json'
        local raw = self.store:read(path)
        local state = raw and json.decode(raw) or { replays = {}, receipts = {}, heartbeat_seq = '0', report_seq = '0' }
        local replay_id = crypto.sha256(claims.key_id .. ':' .. claims.nonce)
        u.check(not state.replays[replay_id], 'request_replayed', 409)
        local replay_count = 0
        for key, expiry in pairs(state.replays) do
            if expiry < now then state.replays[key] = nil else replay_count = replay_count + 1 end
        end
        u.check(replay_count < (self.settings.max_replays_per_node or 2048), 'replay_capacity', 429)
        local input = json.decode(request.body, 65536)
        u.check(type(input) == 'table' and not json.is_array(input), 'invalid_report')
        u.check(input.protocol == u.PROTOCOL and input.node_id == claims.node_id and u.id(input.request_id), 'report_identity', 403)
        local receipt = state.receipts[input.request_id]
        if receipt then
            u.check(receipt.digest == claims.body_sha256 and receipt.path == claims.path, 'idempotency_conflict', 409)
        else
            local receipts = 0
            for _ in pairs(state.receipts) do receipts = receipts + 1 end
            -- Monotonic business sequences make old retries safe after bounded receipt pruning.
            if receipts >= 512 then
                local oldest, oldest_time
                for key, value in pairs(state.receipts) do
                    if not oldest_time or value.accepted_at < oldest_time then oldest, oldest_time = key, value.accepted_at end
                end
                state.receipts[oldest] = nil
            end
            if request.path == '/_scdn_sync/v1/heartbeat' then
                u.keys(input, u.fields('protocol node_id request_id heartbeat_seq applied_revision'))
                u.check(u.seq(input.heartbeat_seq), 'invalid_heartbeat')
                u.check(input.applied_revision == nil or u.id(input.applied_revision), 'invalid_heartbeat')
                local comparison = u.compare(input.heartbeat_seq, state.heartbeat_seq)
                local last = state.last_heartbeat_receipt
                local retry = comparison == 0 and last and last.request_id == input.request_id and last.digest == claims.body_sha256
                u.check(comparison > 0 or retry, 'stale_heartbeat', 409)
                if not retry then
                    state.heartbeat_seq, state.last_seen_at = input.heartbeat_seq, now
                    state.observed_revision = input.applied_revision
                    state.last_heartbeat_receipt = { request_id = input.request_id, digest = claims.body_sha256 }
                end
            else
                u.keys(input, u.fields('protocol node_id request_id report_seq release_id desired_seq revision_id phase error_code'))
                u.check(u.seq(input.report_seq), 'invalid_report')
                u.check(u.id(input.revision_id) and u.id(input.release_id) and u.seq(input.desired_seq)
                    and phases[input.phase] and (not input.error_code or u.id(input.error_code)), 'invalid_report')
                u.check((input.phase == 'applied' and input.error_code == nil)
                    or (input.phase ~= 'applied' and u.id(input.error_code)), 'invalid_report')
                local comparison = u.compare(input.report_seq, state.report_seq)
                local last = state.last_report_receipt
                local retry = comparison == 0 and last and last.request_id == input.request_id and last.digest == claims.body_sha256
                u.check(comparison > 0 or retry, 'stale_report', 409)
                local metadata_bytes = self.store:read('nodes/' .. claims.node_id .. '/releases/' .. input.revision_id .. '/metadata.json')
                local metadata = metadata_bytes and json.decode(metadata_bytes)
                u.check(metadata and metadata.desired_seq == input.desired_seq and metadata.release_id == input.release_id,
                    'report_assignment', 403)
                state.report_seq = input.report_seq
                local desired_bytes = self.store:read('nodes/' .. claims.node_id .. '/desired.json')
                local desired = desired_bytes and json.decode(desired_bytes)
                if not retry and desired and desired.desired_seq == input.desired_seq then
                    local previous = state.latest_report
                    u.check(not previous or previous.revision_id ~= input.revision_id or previous.phase ~= 'applied'
                        or input.phase == 'applied', 'report_transition', 409)
                    state.latest_report = input
                    if input.phase == 'applied' then state.applied_revision = input.revision_id end
                end
                state.last_report_receipt = { request_id = input.request_id, digest = claims.body_sha256 }
            end
            state.receipts[input.request_id] = { digest = claims.body_sha256, path = claims.path, accepted_at = now }
        end
        state.replays[replay_id] = claims.replay_until
        self.store:write(path, json.encode(state))
        return { accepted = true, request_id = input.request_id }
    end)
end
return M
