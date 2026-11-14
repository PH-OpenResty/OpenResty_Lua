-- Test driver for the internal module API; this is not an installed management CLI.
local config = require 'scdn_sync.config'
local json = require 'scdn_sync.codec'
local settings = config.load(assert(arg[2]))
local input = json.decode(config.read(assert(arg[3]), 4 * 1024 * 1024))
if arg[1] == 'publish' then
    local store = require('scdn_sync.fs').open(settings.data_dir)
    local result = require('scdn_sync.master.publish').new(store, settings):publish(input, ngx.time())
    print(json.encode(result))
elseif arg[1] == 'sign' then
    print(json.encode(require('scdn_sync.auth').sign_request(settings.master_endpoint.authority,
        input.path, input.body, settings.request_identity, ngx.time())))
else error('unsupported test action') end
