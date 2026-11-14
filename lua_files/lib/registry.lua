-- 站点注册表: 站点定义来自 sites/*.ljbc, 存入共享内存, 支持零 reload 热更新
local cjson    = require "cjson.safe"
local lrucache = require "resty.lrucache"

local _M = {}
local DICT      = "sites_registry"
local SITES_DIR = "/usr/local/openresty/lua_files/sites"
local lru       = lrucache.new(2048)

local function read_site(path)
    local chunk = loadfile(path)
    if not chunk then return nil, "loadfile failed: " .. path end
    local ok, site = pcall(chunk)
    if not ok or type(site) ~= "table" then return nil, "invalid site: " .. path end
    return site
end

function _M.reload()
    local d = ngx.shared[DICT]
    local gen = (d:get("gen") or 0) + 1
    local p = io.popen("find " .. SITES_DIR .. " -maxdepth 1 -name '*.ljbc' 2>/dev/null")
    if not p then return nil, "cannot scan " .. SITES_DIR end
    -- 先清理上一轮的主机键, 否则已删除的站点会残留
    local old = cjson.decode(d:get("hosts") or "[]") or {}
    for _, h in ipairs(old) do
        d:delete("h:" .. h)
    end

    local count, hosts = 0, {}
    for path in p:lines() do
        local site = read_site(path)
        if site and site.enabled ~= false then
            count = count + 1
            for _, n in ipairs(site.server_names or {}) do
                local h = string.lower(n)
                d:set("h:" .. h, cjson.encode(site))
                hosts[#hosts + 1] = h
            end
        end
    end
    p:close()
    d:set("gen", gen)
    d:set("hosts", cjson.encode(hosts))
    lru:flush_all()
    return count
end

function _M.lookup(host)
    local d = ngx.shared[DICT]
    local gen = d:get("gen") or 0
    local ent = lru:get(host)
    if ent and ent.gen == gen then return ent.site end
    local js = d:get("h:" .. host)
    if not js then return nil end
    local site = cjson.decode(js)
    if not site then return nil end
    lru:set(host, { gen = gen, site = site })
    return site
end

function _M.hosts()
    local d = ngx.shared[DICT]
    return cjson.decode(d:get("hosts") or "[]") or {}
end

return _M
