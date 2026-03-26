-- admin/auth.lua — JWT session middleware for the admin API
-- Called from access_by_lua_block in nginx config.

local jwt = require("utils.jwt")

local M = {}

-- Validate the aig_admin cookie and populate ngx.ctx.admin_user.
-- Calls ngx.exit(401) on failure — halts the request before content_by_lua.
function M.require_session()
    local cookie = ngx.var.http_cookie or ""
    local token  = cookie:match("aig_admin=([^;%s]+)")
    if not token then
        ngx.status = 401
        ngx.header["Content-Type"] = "application/json"
        ngx.header["Access-Control-Allow-Origin"]      = ngx.var.http_origin or "*"
        ngx.header["Access-Control-Allow-Credentials"] = "true"
        ngx.print('{"error":"unauthenticated"}')
        ngx.exit(401)
        return
    end

    local payload, err = jwt.verify(token)
    if not payload then
        ngx.status = 401
        ngx.header["Content-Type"] = "application/json"
        ngx.header["Access-Control-Allow-Origin"]      = ngx.var.http_origin or "*"
        ngx.header["Access-Control-Allow-Credentials"] = "true"
        ngx.print('{"error":"' .. (err or "invalid token") .. '"}')
        ngx.exit(401)
        return
    end

    ngx.ctx.admin_user = {
        id     = payload.sub,
        email  = payload.email,
        role   = payload.role,
        org_id = payload.org,
    }
end

-- Returns true if the current admin user is allowed to access the given org_id.
-- Platform admins (role='admin') pass unconditionally.
-- Org members (role='member'|'viewer') pass only for their own org.
function M.check_org(org_id)
    local u = ngx.ctx.admin_user
    if not u then return false end
    if u.role == "admin" then return true end
    if u.org_id == org_id then return true end
    return false
end

return M
