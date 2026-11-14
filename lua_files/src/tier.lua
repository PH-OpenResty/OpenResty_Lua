-- 热/冷层判定: 90 分钟滑窗内访问次数达到阈值则走 L1
local config = require("config")
local _M = {}

function _M.classify(uri)
    local dict = ngx.shared.hot_tracker
    if not dict then
        return "l2"
    end
    local n = dict:incr(uri, 1, 0, config.tier.window_seconds)
    if n and n >= config.tier.promote_hits then
        return "l1"
    end
    return "l2"
end

-- 仅读取计数, 不自增 (供调试/stat 使用)
function _M.hits(uri)
    local dict = ngx.shared.hot_tracker
    if not dict then return 0 end
    return dict:get(uri) or 0
end

return _M
