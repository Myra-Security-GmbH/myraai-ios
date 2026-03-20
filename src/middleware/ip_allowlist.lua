-- middleware/ip_allowlist.lua — per-gateway CIDR allowlist
-- Config (in gateway_config.ip_allowlist): ["1.2.3.0/24", "10.0.0.0/8"]
-- Empty or absent list = allow all.

local errors = require("core.errors")
local bit     = require("bit")  -- LuaJIT bit library (no Lua 5.3 & / << operators)

local M = {}

-- Parse "a.b.c.d" into a 32-bit integer.
local function ip_to_int(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    return tonumber(a) * 16777216 + tonumber(b) * 65536
         + tonumber(c) * 256      + tonumber(d)
end

-- Returns true if ip_str falls within cidr_str (e.g. "10.0.0.0/8").
local function in_cidr(ip_str, cidr_str)
    local net, bits = cidr_str:match("^([^/]+)/(%d+)$")
    if not net then
        -- bare IP
        return ip_str == cidr_str
    end
    local ip_int  = ip_to_int(ip_str)
    local net_int = ip_to_int(net)
    if not ip_int or not net_int then return false end
    local nbits = tonumber(bits)
    local mask  = nbits == 0 and 0 or bit.lshift(-1, 32 - nbits)
    return bit.band(ip_int, mask) == bit.band(net_int, mask)
end

function M.run(ctx)
    local allowlist = ctx.gateway_config.ip_allowlist
    if not allowlist or #allowlist == 0 then return end

    local client_ip = ngx.var.remote_addr
    for _, cidr in ipairs(allowlist) do
        if in_cidr(client_ip, cidr) then return end
    end

    errors.send("FORBIDDEN", "Client IP not in allowlist")
end

return M
