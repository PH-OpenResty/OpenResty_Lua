local u = require 'scdn_sync.util'
local json = require 'scdn_sync.codec'
local crypto = require 'scdn_sync.crypto'
local source = require 'scdn_sync.master.source'
local M = {}; M.__index = M
function M.new(store, settings, reader)
    local watch = u.check(settings.watch, 'watch_config')
    u.check(type(watch.scopes) == 'table' and #watch.scopes >= 1 and #watch.scopes <= 16, 'watch_scopes')
    local poll, settle, ttl, renew = watch.poll_seconds or 1, watch.settle_seconds or 2,
        watch.ttl_seconds or 3600, watch.renew_before_seconds or 300
    u.check(type(poll) == 'number' and poll >= 0.1 and poll <= 60 and type(settle) == 'number'
        and settle >= poll and settle <= 120 and u.integer(ttl, 60, 86400)
        and u.integer(renew, 1, math.floor(ttl / 2)), 'watch_timing')
    local self = setmetatable({ store = store, settings = settings, poll = poll, settle = settle,
        ttl = ttl, renew = renew, scopes = {}, publisher = require('scdn_sync.master.publish').new(store, settings) }, M)
    local seen, nodes = {}, {}
    for _, scope in ipairs(watch.scopes) do
        u.check(u.id(scope.scope_id) and not seen[scope.scope_id] and type(scope.node_ids) == 'table'
            and #scope.node_ids > 0 and #scope.node_ids <= 1000, 'watch_scope')
        seen[scope.scope_id] = true
        local targets = {}
        for _, id in ipairs(scope.node_ids) do
            local node = settings.nodes[id]
            u.check(u.id(id) and not nodes[id] and node and node.scope_id == scope.scope_id, 'watch_target')
            nodes[id] = true; targets[#targets + 1] = { node_id = id }
        end
        self.scopes[#self.scopes + 1] = { config = scope, source = source.new(scope, reader), targets = targets }
    end
    return self
end
function M:version(scope, kind, id, digest, minimum)
    local path = 'watch/' .. scope .. '/' .. kind .. '/' .. id .. '.json'
    local bytes = self.store:read(path)
    local previous = bytes and json.decode(bytes)
    if previous then
        u.check(u.hex(previous.digest) and u.integer(previous.version, 1, 9007199254740991), 'watch_version_state')
        if previous.digest == digest and previous.version >= minimum then
            self.store:write(path, bytes)
            return previous.version
        end
    end
    local version = math.max(previous and previous.version + (previous.digest ~= digest and 1 or 0) or 1, minimum)
    u.check(u.integer(version, 1, 9007199254740991), 'watch_version_exhausted')
    self.store:write(path, json.encode({ digest = digest, version = version }))
    return version
end
function M:step(now)
    return self.store:locked('watch/tick.lock', function()
        local events = json.array()
        for _, scope in ipairs(self.scopes) do
            local ok, err = pcall(function()
                local captured = scope.source:capture()
                if scope.digest ~= captured.digest then
                    scope.digest, scope.since, scope.compiled = captured.digest, now, nil
                    return
                end
                if now - scope.since < self.settle then return end
                local due = false
                for _, target in ipairs(scope.targets) do
                    if target.digest ~= scope.digest or now >= target.renew_at then due = true end
                end
                if not due then return end
                if not scope.compiled then
                    scope.compiled = source.compile(captured, function(kind, id, digest, minimum)
                        return self:version(scope.config.scope_id, kind, id, digest, minimum)
                    end, now)
                end
                for _, target in ipairs(scope.targets) do
                    local node = self.settings.nodes[target.node_id]
                    local pending = target.digest ~= scope.digest or now >= target.renew_at
                    if pending and node.enabled ~= false and node.revoked ~= true
                        and (target.attempt_digest ~= scope.digest or now >= (target.retry_at or 0)) then
                        target.attempt_digest = scope.digest
                        local accepted, metadata, changed = pcall(function()
                            local input = { node_id = target.node_id, scope_id = scope.config.scope_id, ttl_seconds = self.ttl,
                                sites = scope.compiled.sites, certificates = scope.compiled.certificates }
                            local digest = crypto.sha256(json.encode({ files = scope.digest, key_id = node.decryption_key_id,
                                encryption_key = crypto.sha256(node.encryption_public_key), signing_key_id = self.settings.signing_key_id }))
                            return self.publisher:publish(input, math.floor(now), {
                                id = 'files-' .. crypto.sha256(scope.config.scope_id):sub(1, 32),
                                digest = digest, renew_before_seconds = self.renew })
                        end)
                        if accepted then
                            target.digest, target.renew_at, target.backoff = scope.digest, metadata.expires_at - self.renew, nil
                            if changed then events[#events + 1] = { node_id = target.node_id, scope_id = scope.config.scope_id,
                                revision_id = metadata.revision_id, desired_seq = metadata.desired_seq } end
                        else
                            target.backoff = math.min((target.backoff or self.poll) * 2, 60)
                            target.retry_at = now + target.backoff
                            events[#events + 1] = { node_id = target.node_id, scope_id = scope.config.scope_id,
                                error_code = u.error_code(metadata) }
                        end
                    end
                end
            end)
            if not ok then
                -- Invalid/missing/half-written sources reset the entire settling window.
                scope.digest, scope.compiled, scope.since = nil, nil, nil
                events[#events + 1] = { scope_id = scope.config.scope_id, error_code = u.error_code(err) }
            end
        end
        return events
    end)
end
function M.run(settings, store)
    local lock = store:lock('watch/process.lock')
    local self = M.new(store, settings, require('scdn_sync.fs').reader)
    local errors = {}
    while not ngx.worker.exiting() do
        local ok, events = pcall(self.step, self, ngx.now())
        if not ok then ngx.log(ngx.WARN, 'scdn watch deferred: ', (u.error_code(events)))
        else
            for _, event in ipairs(events) do
                local key = event.scope_id .. ':' .. (event.node_id or '-')
                if event.error_code then
                    local previous, now = errors[key], ngx.now()
                    if not previous or previous.code ~= event.error_code or now >= previous.until_time then
                        ngx.log(ngx.WARN, 'scdn watch deferred: scope=', event.scope_id,
                            ' node=', event.node_id or '-', ' code=', event.error_code)
                        errors[key] = { code = event.error_code, until_time = now + 30 }
                    end
                else
                    errors[key] = nil
                    ngx.log(ngx.NOTICE, 'scdn watch published: node=', event.node_id,
                        ' revision=', event.revision_id, ' seq=', event.desired_seq)
                end
            end
        end
        ngx.sleep(self.poll)
    end
    lock:release()
end
return M
