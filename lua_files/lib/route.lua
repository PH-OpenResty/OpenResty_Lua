-- 动态路由: Host -> 站点; URI 最长前缀 -> location(可覆盖 upstream)
local registry  = require "lib.registry"
local ratelimit = require "lib.ratelimit"
local waf       = require "lib.waf"

local _M = {}

local function pick_location(site, uri)
    local locs = site.locations
    if type(locs) ~= "table" then return nil end
    local best
    for _, l in ipairs(locs) do
        local p = l.prefix
        if p and p ~= "" and uri:sub(1, #p) == p then
            if not best or #p > #best.prefix then best = l end
        end
    end
    return best
end

function _M.run()
    if ngx.ctx.routed then return end
    ngx.ctx.routed = true

    local host = ngx.var.host
    if not host then ngx.exit(403) end
    host = host:lower():gsub(":%d+$", "")

    local site = registry.lookup(host)
    if not site then
        ngx.log(ngx.WARN, "unknown vhost: ", host)
        ngx.exit(403)
    end
    ngx.ctx.site = site

    local ok, why = ratelimit.check(site, host)
    if not ok then
        ngx.log(ngx.WARN, "ratelimit ", why, " host=", host)
        ngx.exit(429)
    end

    local blocked, rule, score = waf.inspect(site)
    if blocked then
        ngx.log(ngx.WARN, "waf block host=", host, " rule=", rule, " score=", score)
        ngx.exit(403)
    end

    local loc = pick_location(site, ngx.var.uri or "")
    local upstream, mode = nil, "static"
    local layer = (loc and loc.cache) or (site.cache and site.cache.layer) or "l2"

    if loc and loc.upstream and loc.upstream ~= "" then
        upstream = loc.upstream
    elseif site.upstream and site.upstream ~= "" then
        upstream = site.upstream
    end

    if upstream then
        if layer == "off" then
            mode = "proxy_nocache"
        elseif layer == "l1" then
            mode = "proxy_l1"
        else
            mode = "proxy_l2"
        end
    end

    if mode == "static" and (not site.root or site.root == "") then
        ngx.log(ngx.ERR, "site has neither root nor upstream: ", host)
        ngx.exit(500)
    end

    ngx.var.site_root     = site.root or ""
    ngx.var.site_upstream = upstream or ""
    ngx.var.site_mode     = mode
    ngx.var.site_name     = site.name or host

    -- 反代模式: 直接内部跳转到对应的命名 location (access 阶段无法用 if 分发)
    if mode == "proxy_l1" then
        return ngx.exec(ngx.var.proxy_target_l1)
    elseif mode == "proxy_l2" then
        return ngx.exec(ngx.var.proxy_target_l2)
    elseif mode == "proxy_nocache" then
        return ngx.exec(ngx.var.proxy_target_nocache)
    end
end

return _M
