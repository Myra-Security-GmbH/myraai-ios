-- cache/key.lua — deterministic cache key from request parameters
-- Key = SHA-256( provider:model:sorted_canonical_json_of_body )
-- Fields excluded from the key: stream, user, metadata headers.

local sha256_lib = require("resty.sha256")
local str_lib    = require("resty.string")
local json       = require("utils.json")

local M = {}

-- Fields that must NOT affect cache identity
local EXCLUDE = {
    stream = true,
    user   = true,
}

-- Produce a stable JSON string for a Lua table (keys sorted).
local function stable_json(t)
    if type(t) ~= "table" then return json.encode(t) end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = t[k]
        if not EXCLUDE[k] then
            local vs = type(v) == "table" and stable_json(v) or json.encode(v)
            parts[#parts + 1] = json.encode(tostring(k)) .. ":" .. vs
        end
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Returns a hex SHA-256 cache key, or nil if the request is not cacheable.
-- Requests with stream=true are not cached.
function M.build(ctx)
    local body = ctx.request_body
    if not body then return nil end
    if body.stream then return nil end  -- streaming responses are not cached

    local provider = ctx.provider
    local model    = ctx.model or (body.model or "")

    local h = sha256_lib:new()
    h:update(provider)
    h:update(":")
    h:update(model)
    h:update(":")
    h:update(stable_json(body))

    return "cache:" .. str_lib.to_hex(h:final())
end

return M
