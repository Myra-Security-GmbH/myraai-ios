-- admin/auth.lua — JWT session middleware for the admin API
-- Called from access_by_lua_block in nginx config.

local jwt     = require("utils.jwt")
local storage = require("storage")

local CORS_ORIGIN = os.getenv("AIG_ADMIN_CORS_ORIGIN")

local M = {}

-- Validate the aig_admin cookie and populate ngx.ctx.admin_user.
-- Calls ngx.exit(401) on failure — halts the request before content_by_lua.
function M.require_session()
    local cookie = ngx.var.http_cookie or ""
    local token  = cookie:match("aig_admin=([^;%s]+)")
    if not token then
        ngx.status = 401
        ngx.header["Content-Type"] = "application/json"
        ngx.header["Access-Control-Allow-Origin"]      = CORS_ORIGIN
        ngx.header["Access-Control-Allow-Credentials"] = "true"
        ngx.print('{"error":"unauthenticated"}')
        ngx.exit(401)
        return
    end

    local payload, err = jwt.verify(token)
    if not payload then
        ngx.status = 401
        ngx.header["Content-Type"] = "application/json"
        ngx.header["Access-Control-Allow-Origin"]      = CORS_ORIGIN
        ngx.header["Access-Control-Allow-Credentials"] = "true"
        ngx.print('{"error":"' .. (err or "invalid token") .. '"}')
        ngx.exit(401)
        return
    end

    -- Re-validate against the DB to pick up role changes and catch soft-deleted users.
    local user = storage.get_user(payload.sub)
    if not user or user.deleted_at then
        ngx.status = 401
        ngx.header["Content-Type"] = "application/json"
        ngx.print('{"error":"account not found or deleted"}')
        ngx.exit(401)
        return
    end

    ngx.ctx.admin_user = {
        id        = user.id,
        email     = user.email,
        role      = user.role,
        tenant_id = user.tenant_id,
    }
end

-- Returns true if the current admin user is allowed to access the given tenant_id.
-- Platform admins (role='admin') pass unconditionally.
-- Other roles pass only for their own tenant.
function M.check_tenant(tenant_id)
    local u = ngx.ctx.admin_user
    if not u then return false end
    if u.role == "admin" then return true end
    if u.tenant_id == tenant_id then return true end
    return false
end

return M
