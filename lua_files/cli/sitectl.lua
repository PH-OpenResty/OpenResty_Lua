-- 站点管理 CLI
-- 用法:
--   resty sitectl.lua add <name> --host=www.example.com --root=/data \
--        [--upstream=127.0.0.1:8080] [--cert=.. --key=..] \
--        [--cache=l1|l2|off] [--locations=/api/=127.0.0.1:9000:l2] \
--        [--forward=9001:127.0.0.1:3306,9002:127.0.0.1:6379] \
--        [--live --live-app=live --hls-path=/path --hls-fragment=2s --hls-playlist=10s] \
--        [--rate=50 --burst=100] [--waf=sqli,xss] [--no-waf]
--   resty sitectl.lua del <name>
--   resty sitectl.lua list
--   resty sitectl.lua reload
local SITES_DIR = "/usr/local/openresty/lua_files/sites"
local GEN_DIR   = "/etc/openresty/generated"
local LJ        = "/usr/local/openresty/luajit/bin/luajit"
local NGINX     = "/usr/local/openresty/nginx/sbin/nginx"
local TOKEN     = "/usr/local/openresty/lua_files/.admin_token"

local argv = arg or {}
local cmd  = argv[1]
local name = argv[2]

local function die(msg) io.stderr:write("error: " .. msg .. "\n"); os.exit(1) end
local function sh(cmdline)
    local ok = os.execute(cmdline)
    return ok == 0 or ok == true
end
local function split(s, sep)
    local t = {}
    for x in (s or ""):gmatch("([^" .. sep .. "]+)") do t[#t + 1] = x end
    return t
end
local function q(s) return string.format("%q", tostring(s or "")) end
local function read_file(p)
    local f = io.open(p, "r"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end
local function write_if_changed(p, content)
    local old = read_file(p)
    if old == content then return false end
    local f = assert(io.open(p, "w")); f:write(content); f:close()
    return true
end
local function admin(action)
    local t = read_file(TOKEN) or ""
    local p = io.popen("curl -s -m 5 'http://127.0.0.1:18082/?action=" .. action .. "&token=" .. t:gsub("%s", "") .. "'")
    local out = p and p:read("*a") or ""
    if p then p:close() end
    return out
end

if not cmd then die("usage: sitectl.lua {add|del|list|reload} ...") end

if cmd == "list" then print(admin("list")); return end
if cmd == "reload" then print(admin("reload")); return end

if cmd == "del" then
    if not name then die("del requires <name>") end
    local need_reload = false
    for _, suffix in ipairs({ ".lua", ".ljbc" }) do os.remove(SITES_DIR .. "/" .. name .. suffix) end
    os.remove(GEN_DIR .. "/" .. name .. ".conf")
    if os.remove(GEN_DIR .. "/stream-" .. name .. ".conf") then need_reload = true end
    if os.remove(GEN_DIR .. "/rtmp-" .. name .. ".conf") then need_reload = true end
    print(admin("reload"))
    if need_reload then sh(NGINX .. " -s reload") end
    return
end

if cmd ~= "add" then die("unknown command " .. cmd) end

local opts = {}
for i = 3, #argv do
    local k, v = argv[i]:match("^%-%-([%w%-]+)=(.*)$")
    if k then opts[k] = v end
    if argv[i] == "--no-waf" then opts["no-waf"] = "1" end
    if argv[i] == "--live" then opts["live"] = "1" end
end

if not name then die("add requires <name>") end
local hosts = split(opts.host or name, ",")

-- locations
local locations = {}
for _, ent in ipairs(split(opts.locations, ",")) do
    local prefix, rest = ent:match("^([^=]+)=(.+)$")
    if prefix then
        local up, cache = rest:match("^(.-):([%w_]+)$")
        if not up then up, cache = rest, "l2" end
        locations[#locations + 1] = { prefix = prefix, upstream = up, cache = cache }
    end
end

-- port forwarding
local forwards = {}
for _, ent in ipairs(split(opts.forward, ",")) do
    local port, target = ent:match("^(%d+):(.+)$")
    if port then forwards[#forwards + 1] = { listen = tonumber(port), target = target } end
end

-- live
local live = nil
if opts["live"] then
    local app = opts["live-app"] or name
    local hls_path = opts["hls-path"] or ("/var/cache/openresty/hls/" .. name)
    live = {
        enabled = true,
        app = app,
        hls = {
            enabled = true,
            path = hls_path,
            fragment = opts["hls-fragment"] or "4s",
            playlist_length = opts["hls-playlist"] or "20s",
        },
    }
end

if live then
    os.execute("mkdir -p " .. live.hls.path)
end

local waf_enabled = not opts["no-waf"]
local waf_groups = split(opts.waf or "sqli,xss,lfi,rce,scanner,protocol", ",")
local cache_layer = opts.cache or "l2"

-- ---------- 生成站点定义 ----------
local function lua_array(t, fmt)
    if #t == 0 then return "" end
    local out = {}
    for _, v in ipairs(t) do out[#out + 1] = "        " .. fmt(v) .. "," end
    return "    {\n" .. table.concat(out, "\n") .. "\n    }"
end

local parts = {}
parts[#parts + 1] = "-- 由 sitectl 生成: " .. os.date("%Y-%m-%d %H:%M:%S")
parts[#parts + 1] = "return {"
parts[#parts + 1] = "    name = " .. q(name) .. ","
parts[#parts + 1] = "    enabled = true,"
parts[#parts + 1] = "    server_names = { " .. table.concat((function()
    local t = {}; for _, h in ipairs(hosts) do t[#t + 1] = q(h) end; return t end)(), ", ") .. " },"
parts[#parts + 1] = "    root = " .. q(opts.root or "") .. ","
parts[#parts + 1] = "    upstream = " .. q(opts.upstream or "") .. ","
parts[#parts + 1] = "    cache = { layer = " .. q(cache_layer) .. " },"
parts[#parts + 1] = "    ssl = { cert = " .. q(opts.cert or "") .. ", key = " .. q(opts.key or "") .. " },"
parts[#parts + 1] = "    rate_limit = { enabled = true, req_per_sec = " .. (opts.rate or "50") ..
                    ", burst = " .. (opts.burst or "100") .. ", conn = 100 },"
parts[#parts + 1] = "    waf = { enabled = " .. tostring(waf_enabled) .. ", groups = { " ..
                    table.concat((function()
                        local t = {}; for _, g in ipairs(waf_groups) do t[#t + 1] = q(g) end; return t end)(), ", ") ..
                    " }, threshold = 5 },"
if #locations > 0 then
    parts[#parts + 1] = "    locations = {"
    for _, l in ipairs(locations) do
        parts[#parts + 1] = string.format("        { prefix = %q, upstream = %q, cache = %q },", l.prefix, l.upstream, l.cache)
    end
    parts[#parts + 1] = "    },"
end
if #forwards > 0 then
    parts[#parts + 1] = "    port_forward = {"
    for _, f in ipairs(forwards) do
        parts[#parts + 1] = string.format("        { listen = %d, target = %q },", f.listen, f.target)
    end
    parts[#parts + 1] = "    },"
end
if live then
    parts[#parts + 1] = string.format("    live = { enabled = true, app = %q, hls = { enabled = true, path = %q, fragment = %q, playlist_length = %q } },",
        live.app, live.hls.path, live.hls.fragment, live.hls.playlist_length)
end
parts[#parts + 1] = "}"
local site_src = table.concat(parts, "\n") .. "\n"

local src = SITES_DIR .. "/" .. name .. ".lua"
local fh = assert(io.open(src, "w")); fh:write(site_src); fh:close()
if not sh(string.format("%s -b %q %q", LJ, src, SITES_DIR .. "/" .. name .. ".ljbc")) then
    die("luajit compile failed")
end

-- ---------- 端口转发配置 (stream) ----------
local need_reload = false
local stream_conf = ""
for _, f in ipairs(forwards) do
    stream_conf = stream_conf .. string.format([[
server {
    listen %d;
    proxy_pass %s;
    proxy_connect_timeout 10s;
    proxy_timeout 1h;
    proxy_socket_keepalive on;
}

]], f.listen, f.target)
end
if stream_conf ~= "" then
    need_reload = write_if_changed(GEN_DIR .. "/stream-" .. name .. ".conf",
        "# sitectl: " .. name .. " port forwarding\n" .. stream_conf) or need_reload
else
    if os.remove(GEN_DIR .. "/stream-" .. name .. ".conf") then need_reload = true end
end

-- ---------- 直播推流 / HLS (rtmp) ----------
local rtmp_conf = ""
if live then
    rtmp_conf = string.format([[
application %s {
    live on;
    hls on;
    hls_path %s;
    hls_fragment %s;
    hls_playlist_length %s;
    hls_fragment_slicing aligned;
    hls_cleanup on;
    hls_nested on;
}

]], live.app, live.hls.path, live.hls.fragment, live.hls.playlist_length)
    need_reload = write_if_changed(GEN_DIR .. "/rtmp-" .. name .. ".conf",
        "# sitectl: " .. name .. " live ( GOP <= fragment 才能切出目标时长 )\n" .. rtmp_conf) or need_reload
else
    if os.remove(GEN_DIR .. "/rtmp-" .. name .. ".conf") then need_reload = true end
end

-- ---------- 配置快照 (审计) ----------
local snapshot = string.format([[# 自动生成 (sitectl) %s
# 站点: %s  hosts: %s
# 说明: HTTP 站点由 Lua 注册表驱动(零 reload);
#       端口转发/直播需 reload 才生效, CLI 已自动处理
# cache.layer = %s
# port_forward = %d 条
# live = %s
]], os.date("%Y-%m-%d %H:%M:%S"), name, table.concat(hosts, ","), cache_layer, #forwards,
    live and (live.app .. " -> " .. live.hls.path) or "off")
write_if_changed(GEN_DIR .. "/" .. name .. ".conf", snapshot)

print(admin("reload"))
if need_reload then
    sh(NGINX .. " -s reload")
    print("reloaded (stream/rtmp changed)")
end
