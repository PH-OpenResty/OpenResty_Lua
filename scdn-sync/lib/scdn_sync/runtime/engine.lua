-- Immutable generations. No file/network IO is performed by this runtime.
local u = require 'scdn_sync.util'
local json = require 'scdn_sync.codec'
local crypto = require 'scdn_sync.crypto'
local validate = require 'scdn_sync.validate'
local M = {}; M.__index = M
function M.new(data, state, locks, settings, ssl, worker, clock)
    return setmetatable({ data = data, state = state, locks = locks, settings = settings,
        ssl = ssl, worker = worker, clock = clock, snapshots = {},
        boot = crypto.sha256(crypto.random(16)):sub(1, 24) }, M)
end
local function set(dict, key, value, ttl)
    u.check(dict:safe_set(key, value, ttl or 0), 'runtime_capacity', 507)
end
local function input_object(input, fields)
    u.check(type(input) == 'table' and not json.is_array(input), 'invalid_control_input')
    u.keys(input, u.fields(fields))
    u.check(u.id(input.transaction_id), 'invalid_transaction')
end
function M:locked(fn)
    local lock = u.check(require('resty.lock'):new(self.locks, { timeout = 0, exptime = 5 }), 'runtime_lock', 503)
    u.check(lock:lock('generation'), 'runtime_busy', 409)
    local ok, value = pcall(fn)
    lock:unlock()
    if not ok then error(value, 0) end
    return value
end
function M:transaction()
    local raw = self.state:get('transaction')
    return raw and json.decode(raw)
end
function M:prepare(revision)
    if self.snapshots[revision] then return self.snapshots[revision] end
    local raw = u.check(self.data:get('snapshot:' .. revision), 'snapshot_missing', 503)
    local value = json.decode(raw, self.settings.max_snapshot_bytes or u.MAX_BYTES)
    u.check(value.protocol == u.PROTOCOL and value.node_id == self.settings.node_id and value.scope_id == self.settings.scope_id
        and value.revision_id == revision and u.seq(value.desired_seq), 'runtime_identity')
    local snapshot = { revision_id = revision, desired_seq = value.desired_seq, hosts = {}, host_list = json.array(), certificates = {} }
    u.check(json.is_array(value.sites) and #value.sites <= (self.settings.max_sites or 1000)
        and json.is_array(value.certificates) and #value.certificates <= 1000, 'runtime_size')
    for _, cert in ipairs(value.certificates) do
        u.check(u.id(cert.certificate_id) and u.integer(cert.version, 1, 9007199254740991)
            and type(cert.chain_pem) == 'string' and #cert.chain_pem <= 262144
            and type(cert.private_key_pem) == 'string' and #cert.private_key_pem <= 65536
            and u.hex(cert.fingerprint) and type(cert.not_after) == 'number', 'runtime_certificate')
        local ref = cert.certificate_id .. ':' .. u.decimal(cert.version)
        u.check(not snapshot.certificates[ref], 'duplicate_certificate')
        snapshot.certificates[ref] = { cert = u.check(self.ssl.parse_pem_cert(cert.chain_pem), 'runtime_certificate'),
            key = u.check(self.ssl.parse_pem_priv_key(cert.private_key_pem), 'runtime_certificate'),
            fingerprint = cert.fingerprint, not_after = cert.not_after }
        if self.settings.yield_prepare then self.settings.yield_prepare() end
    end
    local ids, hosts = {}, {}
    for _, site in ipairs(value.sites) do
        validate.site(site, self.settings)
        u.check(not ids[site.site_id], 'duplicate_site'); ids[site.site_id] = true
        if site.enabled and site.ssl.enabled then u.check(snapshot.certificates[site.ssl.certificate_id .. ':' .. u.decimal(site.ssl.certificate_version)], 'missing_certificate') end
        for _, host in ipairs(site.server_names) do
            u.check(not hosts[host], 'host_conflict'); hosts[host] = true
            if site.enabled then snapshot.hosts[host] = site; snapshot.host_list[#snapshot.host_list + 1] = host end
        end
        if self.settings.yield_prepare then self.settings.yield_prepare() end
    end
    table.sort(snapshot.host_list)
    self.snapshots[revision] = snapshot
    return snapshot
end
function M:tick()
    local active, tx = self.state:get('active'), self:transaction()
    local status = { pid = self.worker.pid(), boot = self.boot, updated_at = self.clock() }
    if active then
        local ok, err = pcall(self.prepare, self, active)
        if ok then status.active_revision = active else status.error = u.error_code(err) end
    end
    if tx then
        local ok, err = pcall(self.prepare, self, tx.revision_id)
        if ok then status.prepared_transaction = tx.transaction_id
        else status.error = u.error_code(err) end
    end
    set(self.state, 'worker:' .. self.worker.id(), json.encode(status), 10)
    -- Keep the rollback generation while a transaction is in progress.
    for revision in pairs(self.snapshots) do
        if revision ~= active and (not tx or (revision ~= tx.revision_id and revision ~= tx.previous)) then
            self.snapshots[revision] = nil
        end
    end
    return status
end
function M:workers()
    local result = json.array()
    for i = 0, self.worker.count() - 1 do
        local raw = self.state:get('worker:' .. i)
        local worker = raw and json.decode(raw) or { missing = true }
        worker.id = i
        result[#result + 1] = worker
    end
    return result
end
function M:stage(input)
    input_object(input, 'transaction_id expected_revision snapshot')
    u.check(input.expected_revision == nil or u.id(input.expected_revision), 'invalid_previous_revision')
    u.check(u.id(input.transaction_id) and type(input.snapshot) == 'table', 'invalid_stage')
    local snapshot = input.snapshot
    u.check(u.id(snapshot.revision_id) and snapshot.node_id == self.settings.node_id
        and snapshot.scope_id == self.settings.scope_id and u.seq(snapshot.desired_seq), 'runtime_identity')
    local encoded = json.encode(snapshot)
    u.check(#encoded <= (self.settings.max_snapshot_bytes or u.MAX_BYTES), 'runtime_size', 413)
    return self:locked(function()
        local existing = self:transaction()
        if existing then
            u.check(existing.transaction_id == input.transaction_id and existing.revision_id == snapshot.revision_id
                and existing.sha256 == crypto.sha256(encoded), 'runtime_transaction_conflict', 409)
            return existing
        end
        local previous = self.state:get('active')
        u.check((input.expected_revision or '') == (previous or ''), 'runtime_previous_conflict', 409)
        local highest_bytes = self.state:get('highest')
        local highest = highest_bytes and json.decode(highest_bytes) or { desired_seq = '0' }
        local comparison = u.compare(snapshot.desired_seq, highest.desired_seq)
        u.check(comparison > 0 or (comparison == 0 and highest.revision_id == snapshot.revision_id
            and highest.sha256 == crypto.sha256(encoded)), 'runtime_stale_sequence', 409)
        local old = self.data:get('snapshot:' .. snapshot.revision_id)
        u.check(not old or old == encoded, 'immutable_snapshot_conflict', 409)
        set(self.data, 'snapshot:' .. snapshot.revision_id, encoded)
        local tx = { transaction_id = input.transaction_id, revision_id = snapshot.revision_id,
            desired_seq = snapshot.desired_seq, previous = previous, sha256 = crypto.sha256(encoded), phase = 'preparing' }
        local ok, err = pcall(set, self.state, 'transaction', json.encode(tx))
        if not ok then
            if not old then self.data:delete('snapshot:' .. snapshot.revision_id) end
            error(err, 0)
        end
        return tx
    end)
end
function M:commit(input)
    input_object(input, 'transaction_id')
    return self:locked(function()
        local tx = self:transaction()
        u.check(tx and tx.transaction_id == input.transaction_id, 'runtime_transaction_conflict', 409)
        if tx.phase == 'committed' and self.state:get('active') == tx.revision_id then return tx end
        u.check((tx.phase == 'preparing' or tx.phase == 'committed')
            and (self.state:get('active') or '') == (tx.previous or ''), 'runtime_previous_conflict', 409)
        for _, worker in ipairs(self:workers()) do
            u.check(not worker.missing and self.clock() - worker.updated_at <= 5
                and worker.prepared_transaction == tx.transaction_id and not worker.error, 'workers_not_ready', 409)
        end
        -- Highest is advanced first. A capacity failure can stall a retry, never admit an older version.
        set(self.state, 'highest', json.encode({ desired_seq = tx.desired_seq, revision_id = tx.revision_id, sha256 = tx.sha256 }))
        tx.phase = 'committed'
        set(self.state, 'transaction', json.encode(tx))
        set(self.state, 'active', tx.revision_id)
        return tx
    end)
end
function M:rollback(input)
    input_object(input, 'transaction_id')
    return self:locked(function()
        local tx = self:transaction()
        u.check(tx and tx.transaction_id == input.transaction_id, 'runtime_transaction_conflict', 409)
        u.check(tx.phase == 'committed' or tx.phase == 'rolled_back', 'runtime_rollback_phase', 409)
        if tx.previous then set(self.state, 'active', tx.previous) else self.state:delete('active') end
        tx.phase = 'rolled_back'
        set(self.state, 'transaction', json.encode(tx))
        return tx
    end)
end
function M:finalize(input)
    input_object(input, 'transaction_id abort')
    u.check(input.abort == nil or type(input.abort) == 'boolean', 'invalid_abort')
    return self:locked(function()
        local tx = self:transaction()
        if not tx then return { finalized = true } end
        u.check(tx.transaction_id == input.transaction_id, 'runtime_transaction_conflict', 409)
        u.check(tx.phase == 'committed' or tx.phase == 'rolled_back'
            or (tx.phase == 'preparing' and input.abort == true), 'runtime_finalize_phase', 409)
        local active = self.state:get('active')
        for _, revision in ipairs({ tx.revision_id, tx.previous or '' }) do
            if revision ~= '' and revision ~= active then self.data:delete('snapshot:' .. revision) end
        end
        self.state:delete('transaction')
        return { finalized = true }
    end)
end
function M:status()
    return { active_revision = self.state:get('active'), transaction = self:transaction(), workers = self:workers() }
end
function M:current(context)
    if context and context.scdn_sync_snapshot then return context.scdn_sync_snapshot end
    local active = self.state:get('active')
    if not active then return nil end
    local snapshot = self.snapshots[active]
    u.check(snapshot, 'worker_not_ready', 503)
    if context then context.scdn_sync_snapshot = snapshot end
    return snapshot
end
function M:lookup(host, context)
    local snapshot = self:current(context)
    return snapshot and snapshot.hosts[host]
end
function M:set_certificate(host)
    local snapshot = self:current()
    local site = snapshot and snapshot.hosts[host]
    u.check(site and site.ssl.enabled, 'unknown_sni', 403)
    local pair = snapshot.certificates[site.ssl.certificate_id .. ':' .. u.decimal(site.ssl.certificate_version)]
    u.check(pair and pair.not_after > self.clock(), 'certificate_expired', 503)
    u.check(self.ssl.clear_certs(), 'tls_install_failed', 503)
    u.check(self.ssl.set_cert(pair.cert), 'tls_install_failed', 503)
    u.check(self.ssl.set_priv_key(pair.key), 'tls_install_failed', 503)
    return true
end
return M
