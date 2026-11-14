-- 把 L1 内存层中 L2 尚不存在的缓存文件落盘到 L2
-- 缓存文件名即 key 的 MD5 分级路径, 两级使用同一 proxy_cache_key, 因此可直接按相对路径复制
local L1 = "/var/cache/openresty/L1"
local L2 = "/var/cache/openresty/L2"
local OWNER = "nobody:nogroup"

local function exists(p)
    local f = io.open(p, "rb")
    if f then f:close() return true end
    return false
end

local function dirname(p)
    return p:match("^(.*)/[^/]+$") or "."
end

local copied, skipped, failed = 0, 0, 0
local p = io.popen("find '" .. L1 .. "' -type f 2>/dev/null")
if not p then
    io.stderr:write("cannot scan " .. L1 .. "\n")
    os.exit(1)
end

for src in p:lines() do
    local rel = src:sub(#L1 + 2)
    local dst = L2 .. "/" .. rel
    if exists(dst) then
        skipped = skipped + 1
    else
        local tmp = dst .. ".flush.tmp"
        local cmd = string.format(
            "mkdir -p '%s' && cp -p '%s' '%s' && mv -f '%s' '%s' && chown %s '%s'",
            dirname(dst), src, tmp, tmp, dst, OWNER, dst)
        local rc = os.execute(cmd)
        if rc == 0 or rc == true then
            copied = copied + 1
        else
            failed = failed + 1
            io.stderr:write(string.format("flush failed rc=%s: %s\n", tostring(rc), cmd))
        end
    end
end
p:close()

print(string.format("flush L1->L2: copied=%d skipped=%d failed=%d", copied, skipped, failed))
os.exit(failed > 0 and 1 or 0)
