-- 集群控制面: 维护集群级站点定义, 提供快照/上报/状态/发布接口
local cjson = require "cjson.safe"
local _M = {}

local CLUSTER_DIR = "/usr/local/openresty/lua_files/cluster"
local SITES_DIR   = CLUSTER_DIR .. "/sites"
local STATE_FILE  = CLUSTER_DIR .. "/state.json"
local TOKEN_FILE  = "/usr/local/openresty/lua_files/.admin_token"

local function token()
    local f = io.open(TOKEN_FILE, "r"); if not f then return nil end
    local t = (f:read("*l") or ""):gsub("%s", ""); f:close(); return t
end

local function read_all_sites()
    local p = io.popen("find " .. SITES_DIR .. " -maxdepth 1 -name '*.lua' | sort")
    local list = {}
    if p then
        for path in p:lines() do
            local name = path:match("([^/]+)%.lua$")
            local f = io.open(path, "r")
            if name and f then
                local src = f:read("*a"); f:close()
                list[#list + 1] = { name = name, source = src }
            end
        end
        p:close()
    end
    return list
end

local function version_of(list)
    local parts = {}
    for _, s in ipairs(list) do parts[#parts + 1] = s.name .. ":" .. s.source end
    return ngx.md5(table.concat(parts, "\n"))
end

local function read_state()
    local f = io.open(STATE_FILE, "r"); if not f then return { nodes = {} } end
    local s = f:read("*a"); f:close()
    return cjson.decode(s) or { nodes = {} }
end

local function write_state(st)
    local tmp = STATE_FILE .. ".tmp"
    local f = io.open(tmp, "w"); if not f then return end
    f:write(cjson.encode(st)); f:close()
    os.rename(tmp, STATE_FILE)
end

local function reply(code, obj)
    ngx.status = code
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(obj))
    return ngx.exit(code)
end

function _M.handle()
    local expect = token()
    local args = ngx.req.get_uri_args()
    if not expect or args.token ~= expect then
        return reply(403, { ok = false, err = "forbidden" })
    end

    local uri = ngx.var.uri
    if uri == "/cluster/snapshot" then
        local list = read_all_sites()
        return reply(200, { ok = true, version = version_of(list), sites = list })
    elseif uri == "/cluster/report" then
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        local rep = body and cjson.decode(body)
        if not rep or not rep.node then return reply(400, { ok = false, err = "bad report" }) end
        local st = read_state()
        st.nodes = st.nodes or {}
        st.nodes[rep.node] = rep
        write_state(st)
        return reply(200, { ok = true })
    elseif uri == "/cluster/status" then
        local list = read_all_sites()
        local st = read_state()
        return reply(200, { ok = true, version = version_of(list), sites = #list, nodes = st.nodes })
    elseif uri == "/cluster/publish" then
        ngx.req.read_body()
        local body = ngx.req.get_body_data()
        local obj = body and cjson.decode(body)
        if not obj or not obj.name or not obj.source then
            return reply(400, { ok = false, err = "need {name, source}" })
        end
        if not obj.name:match("^[%w_%-]+$") then
            return reply(400, { ok = false, err = "invalid name" })
        end
        local f = assert(io.open(SITES_DIR .. "/" .. obj.name .. ".lua", "w"))
        f:write(obj.source); f:close()
        local list = read_all_sites()
        return reply(200, { ok = true, version = version_of(list), sites = #list })
    end
    return reply(404, { ok = false, err = "unknown endpoint" })
end

return _M
