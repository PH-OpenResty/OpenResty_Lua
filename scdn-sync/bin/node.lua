local ok, err = pcall(function()
    local config = require 'scdn_sync.config'
    local settings = config.load(assert(arg[1], 'node config path is required'))
    require('scdn_sync.node.daemon').run(settings, require('scdn_sync.fs').open(settings.data_dir))
end)
if not ok then
    ngx.log(ngx.ERR, 'scdn agent stopped: ', (require('scdn_sync.util').error_code(err)))
    return ngx.exit(ngx.ERROR)
end
