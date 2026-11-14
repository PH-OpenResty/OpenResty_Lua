-- 站点管理接口: 仅本机 + token, 用于 CLI 触发注册表热加载
local cjson    = require "cjson.safe"
local registry = require "lib.registry"

local _M = {}
local TOKEN_FILE = "/usr/local/openresty/lua_files/.admin_token"

local function token()
    local f = io.open(TOKEN_FILE, "r")
    if not f then return nil end
    local t = f:read("*l")
    f:close()
    return t
end

local function reply(code, obj)
    ngx.status = code
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(obj))
    return ngx.exit(code)
end

function _M.handle()
    local expected = token()
    if not expected or expected == "" then
        return reply(503, { ok = false, err = "admin token not configured" })
    end
    local args = ngx.req.get_uri_args()
    if args.token ~= expected then
        return reply(403, { ok = false, err = "forbidden" })
    end

    local action = args.action
    if action == "reload" then
        local n, err = registry.reload()
        if not n then return reply(500, { ok = false, err = err }) end
        ngx.log(ngx.NOTICE, "site registry reloaded, sites=", n)
        return reply(200, { ok = true, sites = n })
    elseif action == "list" then
        return reply(200, { ok = true, hosts = registry.hosts() })
    end
    return reply(400, { ok = false, err = "unknown action" })
end

return _M
