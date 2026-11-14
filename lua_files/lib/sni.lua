-- SNI 证书选择 + 缓存: 按 SNI 查注册表, 解析后的证书缓存在 worker 内 LRU
local registry = require "lib.registry"
local ngx_ssl  = require "ngx.ssl"
local lrucache = require "resty.lrucache"

local _M = {}
local cache = lrucache.new(512)
local DEFAULT_CERT = "/etc/openresty/ssl/default.crt"
local DEFAULT_KEY  = "/etc/openresty/ssl/default.key"

local function read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function load_pair(cert_file, key_file)
    local key = cert_file .. "|" .. key_file
    local ent = cache:get(key)
    if ent then return ent, true end
    local pem_c = read_file(cert_file)
    local pem_k = read_file(key_file)
    if not pem_c or not pem_k then return nil, false end
    local cert, err = ngx_ssl.parse_pem_cert(pem_c)
    if not cert then
        ngx.log(ngx.ERR, "parse cert failed ", cert_file, ": ", err)
        return nil, false
    end
    local priv, err2 = ngx_ssl.parse_pem_priv_key(pem_k)
    if not priv then
        ngx.log(ngx.ERR, "parse key failed ", key_file, ": ", err2)
        return nil, false
    end
    ent = { cert = cert, key = priv }
    cache:set(key, ent)
    return ent, false
end

-- ssl_certificate_by_lua 阶段调用
function _M.set_cert()
    local sni = ngx_ssl.server_name()
    local site
    if sni then
        site = registry.lookup(sni:lower())
    end

    local ssl = site and site.ssl
    local cert_file = (type(ssl) == "table" and ssl.cert) or DEFAULT_CERT
    local key_file  = (type(ssl) == "table" and ssl.key)  or DEFAULT_KEY

    local ent, hit = load_pair(cert_file, key_file)
    if not ent then
        ent = load_pair(DEFAULT_CERT, DEFAULT_KEY)
    end
    if not ent then
        ngx.log(ngx.ERR, "no usable certificate for SNI ", tostring(sni))
        return ngx.exit(ngx.ERROR)
    end

    ngx.ctx.sni_cert_hit = hit
    ngx.ctx.sni_name = sni
    ngx_ssl.set_cert(ent.cert)
    ngx_ssl.set_priv_key(ent.key)
end

return _M
