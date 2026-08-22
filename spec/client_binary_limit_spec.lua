package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["ltn12"] = function()
    return { source = { string = function() return function() end end } }
end
package.preload["logger"] = function()
    return { info = function() end, err = function() end }
end
package.preload["socketutil"] = function()
    return { set_timeout = function() end, reset_timeout = function() end }
end
package.preload["socket.http"] = function()
    return {
        request = function(options)
            options.sink("12345")
            return 1, 200, { ["content-type"] = "application/octet-stream" }, "OK"
        end,
    }
end
package.preload["weread.lib.protocol"] = function()
    return { USER_AGENT = "limit spec" }
end

local Client = require("weread.lib.client")
local client = Client:new{
    get = function(_self, _key, default) return default end,
    merge_set_cookie = function() end,
}
local ok, err = pcall(function()
    client:get_binary("https://cdn.example.test/file", { max_bytes = 4 })
end)
assert(not ok and tostring(err):find("maximum allowed size", 1, true),
    "oversized in-memory binary response was accepted")

print("client_binary_limit_spec: 1 check")
