local u = require 'scdn_sync.util'
local json = require 'scdn_sync.codec'
local crypto = require 'scdn_sync.crypto'
local validate = require 'scdn_sync.validate'
local certificates = require 'scdn_sync.certificates'
local M = {}; M.__index = M
local function object(value, fields)
    u.check(type(value) == 'table' and not json.is_array(value), 'invalid_site_source')
    u.keys(value, u.fields(fields)); return value
end
local function array(value, maximum)
    u.check(type(value) == 'table' and #value <= maximum, 'invalid_site_source')
    for key in pairs(value) do u.check(u.integer(key, 1, #value), 'invalid_site_source') end
    return json.array(value)
end
local function directory(path)
    u.check(type(path) == 'string' and #path < 1024 and path:sub(1, 1) == '/' and path ~= '/'
        and path:sub(-1) ~= '/' and not path:find('[%z\\\r\n]') and not path:find('//', 1, true)
        and not path:find('/%.%.?/') and path:sub(-3) ~= '/..' and path:sub(-2) ~= '/.', 'watch_directory')
end
function M.new(scope, reader)
    directory(scope.sites_dir)
    u.check(u.id(scope.scope_id) and type(scope.certificate_roots or {}) == 'table', 'watch_scope')
    u.check(#(scope.certificate_roots or {}) <= 16, 'watch_certificate_roots')
    for _, root in ipairs(scope.certificate_roots or {}) do directory(root) end
    u.check(scope.allow_empty == nil or type(scope.allow_empty) == 'boolean', 'watch_empty_policy')
    return setmetatable({ scope = scope, reader = reader }, M)
end

function M:capture()
    local readers, fingerprints, cache, total = {}, {}, {}, 0
    local function opened(root)
        if not readers[root] then readers[root] = self.reader(root) end
        return readers[root]
    end
    local function read(root, relative, limit, identity)
        if cache[identity] then
            u.check(#cache[identity] <= limit, 'site_source_size'); return cache[identity]
        end
        local bytes = u.check(opened(root):read(relative, limit), 'source_changed', 503)
        total = total + #bytes; u.check(total <= u.MAX_BYTES, 'source_snapshot_size', 413)
        cache[identity], fingerprints[identity] = bytes, crypto.sha256(bytes)
        return bytes
    end
    local function pem(path, limit)
        u.check(type(path) == 'string', 'certificate_source_path')
        for _, root in ipairs(self.scope.certificate_roots or {}) do
            if path:sub(1, #root + 1) == root .. '/' then
                return read(root, path:sub(#root + 2), limit, 'pem:' .. path)
            end
        end
        u.fail('certificate_source_forbidden', 403)
    end
    local ok, result = pcall(function()
        local captured = { sites = json.array(), certificates = {} }
        local ids, files = {}, {}
        for _, name in ipairs(opened(self.scope.sites_dir):list(nil, 4096)) do
            if name:sub(1, 1) ~= '.' then
                local base = name:match('^(.*)%.lua$') or name:match('^(.*)%.json$')
                if base then
                    u.check(u.id(base) and not files[base], 'duplicate_source_name')
                    files[base] = true
                    local bytes = read(self.scope.sites_dir, name, 262144, 'site:' .. name)
                    local raw = name:sub(-5) == '.json' and json.decode(bytes) or require('scdn_sync.data_lua').decode(bytes)
                    object(raw, 'site_id resource_version name enabled server_names root upstream cache ssl rate_limit waf locations')
                    u.check(raw.enabled == nil or type(raw.enabled) == 'boolean', 'invalid_site_source')
                    u.check(raw.resource_version == nil or u.integer(raw.resource_version, 1, 9007199254740991), 'invalid_site_source')
                    local site = { site_id = raw.site_id or base, name = raw.name or base, resource_version = 1,
                        enabled = raw.enabled ~= false, server_names = array(raw.server_names, 100),
                        root = raw.root or '', upstream = raw.upstream or '', cache = raw.cache or { layer = 'l2' },
                        locations = raw.locations and array(raw.locations, 100) or nil }
                    u.check(u.id(site.site_id) and not ids[site.site_id], 'duplicate_site'); ids[site.site_id] = true
                    for i, host in ipairs(site.server_names) do
                        u.check(type(host) == 'string', 'invalid_host'); site.server_names[i] = host:lower()
                    end
                    local rate = object(raw.rate_limit or {}, 'enabled req_per_sec burst conn')
                    u.check(rate.enabled == nil or type(rate.enabled) == 'boolean', 'invalid_rate_limit')
                    site.rate_limit = { enabled = rate.enabled == true, req_per_sec = rate.req_per_sec or 50, burst = rate.burst or 0 }
                    -- The original conn field has no implementation; do not claim it as a connection limit.
                    if not site.rate_limit.enabled and site.rate_limit.req_per_sec == 0 then site.rate_limit.req_per_sec = 1 end
                    local waf = object(raw.waf or {}, 'enabled groups threshold')
                    u.check(waf.enabled == nil or type(waf.enabled) == 'boolean', 'invalid_waf')
                    site.waf = { enabled = waf.enabled == true, groups = array(waf.groups or {}, 6), threshold = waf.threshold or 5 }
                    local ssl = object(raw.ssl or {}, 'enabled cert key')
                    u.check(ssl.enabled == nil or type(ssl.enabled) == 'boolean', 'invalid_tls')
                    u.check((ssl.cert == nil or type(ssl.cert) == 'string') and (ssl.key == nil or type(ssl.key) == 'string'), 'invalid_tls')
                    local has_cert, has_key = ssl.cert and ssl.cert ~= '', ssl.key and ssl.key ~= ''
                    site.ssl = { enabled = false }
                    if site.enabled and ssl.enabled ~= false then
                        u.check((not has_cert and not has_key and ssl.enabled ~= true) or (has_cert and has_key), 'missing_certificate')
                        if has_cert and has_key then
                            local id = 'file-' .. crypto.sha256(self.scope.scope_id .. '\0' .. ssl.cert .. '\0' .. ssl.key):sub(1, 32)
                            local material = captured.certificates[id]
                            if not material then
                                material = { certificate_id = id, chain_pem = pem(ssl.cert, 262144),
                                    private_key_pem = pem(ssl.key, 65536), hosts = {} }
                                captured.certificates[id] = material
                            end
                            for _, host in ipairs(site.server_names) do material.hosts[#material.hosts + 1] = host end
                            site.ssl = { enabled = true, certificate_id = id, certificate_version = 1 }
                        end
                    end
                    validate.site(site)
                    captured.sites[#captured.sites + 1] = { site = site, minimum_version = raw.resource_version or 1 }
                    u.check(#captured.sites <= 1000, 'source_site_capacity', 413)
                end
            end
        end
        u.check(#captured.sites > 0 or self.scope.allow_empty == true, 'source_empty', 409)
        table.sort(captured.sites, function(a, b) return a.site.site_id < b.site.site_id end)
        captured.digest = crypto.sha256(json.encode(fingerprints))
        return captured
    end)
    for _, reader in pairs(readers) do reader:close() end
    if not ok then error(result, 0) end
    return result
end

function M.compile(captured, version, now)
    local sites, materials, ids = json.array(), json.array(), {}
    for id in pairs(captured.certificates) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local source = captured.certificates[id]
        local digest = crypto.sha256(source.chain_pem .. '\0' .. source.private_key_pem)
        local material = { certificate_id = id, chain_pem = source.chain_pem, private_key_pem = source.private_key_pem,
            version = version('certificates', id, digest, 1) }
        certificates.check(material, source.hosts, now)
        materials[#materials + 1] = material
        source.version = material.version
    end
    local hosts = {}
    for _, entry in ipairs(captured.sites) do
        local site = entry.site
        if site.ssl.enabled then site.ssl.certificate_version = captured.certificates[site.ssl.certificate_id].version end
        site.resource_version = nil
        local digest = crypto.sha256(json.encode(site))
        site.resource_version = version('sites', site.site_id, digest, entry.minimum_version)
        for _, host in ipairs(site.server_names) do u.check(not hosts[host], 'host_conflict'); hosts[host] = true end
        sites[#sites + 1] = site
    end
    local result = { sites = sites, certificates = materials }
    u.check(#json.encode(result) <= u.MAX_BYTES - 8192, 'source_snapshot_size', 413)
    return result
end
return M
