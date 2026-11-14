-- 节点 agent: 从控制面拉取站点快照, 有变化则落盘/编译/热加载, 并回报状态
local cjson = require "cjson.safe"

local CONF = "/usr/local/openresty/lua_files/cluster/agent.conf"
local SITES_DIR = "/usr/local/openresty/lua_files/sites"
local CLUSTER_DIR = "/usr/local/openresty/lua_files/cluster"
local VERSION_FILE = CLUSTER_DIR .. "/version"
local LJ = "/usr/local/openresty/luajit/bin/luajit"

local conf = assert(loadfile(CONF))()
local function token()
    local f = io.open("/usr/local/openresty/lua_files/.admin_token", "r")
    if not f then return "" end
    local t = (f:read("*l") or ""):gsub("%s", ""); f:close(); return t
end
local T = token()

local function http_get(url)
    local p = io.popen("curl -s -m 5 '" .. url .. "'")
    local out = p and p:read("*a") or ""; if p then p:close() end
    return out
end
local function post(url, body)
    local f = io.open("/tmp/cluster-report.json", "w"); f:write(body); f:close()
    local p = io.popen("curl -s -m 5 -X POST --data-binary @/tmp/cluster-report.json '" .. url .. "'")
    local out = p and p:read("*a") or ""; if p then p:close() end
    return out
end
local function read_file(p)
    local f = io.open(p, "r"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end

local snap = http_get(conf.control .. "/cluster/snapshot?token=" .. T)
local data = cjson.decode(snap)
if not data or not data.ok then
    post(conf.control .. "/cluster/report?token=" .. T,
        cjson.encode({ node = conf.node_id, status = "control_unreachable", ts = os.time() }))
    os.exit(1)
end

local local_ver = read_file(VERSION_FILE) or ""
local applied = false
if data.version ~= local_ver then
    for _, s in ipairs(data.sites or {}) do
        local path = SITES_DIR .. "/" .. s.name .. ".lua"
        local f = assert(io.open(path, "w")); f:write(s.source); f:close()
        os.execute(string.format("%s -b %q %q", LJ, path, SITES_DIR .. "/" .. s.name .. ".ljbc"))
    end
    os.execute("curl -s '" .. conf.local_admin .. "/?action=reload&token=" .. T .. "' >/dev/null")
    local f = io.open(VERSION_FILE, "w"); f:write(data.version); f:close()
    applied = true
end

post(conf.control .. "/cluster/report?token=" .. T, cjson.encode({
    node = conf.node_id,
    status = "ok",
    version = data.version,
    sites = #(data.sites or {}),
    applied = applied,
    ts = os.time(),
}))
print(string.format("agent: version=%s sites=%d applied=%s", data.version, #(data.sites or {}), tostring(applied)))
