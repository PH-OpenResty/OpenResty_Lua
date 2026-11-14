-- Opt-in package-path adapter for the existing lib.route / lib.admin modules.
local runtime = require 'scdn_sync.runtime.registry'
return { lookup = runtime.lookup, hosts = runtime.hosts,
    reload = function() return nil, 'managed sites require an authenticated version transaction' end }
