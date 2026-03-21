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

    -- Check expiry (expires_at is Unix seconds INTEGER or NULL)
    if row.expires_at then
        if ngx.time() > row.expires_at then
            errors.send("UNAUTHORIZED", "Token expired")
        end
    end

    ctx.token_id         = row.id
    ctx.token_label      = row.label
    ctx.token_budget_usd = row.budget_usd
    ctx.token_rate_limit = row.rate_limit  -- raw JSON string, parsed by rate_limit middleware

    -- User-bound token checks
    if row.user_id then
        local user, uerr = storage.get_user(row.user_id)
        if uerr then
            ngx.log(ngx.ERR, "auth user lookup error: ", uerr)
            errors.send("INTERNAL")
        end
        if not user or user.deleted_at then
            errors.send("UNAUTHORIZED", "User account disabled")
        end
        -- viewer role cannot make inference calls
        if user.role == "viewer" then
            errors.send("FORBIDDEN", "Viewer role cannot make inference requests")
        end
        -- member role: check per-gateway access
        if user.role == "member" then
            local has_access = storage.check_user_gateway_access(user.id, ctx.gateway_id)
            if not has_access then
                errors.send("FORBIDDEN", "Gateway not accessible to this user")
            end
        end
        ctx.user_id   = user.id
        ctx.user_role = user.role
    end
end

return M
