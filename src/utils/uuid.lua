-- utils/uuid.lua — RFC 4122 UUID v4 generation via resty.random
local random_lib = require("resty.random")
local str_lib    = require("resty.string")
local bit        = require("bit")  -- LuaJIT bit library; Lua 5.3 & / | not available

local M = {}

function M.v4()
    local b = random_lib.bytes(16, true)
    -- Set version bits (v4) and variant bits (RFC 4122)
    b = b:sub(1,6) .. string.char(
            bit.bor(bit.band(b:byte(7), 0x0f), 0x40),  -- version 4
            bit.bor(bit.band(b:byte(8), 0x3f), 0x80)   -- variant bits
        ) .. b:sub(9)
    local h = str_lib.to_hex(b)
    return h:sub(1,8)  .. "-" .. h:sub(9,12)  .. "-" ..
           h:sub(13,16) .. "-" .. h:sub(17,20) .. "-" .. h:sub(21)
end

return M
