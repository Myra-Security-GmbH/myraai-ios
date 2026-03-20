-- middleware/auth.lua — validate x-aig-token (or Authorization: Bearer)
-- Skipped when gateway_config.auth_required == false (default: true).

local storage = require("storage")
local crypto  = require("utils.crypto")
local errors  = require("core.errors")

local M = {}

local function extract_token()
    -- 1. Dedicated gateway header
    local token = ngx.var.http_x_aig_token
    if token and token ~= "" then return token end

    -- 2. Standard Bearer (Authorization: Bearer <token>)
    local auth = ngx.var.http_authorization
    if auth and auth ~= "" then
        local t = auth:match("^[Bb]earer%s+(.+)$")
        if t then return t end
    end

    -- 3. x-api-key — sent by Anthropic SDK when using a custom base URL
    local api_key = ngx.var.http_x_api_key
    if api_key and api_key ~= "" then return api_key end
end

function M.run(ctx)
    local gw = ctx.gateway_config

    -- Auth is required by default; gateway can opt out for open gateways
    if gw.auth_required == false then
        return
    end

    local token = extract_token()
    if not token then
        errors.send("UNAUTHORIZED")
    end

    local hash = crypto.sha256_hex(token)
    local row, err = storage.get_auth_token(ctx.gateway_id, hash)

    if err then
        ngx.log(ngx.ERR, "auth lookup error: ", err)
        errors.send("INTERNAL")
    end

    if not row then
        errors.send("UNAUTHORIZED")
    end

    -- Check expiry
    if row.expires_at and row.expires_at ~= "" then
        -- expires_at is ISO8601; compare lexicographically (works for UTC)
        local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
        if now > row.expires_at then
            errors.send("UNAUTHORIZED", "Token expired")
        end
    end

    ctx.token_id = row.id
end

return M
