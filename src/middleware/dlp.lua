-- middleware/dlp.lua — Data Loss Prevention: scan and optionally scrub PII
-- Patterns are evaluated against the serialised request body.
-- Actions: "block" | "scrub" | "flag" (log only)
-- Config (in gateway_config.dlp):
--   { enabled = true, action = "scrub", patterns = ["email","cc","ssn"] }

local errors   = require("core.errors")
local req_util = require("utils.request")

local M = {}

-- Built-in pattern library (Lua patterns only — no {n,m} quantifier support)
local PATTERNS = {
    email   = "[a-zA-Z0-9%._%+%-]+@[a-zA-Z0-9%-%.]+%.[a-zA-Z][a-zA-Z]+",
    ssn     = "%d%d%d%-?%d%d%-?%d%d%d%d",
    cc      = "%d%d%d%d[%s%-]?%d%d%d%d[%s%-]?%d%d%d%d[%s%-]?%d%d%d%d",
    phone   = "%+?%d[%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-][%d%s%(%)%-]",
    api_key = "[Aa][Pp][Ii][_%-]?[Kk][Ee][Yy][\"'%s]*[:=][\"'%s]*[%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_][%w%-_]+",
    jwt     = "ey[A-Za-z0-9%-_]+%.[A-Za-z0-9%-_]+%.[A-Za-z0-9%-_]+",
}

local REDACTED = "[REDACTED]"

local function scrub(text, pattern_names)
    for _, name in ipairs(pattern_names) do
        local pat = PATTERNS[name]
        if pat then
            text = text:gsub(pat, REDACTED)
        end
    end
    return text
end

local function has_match(text, pattern_names)
    for _, name in ipairs(pattern_names) do
        local pat = PATTERNS[name]
        if pat and text:find(pat) then
            return true, name
        end
    end
    return false
end

function M.run(ctx)
    local dlp_cfg = ctx.gateway_config.dlp
    if not dlp_cfg or not dlp_cfg.enabled then return end

    -- Ensure body is read
    if not ctx.raw_request_body then
        ctx.raw_request_body = req_util.read_body() or ""
    end

    local body_str = ctx.raw_request_body
    local patterns = dlp_cfg.patterns or { "email", "ssn", "cc" }
    local action   = dlp_cfg.action   or "flag"

    if action == "block" then
        local matched, which = has_match(body_str, patterns)
        if matched then
            ngx.log(ngx.WARN, "DLP block: pattern=", which,
                    " tenant=", ctx.tenant_id, " gw=", ctx.gateway_id)
            ctx.log_fields = ctx.log_fields or {}
            ctx.log_fields.blocked_by   = "dlp"
            ctx.log_fields.block_reason = which
            errors.send("DLP_BLOCKED", "Request contains sensitive data: " .. which)
        end

    elseif action == "scrub" then
        local scrubbed = scrub(body_str, patterns)
        if scrubbed ~= body_str then
            ngx.log(ngx.INFO, "DLP scrub applied tenant=", ctx.tenant_id)
            ctx.raw_request_body = scrubbed
            ngx.req.set_body_data(scrubbed)
        end

    elseif action == "flag" then
        local matched, which = has_match(body_str, patterns)
        if matched then
            ngx.log(ngx.WARN, "DLP flag: pattern=", which,
                    " tenant=", ctx.tenant_id, " gw=", ctx.gateway_id)
            ctx.dlp_flagged = which
        end
    end
end

return M
