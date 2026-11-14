local x509 = require 'resty.openssl.x509'
local pkey = require 'resty.openssl.pkey'
local json = require 'scdn_sync.codec'
local u = require 'scdn_sync.util'
local validate = require 'scdn_sync.validate'
local M = {}
function M.check(material, hosts, now)
    u.keys(material, u.fields('certificate_id version chain_pem private_key_pem node_id key_id'))
    u.check(u.id(material.certificate_id) and u.integer(material.version, 1, 9007199254740991)
        and type(material.chain_pem) == 'string' and #material.chain_pem <= 262144
        and type(material.private_key_pem) == 'string' and #material.private_key_pem <= 65536, 'certificate_size')
    local certificates, stripped = {}, material.chain_pem
    for pem in material.chain_pem:gmatch('%-%-%-%-%-BEGIN CERTIFICATE%-%-%-%-%-[A-Za-z0-9+/=%s]+%-%-%-%-%-END CERTIFICATE%-%-%-%-%-') do
        certificates[#certificates + 1] = u.check(x509.new(pem), 'invalid_certificate')
        stripped = stripped:gsub(pem:gsub('([^%w])', '%%%1'), '', 1)
    end
    u.check(#certificates > 0 and #certificates <= 10 and not stripped:find('%S'), 'invalid_certificate_chain')
    local key = u.check(pkey.new(material.private_key_pem), 'invalid_certificate_key')
    u.check(key:is_private() and certificates[1]:check_private_key(key), 'certificate_key_mismatch')
    for i, cert in ipairs(certificates) do
        u.check(cert:get_not_before() <= now + 30 and cert:get_not_after() > now, 'certificate_expired')
        if certificates[i + 1] then u.check(cert:verify(certificates[i + 1]:get_pubkey()), 'certificate_chain_order') end
    end
    local sans = json.array()
    local alt = certificates[1]:get_subject_alt_name()
    if alt then
        for kind, value in alt:each() do
            if kind == 'DNS' and validate.host(value:lower(), true) then sans[#sans + 1] = value:lower() end
        end
    end
    for _, host in ipairs(hosts or {}) do
        local found = false
        for _, san in ipairs(sans) do if validate.matches(host, san) then found = true end end
        u.check(found, 'certificate_san_mismatch')
    end
    local bytes = u.check(certificates[1]:digest('sha256'), 'certificate_fingerprint')
    -- resty.openssl returns binary digest.
    local fingerprint = (bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end))
    return { fingerprint = fingerprint, not_after = certificates[1]:get_not_after(), sans = sans }
end
return M
