-- core/errors.lua — typed error codes and HTTP response helpers
local json = require("utils.json")

local M = {}

M.codes = {
    UNAUTHORIZED        = { status = 401, code = "unauthorized",          msg = "Missing or invalid gateway token" },
    FORBIDDEN           = { status = 403, code = "forbidden",             msg = "Access denied" },
    TENANT_NOT_FOUND    = { status = 404, code = "tenant_not_found",      msg = "Tenant or gateway not found" },
    RATE_LIMITED        = { status = 429, code = "rate_limited",          msg = "Rate limit exceeded" },
    QUOTA_EXCEEDED      = { status = 429, code = "quota_exceeded",        msg = "Budget quota exceeded" },
    PROVIDER_ERROR      = { status = 502, code = "provider_error",        msg = "Upstream provider returned an error" },
    ALL_PROVIDERS_FAILED= { status = 502, code = "all_providers_failed",  msg = "All configured providers failed" },
    GUARDRAIL_BLOCKED   = { status = 400, code = "guardrail_blocked",     msg = "Request blocked by content policy" },
    DLP_BLOCKED         = { status = 400, code = "dlp_blocked",           msg = "Request blocked by DLP policy" },
    INVALID_REQUEST     = { status = 400, code = "invalid_request",       msg = "Malformed request" },
    INTERNAL            = { status = 500, code = "internal_error",        msg = "Internal gateway error" },
}

-- Send a JSON error response and exit the current phase.
function M.send(code_key, detail)
    local err = M.codes[code_key] or M.codes.INTERNAL
    ngx.status = err.status
    ngx.header["Content-Type"] = "application/json"
    ngx.header["X-AIG-Error"] = err.code
    ngx.print(json.encode({
        error = {
            code    = err.code,
            message = detail or err.msg,
        }
    }))
    ngx.exit(err.status)
end

return M
