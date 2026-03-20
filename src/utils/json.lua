-- utils/json.lua — cjson wrapper with safe error handling
local cjson = require("cjson.safe")
cjson.decode_array_with_array_mt(true)

local M = {}

function M.encode(val)
    local ok, result = pcall(cjson.encode, val)
    if not ok then
        ngx.log(ngx.ERR, "json.encode error: ", result)
        return nil, result
    end
    return result
end

function M.decode(str)
    if not str or str == "" then return {} end
    local ok, result = pcall(cjson.decode, str)
    if not ok then
        ngx.log(ngx.ERR, "json.decode error: ", result, " input: ", str:sub(1, 200))
        return nil, result
    end
    return result
end

return M
