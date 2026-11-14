local u = require 'scdn_sync.util'
local json = require 'scdn_sync.codec'
local M = {}
local groups = u.fields('sqli xss lfi rce scanner protocol')

function M.host(value, wildcard)
    if type(value) ~= 'string' or #value > 253 or #value < 1 or value ~= value:lower() then return false end
    if wildcard and value:sub(1, 2) == '*.' then value = value:sub(3) end
    if value == '' or value:find('[^a-z0-9%.%-]') or value:sub(1, 1) == '.'
        or value:sub(-1) == '.' or value:find('..', 1, true) then return false end
    for label in value:gmatch('[^.]+') do
        if #label > 63 or label:sub(1, 1) == '-' or label:sub(-1) == '-' then return false end
    end
    return true
end
function M.matches(host, san)
    if host == san then return true end
    if san:sub(1, 2) ~= '*.' then return false end
    local dot = host:find('.', 1, true)
    return dot and host:sub(dot + 1) == san:sub(3) or false
end
local function object(value, allowed)
    u.check(type(value) == 'table' and not json.is_array(value), 'expected_object')
    if allowed then u.keys(value, u.fields(allowed)) end
end
local function array(value, maximum)
    u.check(json.is_array(value) and #value <= maximum, 'expected_array')
end
function M.endpoint(value)
    if type(value) ~= 'string' or #value > 320 then return false end
    local host, port = value:match('^([a-z0-9%.%-]+):([0-9]+)$')
    return host and M.host(host) and u.integer(tonumber(port), 1, 65535) or false
end
function M.site(site, policy)
    object(site, 'site_id resource_version name enabled server_names root upstream cache ssl rate_limit waf locations')
    u.check(u.id(site.site_id) and u.id(site.name) and u.integer(site.resource_version, 1, 9007199254740991)
        and type(site.enabled) == 'boolean', 'invalid_site')
    array(site.server_names, 100)
    u.check(#site.server_names > 0, 'empty_hosts')
    local seen = {}
    for _, host in ipairs(site.server_names) do
        u.check(M.host(host) and not seen[host], 'invalid_host'); seen[host] = true
    end
    u.check(type(site.root) == 'string' and type(site.upstream) == 'string', 'invalid_route')
    u.check(site.upstream == '' or M.endpoint(site.upstream), 'invalid_upstream')
    u.check(#site.root <= 1024 and (site.root == '' or (site.root:sub(1, 1) == '/' and site.root ~= '/'
        and not site.root:find('[%z\\\r\n]') and not site.root:find('//', 1, true)
        and not site.root:find('/%.%.?/') and site.root:sub(-3) ~= '/..'
        and site.root:sub(-2) ~= '/.' and site.root:sub(-1) ~= '/')), 'invalid_root')
    u.check(not site.enabled or site.upstream ~= '' or site.root ~= '', 'missing_route')
    if policy and site.root ~= '' then
        local allowed = false
        for _, root in ipairs(policy.static_roots or {}) do
            if site.root == root or site.root:sub(1, #root + 1) == root .. '/' then allowed = true end
        end
        u.check(allowed, 'root_not_allowed', 403)
    end
    object(site.cache, 'layer')
    u.check(site.cache.layer == 'l1' or site.cache.layer == 'l2' or site.cache.layer == 'off', 'invalid_cache')
    object(site.ssl, 'enabled certificate_id certificate_version')
    u.check(type(site.ssl.enabled) == 'boolean', 'invalid_tls')
    if site.ssl.enabled then
        u.check(u.id(site.ssl.certificate_id) and u.integer(site.ssl.certificate_version, 1, 9007199254740991), 'invalid_tls')
    else u.check(site.ssl.certificate_id == nil and site.ssl.certificate_version == nil, 'invalid_tls') end
    object(site.rate_limit, 'enabled req_per_sec burst')
    u.check(type(site.rate_limit.enabled) == 'boolean' and u.integer(site.rate_limit.req_per_sec, 1, 1000000)
        and u.integer(site.rate_limit.burst, 0, 1000000), 'invalid_rate_limit')
    object(site.waf, 'enabled groups threshold')
    u.check(type(site.waf.enabled) == 'boolean' and u.integer(site.waf.threshold, 1, 1000), 'invalid_waf')
    array(site.waf.groups, 6)
    local selected = {}
    for _, group in ipairs(site.waf.groups) do
        u.check(groups[group] and not selected[group], 'invalid_waf_group'); selected[group] = true
    end
    if site.locations then
        array(site.locations, 100)
        local prefixes = {}
        for _, loc in ipairs(site.locations) do
            object(loc, 'prefix upstream cache')
            u.check(type(loc.prefix) == 'string' and #loc.prefix <= 1024 and loc.prefix:sub(1, 1) == '/'
                and not loc.prefix:find('[%z\r\n]') and not prefixes[loc.prefix], 'invalid_location')
            prefixes[loc.prefix] = true
            u.check(M.endpoint(loc.upstream) and (loc.cache == 'l1' or loc.cache == 'l2' or loc.cache == 'off'), 'invalid_location')
        end
    end
    return site
end
function M.manifest(value, expected, now, recovery)
    object(value, 'protocol node_id scope_id revision_id release_id desired_seq issued_at expires_at sites certificates tombstones')
    u.check(value.protocol == u.PROTOCOL and value.node_id == expected.node_id and value.scope_id == expected.scope_id
        and u.id(value.revision_id) and u.id(value.release_id) and u.seq(value.desired_seq) and value.desired_seq ~= '0', 'manifest_identity')
    u.check(u.integer(value.issued_at, 0, 9007199254740991) and u.integer(value.expires_at, 0, 9007199254740991)
        and value.expires_at > value.issued_at and value.expires_at - value.issued_at <= 86400
        and (recovery or (value.issued_at <= now + 30 and value.expires_at > now)), 'manifest_expired')
    array(value.sites, expected.max_sites or 1000)
    array(value.certificates, expected.max_certificates or 1000)
    array(value.tombstones, 2000)
    local ids, hosts, certificates = {}, {}, {}
    for _, cert in ipairs(value.certificates) do
        object(cert, 'certificate_id version key_id sha256')
        u.check(u.id(cert.certificate_id) and u.integer(cert.version, 1, 9007199254740991)
            and cert.key_id == expected.decryption_key_id and u.hex(cert.sha256), 'invalid_certificate_reference')
        local ref = cert.certificate_id .. ':' .. u.decimal(cert.version)
        u.check(not certificates[ref], 'duplicate_certificate'); certificates[ref] = cert
    end
    for _, site in ipairs(value.sites) do
        M.site(site, expected)
        u.check(not ids[site.site_id], 'duplicate_site'); ids[site.site_id] = true
        for _, host in ipairs(site.server_names) do
            u.check(not hosts[host], 'host_conflict'); hosts[host] = site.site_id
        end
        if site.enabled and site.ssl.enabled then
            u.check(certificates[site.ssl.certificate_id .. ':' .. u.decimal(site.ssl.certificate_version)], 'missing_certificate')
        end
    end
    local deleted = {}
    for _, id in ipairs(value.tombstones) do
        u.check(u.id(id) and not ids[id] and not deleted[id], 'invalid_tombstone'); deleted[id] = true
    end
    return value
end
return M
