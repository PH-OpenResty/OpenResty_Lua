local u = require 'scdn_sync.util'
local json = require 'scdn_sync.codec'
local crypto = require 'scdn_sync.crypto'
local validate = require 'scdn_sync.validate'
local certificates = require 'scdn_sync.certificates'
local M = {}; M.__index = M
function M.new(store, settings, control, outbox, clock, sleep, probe)
    return setmetatable({ store = store, settings = settings, control = control, outbox = outbox,
        clock = clock, sleep = sleep, probe = probe }, M)
end
function M:read(name)
    local raw = self.store:read(name)
    return raw and json.decode(raw)
end
function M:call(action, input)
    local response = self.control(action, input)
    u.check(response.status == 200, 'local_' .. action .. '_failed', response.status == 409 and 409 or 503)
    return type(response.body) == 'string' and json.decode(response.body) or response.body
end
function M:wait(revision, transaction)
    local deadline = self.clock() + (self.settings.prepare_seconds or 15)
    repeat
        local status = self:call('status')
        local ready = #status.workers == (self.settings.worker_count or #status.workers) and #status.workers > 0
        if not transaction and (status.active_revision or '') ~= (revision or '') then ready = false end
        for _, worker in ipairs(status.workers) do
            if worker.missing or not worker.updated_at or self.clock() - worker.updated_at > 5 or worker.error then ready = false end
            if transaction then
                if worker.prepared_transaction ~= transaction then ready = false end
            elseif (worker.active_revision or '') ~= (revision or '') then ready = false end
        end
        if ready then return status end
        u.check(self.clock() < deadline, 'worker_deadline', 503)
        self.sleep(0.05)
    until false
end
local function report_fields(journal, phase, code)
    return { release_id = journal.target.release_id, desired_seq = journal.target.desired_seq,
        revision_id = journal.target.revision_id, phase = phase, error_code = code }
end
function M:recover()
    local applied, journal = self:read('applied.json'), self:read('journal.json')
    local status = self:call('status')
    if journal then
        if applied and applied.revision_id == journal.target.revision_id then
            u.check(status.active_revision == applied.revision_id, 'runtime_recovery_required', 503)
            self:wait(applied.revision_id)
            -- A previous rename may have succeeded while fsync failed. Confirm durability
            -- before treating a visible applied marker as an acknowledged commit.
            self.store:write('applied.json', json.encode(applied))
            self.outbox:enqueue(journal.reservation, report_fields(journal, 'applied'))
            self:call('finalize', { transaction_id = journal.transaction_id })
        else
            if status.transaction then
                u.check(status.transaction.transaction_id == journal.transaction_id, 'runtime_transaction_conflict', 409)
                if status.transaction.phase == 'committed' then self:call('rollback', { transaction_id = journal.transaction_id }) end
                self:wait(applied and applied.revision_id)
                self:call('finalize', { transaction_id = journal.transaction_id, abort = true })
            else
                u.check((status.active_revision or '') == (applied and applied.revision_id or ''), 'runtime_recovery_required', 503)
            end
            self.outbox:enqueue(journal.reservation, report_fields(journal, 'rolled_back', journal.error_code or 'interrupted_apply'))
        end
        self.store:remove('journal.json')
    end
    status = self:call('status')
    u.check((status.active_revision or '') == (applied and applied.revision_id or ''), 'runtime_recovery_required', 503)
    return applied
end
function M:download(signed, fetch)
    local deadline = self.clock() + (self.settings.download_seconds or 120)
    local digest = crypto.sha256(signed)
    local plaintext = crypto.decrypt(crypto.unwrap(signed, self.settings.signing_public_keys),
        self.settings.decryption_private_key, self.settings.decryption_key_id)
    local manifest = validate.manifest(json.decode(plaintext), self.settings, self.clock())
    local highest = self:read('highest.json')
    if highest then
        local comparison = u.compare(manifest.desired_seq, highest.desired_seq)
        u.check(comparison >= 0 and (comparison > 0 or highest.digest == digest), 'stale_or_conflicting_manifest', 409)
    end
    local applied = self:read('applied.json')
    if applied and applied.desired_seq == manifest.desired_seq then
        u.check(applied.digest == digest, 'immutable_manifest_conflict', 409)
        return nil, applied
    end
    self.store:write('highest.json', json.encode({ desired_seq = manifest.desired_seq, digest = digest }))
    local runtime = { protocol = u.PROTOCOL, node_id = manifest.node_id, scope_id = manifest.scope_id,
        revision_id = manifest.revision_id, desired_seq = manifest.desired_seq, sites = manifest.sites,
        certificates = json.array() }
    local directory = 'releases/' .. manifest.revision_id .. '/'
    for _, reference in ipairs(manifest.certificates) do
        u.check(self.clock() < deadline, 'download_deadline', 503)
        local ciphertext = fetch(reference.sha256)
        u.check(self.clock() < deadline, 'download_deadline', 503)
        u.check(type(ciphertext) == 'string' and crypto.sha256(ciphertext) == reference.sha256, 'object_digest')
        local object = json.decode(crypto.decrypt(ciphertext, self.settings.decryption_private_key, reference.key_id))
        u.check(object.node_id == manifest.node_id and object.key_id == reference.key_id
            and object.certificate_id == reference.certificate_id and object.version == reference.version, 'certificate_audience')
        local hosts = {}
        for _, site in ipairs(manifest.sites) do
            if site.enabled and site.ssl.enabled and site.ssl.certificate_id == object.certificate_id and site.ssl.certificate_version == object.version then
                for _, host in ipairs(site.server_names) do hosts[#hosts + 1] = host end
            end
        end
        local checked = certificates.check(object, hosts, self.clock())
        object.fingerprint, object.not_after = checked.fingerprint, checked.not_after
        runtime.certificates[#runtime.certificates + 1] = object
        self.store:write(directory .. 'objects/' .. reference.sha256 .. '.jwe', ciphertext)
    end
    for _, site in ipairs(manifest.sites) do
        if site.enabled and site.root ~= '' then
            u.check(self.settings.verify_root, 'root_verifier_required', 503)
            self.settings.verify_root(site.root)
        end
    end
    local runtime_json = json.encode(runtime)
    u.check(#runtime_json <= (self.settings.max_snapshot_bytes or u.MAX_BYTES), 'runtime_size', 413)
    self.store:write(directory .. 'manifest.jws', signed)
    self.store:write(directory .. 'runtime.json', runtime_json)
    return runtime, { revision_id = manifest.revision_id, desired_seq = manifest.desired_seq,
        release_id = manifest.release_id, digest = digest, expires_at = manifest.expires_at,
        snapshot_sha256 = crypto.sha256(runtime_json) }
end
function M:apply(signed, fetch)
    local previous = self:recover()
    u.check(self.outbox:available(), 'outbox_full', 503)
    local runtime, target = self:download(signed, fetch)
    if not runtime then return target end
    u.check(target.expires_at > self.clock(), 'manifest_expired')
    local transaction = crypto.sha256(crypto.random(16)):sub(1, 32)
    local journal = { transaction_id = transaction, previous = previous, target = target,
        reservation = self.outbox:reserve('/_scdn_sync/v1/reports') }
    local recorded, record_error = pcall(self.store.write, self.store, 'journal.json', json.encode(journal))
    if not recorded then self.outbox:cancel(journal.reservation); error(record_error, 0) end
    local ok, err = pcall(function()
        self:call('stage', { transaction_id = transaction, expected_revision = previous and previous.revision_id,
            snapshot = runtime })
        self:wait(target.revision_id, transaction)
        self:call('commit', { transaction_id = transaction })
        self:wait(target.revision_id)
        u.check(self.probe, 'health_probe_required', 503)
        self.probe(runtime)
        self.store:write('applied.json', json.encode(target))
    end)
    if not ok then
        local code = u.error_code(err)
        journal.error_code = code
        self.store:write('journal.json', json.encode(journal))
        -- recover rolls back if applied was not durably committed. Failed rollback retains journal.
        self:recover()
        error(err, 0)
    end
    self.outbox:enqueue(journal.reservation, report_fields(journal, 'applied'))
    self:call('finalize', { transaction_id = transaction })
    self.store:remove('journal.json')
    return target
end
return M
