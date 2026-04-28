-- utils/feedback_context.lua — validate, sanitise, and enrich the client_context
-- JSON blob attached to feedback / content-report submissions.
--
-- Contract:
--   - Input is whatever the client posted (any Lua value).
--   - Output is a JSON string ≤ 16384 bytes (or nil + error).
--   - schema_version must be an integer in 1..MAX_SCHEMA_VERSION.
--   - Recognised top-level keys land in their canonical place.
--   - Unknown top-level keys are quarantined under "_unknown" (capped 4 KiB,
--     truncated keys recorded under "_unknown_truncated": true).
--   - Client-supplied identity-ish keys are stripped: those go in the dedicated
--     "_server" sub-object enriched server-side and never come from the client.
--   - The server-side enrichment is added by the caller via enrich(server_ctx).

local cjson = require("cjson.safe")

local M = {}

M.MAX_SIZE_BYTES         = 16384
M.MAX_UNKNOWN_BYTES      = 4096
M.MAX_SCHEMA_VERSION     = 1
M.MIN_SCHEMA_VERSION     = 1

-- Top-level keys the client is allowed to fill. Anything else becomes
-- _unknown.<key>.  The set is permissive (stuff we expect to grow over time)
-- but explicit so a typo or injection surfaces as quarantine, not data.
local ALLOWED_KEYS = {
    schema_version = true,
    submitted_at   = true,
    app_version    = true,
    app_type       = true,
    uptime_sec     = true,
    timezone       = true,
    locale         = true,
    screen         = true,
    viewport       = true,
    user_agent     = true,
    platform       = true,
    online         = true,
    connection     = true,
    save_data      = true,
    color_scheme   = true,
    reduced_motion = true,
    current_route  = true,
    referrer       = true,
    -- Layer 2 (native bridge) — added when populated.
    device_model_raw = true,
    os_version       = true,
    device_arch      = true,
    battery_pct      = true,
    battery_charging = true,
    disk_free_bytes  = true,
    disk_total_bytes = true,
    connection_type  = true,
    carrier          = true,
    uptime_app_sec   = true,
}

-- Identity-ish keys the client must never set: server enriches these.
local STRIP_KEYS = {
    client_ip   = true,
    tenant_id   = true,
    user_id     = true,
    user_role   = true,
    request_id  = true,
    session_id  = true,
    _server     = true,  -- client must not pre-fill the server slot
}

-- Validate + sanitise + return a Lua table (without serialising yet) so the
-- caller can attach _server enrichment then encode once at the end.
function M.parse(raw)
    if raw == nil or raw == cjson.null then
        return {}, nil
    end
    if type(raw) ~= "table" then
        return nil, "client_context must be an object"
    end

    -- schema_version: required when client_context is non-empty.
    local sv = raw.schema_version
    if sv ~= nil then
        if type(sv) ~= "number" or sv ~= math.floor(sv)
           or sv < M.MIN_SCHEMA_VERSION or sv > M.MAX_SCHEMA_VERSION then
            return nil, "schema_version must be an integer in "
                        .. M.MIN_SCHEMA_VERSION .. ".." .. M.MAX_SCHEMA_VERSION
        end
    end

    local out     = {}
    local unknown = {}
    local unknown_size = 0

    for k, v in pairs(raw) do
        if STRIP_KEYS[k] then
            -- silently dropped — server overwrites
        elseif ALLOWED_KEYS[k] then
            out[k] = v
        else
            -- Estimate cost using the encoded representation; this gives a
            -- consistent ceiling regardless of what the client passed.
            local enc = cjson.encode({ [k] = v }) or ""
            if unknown_size + #enc <= M.MAX_UNKNOWN_BYTES then
                unknown[k] = v
                unknown_size = unknown_size + #enc
            else
                out._unknown_truncated = true
            end
        end
    end
    if next(unknown) then
        out._unknown = unknown
    end
    return out, nil
end

-- Add the server-side identity / request envelope. server_ctx fields land under
-- _server. Caller should pass: { request_id, client_ip, tenant_id, user_id,
-- user_role, session_id, received_at }.
function M.enrich(ctx, server_ctx)
    ctx = ctx or {}
    local s = {}
    for k, v in pairs(server_ctx or {}) do
        if v ~= nil then s[k] = v end
    end
    ctx._server = s
    return ctx
end

-- Final encode + size check. Returns (json_string, nil) or (nil, error).
function M.encode(ctx)
    if not ctx or not next(ctx) then return nil, nil end  -- empty → store NULL
    local s, err = cjson.encode(ctx)
    if not s then return nil, "client_context encode failed: " .. tostring(err) end
    if #s > M.MAX_SIZE_BYTES then
        return nil, "client_context too large (" .. #s .. " > " .. M.MAX_SIZE_BYTES .. ")"
    end
    return s, nil
end

-- Convenience: parse + enrich + encode in one call.
function M.process(raw, server_ctx)
    local ctx, err = M.parse(raw)
    if err then return nil, err end
    ctx = M.enrich(ctx, server_ctx)
    return M.encode(ctx)
end

return M
