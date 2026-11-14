-- 全局配置中心: 所有可调参数集中于此, 编译为 LuaJIT 字节码供 nginx 引用
local _M = {
    version = "1.0.0",

    -- 回源
    upstream = {
        name    = "example_origin",
        servers = { "127.0.0.1:18080" },
    },

    -- 分级缓存
    cache = {
        l1 = {
            path            = "/var/cache/openresty/L1",
            max_size_gb     = 32,
            inactive_min    = 90,      -- 90 分钟无访问淘汰回 L2
            max_file_mb     = 512,     -- 单文件上限
            ttl_days        = 3650,
        },
        l2 = {
            path            = "/var/cache/openresty/L2",
            max_size_gb     = 2000,
            min_free_gb     = 50,
            inactive_days   = 3650,
            max_file_gb     = 32,
            ttl_days        = 3650,
        },
    },

    -- 热度晋级
    tier = {
        promote_hits   = 3,        -- 窗口内命中 N 次晋级 L1
        window_seconds = 5400,     -- 90 分钟滑窗
    },

    -- 日志
    logs = {
        dir             = "/var/log/openresty",
        access_keep     = 180,
        error_keep      = 365,
    },
}

return _M
