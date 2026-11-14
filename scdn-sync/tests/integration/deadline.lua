local http = require 'scdn_sync.http'
local started = ngx.now()
local ok, err = pcall(http.request, { scheme = 'http', host = '127.0.0.1', port = tonumber(arg[1]),
    read_ms = 5000, total_ms = 600 }, 'GET', '/', nil, nil, 1024)
assert(not ok and type(err) == 'table' and err.code == 'network_deadline')
assert(ngx.now() - started >= 0.5 and ngx.now() - started < 2)
print('absolute network deadline passed')
