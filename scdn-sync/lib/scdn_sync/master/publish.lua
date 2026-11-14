local u = require 'scdn_sync.util'
local json = require 'scdn_sync.codec'
local crypto = require 'scdn_sync.crypto'
local validate = require 'scdn_sync.validate'
local certificates = require 'scdn_sync.certificates'
local M = {}; M.__index = M

function M.new(store, settings)
    u.check(u.id(settings.signing_key_id) and type(settings.signing_private_key) == 'string', 'publisher_config')
    return setmetatable({ store = store, settings = settings }, M)
end

-- Internal module API. There is intentionally no unauthenticated publish HTTP route.
function M:publish(input, now, source)
    if source then
        u.keys(source, u.fields('id digest renew_before_seconds'))
        u.check(u.id(source.id) and u.hex(source.digest)
            and u.integer(source.renew_before_seconds, 0, 43200), 'publish_source')
    end
    u.check(u.id(input.node_id) and u.id(input.scope_id), 'publish_target')
    local node = self.settings.nodes[input.node_id]
    u.check(node and node.enabled ~= false and node.revoked ~= true and node.scope_id == input.scope_id, 'publish_forbidden', 403)
    u.check(json.is_array(input.sites) and #input.sites <= (node.max_sites or 1000)
        and (input.certificates == nil or (json.is_array(input.certificates) and #input.certificates <= 1000)), 'publish_size')
    return self.store:locked('nodes/' .. input.node_id .. '/publish.lock', function()
        local root = 'nodes/' .. input.node_id .. '/'
        local previous_bytes = self.store:read(root .. 'desired.json')
        local previous = previous_bytes and json.decode(previous_bytes)
        -- Compare under the same per-node commit lock. Restarting a file watcher,
        -- including after commit but before its notification, must not republish.
        if source and previous and previous.source_id == source.id and previous.source_digest == source.digest
            and previous.expires_at > now + source.renew_before_seconds then
            -- A previous rename may have become visible before directory fsync
            -- failed. Reconfirm durability before treating that attempt as done.
            self.store:write(root .. 'desired.json', json.encode(previous))
            local metadata = json.decode(json.encode(previous)); metadata.recent = nil
            return metadata, false
        end
        local seq = u.increment(previous and previous.desired_seq or '0')
        local revision = crypto.sha256(crypto.random(32)):sub(1, 32)
        local manifest = { protocol = u.PROTOCOL, node_id = input.node_id, scope_id = input.scope_id,
            revision_id = revision, release_id = input.release_id or revision, desired_seq = seq,
            issued_at = now, expires_at = now + (input.ttl_seconds or 3600), sites = input.sites,
            certificates = json.array(), tombstones = input.tombstones or json.array() }
        local wanted = {}
        for _, site in ipairs(input.sites) do
            validate.site(site, node)
            if site.enabled and site.ssl.enabled then
                local ref = site.ssl.certificate_id .. ':' .. u.decimal(site.ssl.certificate_version)
                wanted[ref] = wanted[ref] or {}
                for _, host in ipairs(site.server_names) do wanted[ref][#wanted[ref] + 1] = host end
            end
        end
        local objects, available = {}, {}
        for _, material in ipairs(input.certificates or {}) do
            u.check(u.id(material.certificate_id) and u.integer(material.version, 1, 9007199254740991), 'invalid_certificate')
            local ref = material.certificate_id .. ':' .. u.decimal(material.version)
            u.check(wanted[ref] and not available[ref], 'unexpected_certificate')
            certificates.check(material, wanted[ref], now)
            local certificate_path = root .. 'certificates/' .. material.certificate_id .. '/' .. u.decimal(material.version) .. '.json'
            local material_digest = crypto.sha256(material.chain_pem .. '\0' .. material.private_key_pem)
            local existing_certificate = self.store:read(certificate_path)
            u.check(not existing_certificate or json.decode(existing_certificate).material_digest == material_digest,
                'immutable_certificate_version', 409)
            if not existing_certificate then
                self.store:write(certificate_path, json.encode({ material_digest = material_digest }))
            end
            local object = { node_id = input.node_id, key_id = node.decryption_key_id,
                certificate_id = material.certificate_id, version = material.version,
                chain_pem = material.chain_pem, private_key_pem = material.private_key_pem }
            local ciphertext = crypto.encrypt(json.encode(object), node.encryption_public_key, node.decryption_key_id)
            local sha = crypto.sha256(ciphertext)
            objects[sha], available[ref] = ciphertext, true
            manifest.certificates[#manifest.certificates + 1] = { certificate_id = material.certificate_id,
                version = material.version, key_id = node.decryption_key_id, sha256 = sha }
        end
        validate.manifest(manifest, { node_id = input.node_id, scope_id = input.scope_id,
            decryption_key_id = node.decryption_key_id, static_roots = node.static_roots }, now)
        local encrypted = crypto.encrypt(json.encode(manifest), node.encryption_public_key, node.decryption_key_id)
        local signed = crypto.wrap(encrypted, self.settings.signing_private_key, self.settings.signing_key_id)
        local directory = root .. 'releases/' .. revision .. '/'
        for sha, ciphertext in pairs(objects) do self.store:write(directory .. 'objects/' .. sha .. '.jwe', ciphertext) end
        self.store:write(directory .. 'manifest.jws', signed)
        local metadata = { node_id = input.node_id, scope_id = input.scope_id, desired_seq = seq,
            revision_id = revision, release_id = manifest.release_id, sha256 = crypto.sha256(signed),
            expires_at = manifest.expires_at, objects = json.array() }
        if source then metadata.source_id, metadata.source_digest = source.id, source.digest end
        for sha in pairs(objects) do metadata.objects[#metadata.objects + 1] = sha end
        table.sort(metadata.objects)
        self.store:write(directory .. 'metadata.json', json.encode(metadata))
        local desired = json.decode(json.encode(metadata))
        desired.recent = json.array()
        if previous then
            local previous_metadata = json.decode(json.encode(previous))
            previous_metadata.recent = nil
            desired.recent[#desired.recent + 1] = previous_metadata
            for _, old in ipairs(previous.recent or {}) do
                if #desired.recent >= 7 then break end
                if old.expires_at > now then desired.recent[#desired.recent + 1] = old end
            end
        end
        -- This is the only publication commit. Earlier failures leave the old desired intact.
        self.store:write(root .. 'desired.json', json.encode(desired))
        if source then return metadata, true end
        return metadata
    end)
end
return M
