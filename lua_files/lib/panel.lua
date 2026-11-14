-- 网页面板 + 管理 API: 把 sitectl 的能力暴露成 HTTP
local cjson    = require "cjson.safe"
local registry = require "lib.registry"

local _M = {}
local SITECTL = "/usr/local/openresty/lua_files/cli/sitectl.lua"
local RESTY   = "/usr/local/openresty/bin/resty"

local function sh(cmd)
    local p = io.popen(cmd .. " 2>&1")
    local out = p and p:read("*a") or ""
    local ok = p and p:close()
    return out, ok
end

local function reply(code, obj)
    ngx.status = code
    ngx.header["Content-Type"] = "application/json"
    ngx.say(cjson.encode(obj))
    return ngx.exit(code)
end

local function valid(s, pat) return s and s:match(pat) ~= nil end
local function q(s) return "'" .. tostring(s):gsub("'", "") .. "'" end

local function site_args(b)
    local a = { "add", b.name, "--host=" .. b.hosts }
    if b.root and b.root ~= "" then a[#a + 1] = "--root=" .. b.root end
    if b.upstream and b.upstream ~= "" then a[#a + 1] = "--upstream=" .. b.upstream end
    if b.cache and b.cache ~= "" then a[#a + 1] = "--cache=" .. b.cache end
    if b.cert and b.cert ~= "" then a[#a + 1] = "--cert=" .. b.cert end
    if b.key and b.key ~= "" then a[#a + 1] = "--key=" .. b.key end
    if b.waf then a[#a + 1] = "--waf=" .. b.waf else a[#a + 1] = "--no-waf" end
    if b.rate then a[#a + 1] = "--rate=" .. b.rate end
    return a
end

function _M.api()
    local method = ngx.req.get_method()
    local uri = ngx.var.uri

    if method == "GET" and uri == "/api/sites" then
        local d = ngx.shared.sites_registry
        local gen = d:get("gen") or 0
        return reply(200, { ok = true, gen = gen, hosts = registry.hosts() })
    end

    if method == "GET" and uri == "/api/metrics" then
        local d = ngx.shared.metrics_dict
        local out = {}
        for _, k in ipairs(d:get_keys(0)) do
            local site = k:match("^req|(.+)$")
            if site then
                out[#out + 1] = { site = site, requests = d:get(k),
                                  bytes = d:get("bytes|" .. site) or 0 }
            end
        end
        return reply(200, { ok = true, sites = out })
    end

    if method == "POST" and uri == "/api/metrics/reset" then
        local d = ngx.shared.metrics_dict
        d:flush_all(); d:flush_expired()
        return reply(200, { ok = true })
    end

    if method == "POST" and uri == "/api/reload" then
        local n, err = registry.reload()
        if not n then return reply(500, { ok = false, err = err }) end
        return reply(200, { ok = true, sites = n })
    end

    if method == "POST" and uri == "/api/sites" then
        ngx.req.read_body()
        local b = cjson.decode(ngx.req.get_body_data() or "")
        if not b then return reply(400, { ok = false, err = "invalid json" }) end
        if not valid(b.name, "^[%w_%-]+$") then return reply(400, { ok = false, err = "invalid name" }) end
        if not valid(b.hosts, "^[%w%._%-]+$") then return reply(400, { ok = false, err = "invalid hosts" }) end
        if b.root and b.root ~= "" and not valid(b.root, "^/[%w%._/%-]*$") then
            return reply(400, { ok = false, err = "invalid root" })
        end
        if b.upstream and b.upstream ~= "" and not valid(b.upstream, "^[%w%._%-]+:%d+$") then
            return reply(400, { ok = false, err = "invalid upstream" })
        end
        if b.cache and not (b.cache == "l1" or b.cache == "l2" or b.cache == "off") then
            return reply(400, { ok = false, err = "invalid cache" })
        end

        local args = site_args(b)
        local cmd = RESTY .. " " .. SITECTL
        for _, x in ipairs(args) do cmd = cmd .. " " .. q(x) end
        local out = sh(cmd)
        return reply(200, { ok = true, output = out })
    end

    if method == "DELETE" and uri:match("^/api/sites/") then
        local name = uri:match("^/api/sites/([%w_%-]+)$")
        if not name then return reply(400, { ok = false, err = "invalid name" }) end
        local out = sh(RESTY .. " " .. SITECTL .. " del " .. q(name))
        return reply(200, { ok = true, output = out })
    end

    return reply(404, { ok = false, err = "unknown endpoint" })
end

function _M.ui()
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.print([[
<!doctype html><html lang="zh"><head><meta charset="utf-8">
<title>OpenResty 控制面板</title>
<style>
body{font-family:system-ui,sans-serif;margin:24px;background:#0f172a;color:#e2e8f0}
h1{font-size:20px} table{width:100%;border-collapse:collapse;margin-top:12px}
td,th{border-bottom:1px solid #334155;padding:8px;text-align:left}
input,select{background:#1e293b;color:#e2e8f0;border:1px solid #475569;padding:6px;border-radius:4px}
button{background:#2563eb;color:#fff;border:0;padding:8px 14px;border-radius:4px;cursor:pointer}
button.del{background:#dc2626} .row{display:flex;gap:8px;flex-wrap:wrap;margin:8px 0}
pre{background:#1e293b;padding:12px;border-radius:6px;overflow:auto;max-height:240px}
</style></head><body>
<h1>OpenResty 站点控制面板</h1>
<div class="row">
  <input id="name" placeholder="站点名 (如 mysite)">
  <input id="hosts" placeholder="域名, 逗号分隔" size="28">
  <input id="root" placeholder="静态根 /data/site">
  <input id="upstream" placeholder="反代 127.0.0.1:8080">
  <select id="cache"><option value="l2">L2 缓存</option><option value="l1">L1 缓存</option><option value="off">不缓存</option></select>
  <button onclick="addSite()">新增 / 更新</button>
  <button onclick="reloadReg()">刷新注册表</button>
</div>
<table><thead><tr><th>Host</th><th>操作</th></tr></thead><tbody id="sites"></tbody></table>
<h3>流量 (来自 metrics_dict)</h3>
<table><thead><tr><th>站点</th><th>请求数</th><th>字节</th></tr></thead><tbody id="metrics"></tbody></table>
<pre id="out"></pre>
<script>
async function api(m,u,b){
  const r=await fetch(u,{method:m,headers:{'Content-Type':'application/json'},body:b?JSON.stringify(b):undefined});
  return r.json();
}
async function load(){
  const d=await api('GET','/api/sites');
  document.getElementById('sites').innerHTML=(d.hosts||[]).map(h=>
    `<tr><td>${h}</td><td><button class="del" onclick="delSite('${h}')">删除</button></td></tr>`).join('');
  const m=await api('GET','/api/metrics');
  document.getElementById('metrics').innerHTML=(m.sites||[]).map(s=>
    `<tr><td>${s.site}</td><td>${s.requests}</td><td>${s.bytes}</td></tr>`).join('');
}
async function addSite(){
  const b={name:name.value,hosts:hosts.value,root:root.value,upstream:upstream.value,cache:cache.value};
  const r=await api('POST','/api/sites',b);
  document.getElementById('out').textContent=JSON.stringify(r,null,2); load();
}
async function delSite(n){
  if(!confirm('删除站点 '+n+' ?'))return;
  const r=await api('DELETE','/api/sites/'+n);
  document.getElementById('out').textContent=JSON.stringify(r,null,2); load();
}
async function reloadReg(){
  const r=await api('POST','/api/reload');
  document.getElementById('out').textContent=JSON.stringify(r,null,2); load();
}
load();
</script></body></html>]])
end

return _M
