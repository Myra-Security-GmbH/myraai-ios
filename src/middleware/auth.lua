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
        errors.send("UNAUTHORIZED"); return
    end

    local hash = crypto.sha256_hex(token)
    local row, err = storage.get_auth_token(ctx.gateway_id, hash)

    if err then
        ngx.log(ngx.ERR, "auth lookup error gateway=", ctx.gateway_id, " err=", err)
        errors.send("INTERNAL"); return
    end

    if not row then
        errors.send("UNAUTHORIZED"); return
    end

    -- Check expiry (expires_at is Unix seconds INTEGER or NULL)
    if row.expires_at then
        if ngx.time() > row.expires_at then
            errors.send("UNAUTHORIZED", "Token expired"); return
        end
    end

    ctx.token_id            = row.id
    ctx.token_label         = row.label
    ctx.token_budget_usd    = row.budget_usd
    ctx.token_budget_period = row.budget_period or "monthly"
    ctx.token_rate_limit    = row.rate_limit  -- raw JSON string, parsed by rate_limit middleware

    -- Start a playground trace for playground tokens
    if row.label == "playground" then
        ctx.trace_id  = ctx.request_id  -- reuse request_id as trace_id
        ctx.trace_seq = 0
        pcall(function()
            storage.create_playground_trace(ctx.trace_id, ctx.gateway_id, nil)
        end)
    end

    -- User-bound token checks.
    -- Playground tokens carry user_id for audit attribution only — the admin
    -- session already authenticated the user, so skip account validation.
    if row.user_id and row.label ~= "playground" then
        local user, uerr = storage.get_user(row.user_id)
        if uerr then
            ngx.log(ngx.ERR, "auth user lookup error gateway=", ctx.gateway_id,
                    " user_id=", row.user_id, " err=", uerr)
            errors.send("INTERNAL"); return
        end
        if not user or user.deleted_at then
            errors.send("UNAUTHORIZED", "User account disabled"); return
        end
        -- viewer role cannot make inference calls
        if user.role == "viewer" then
            errors.send("FORBIDDEN", "Viewer role cannot make inference requests"); return
        end
        -- member role has access to all gateways in their org (no per-gateway check)
        ctx.user_id   = user.id
        ctx.user_role = user.role
    elseif row.user_id then
        -- playground token: record user_id for cost attribution without re-validating
        ctx.user_id = row.user_id
    end
end

return M
