-- admin/share.lua — Public read-only share endpoint (no authentication required)
--
-- GET /share/:token
--   Returns the conversation snapshot for the given share token.
--   Access-Control-Allow-Origin: * (public CORS)

local json    = require("utils.json")
local storage = require("storage")

local M = {}

function M.handle()
    -- Extract token from URI: /share/<token>
    local token = ngx.var.uri:match("^/share/([^/?]+)")
    if not token then
        ngx.status = 400
        ngx.header["Content-Type"] = "application/json"
        ngx.print(json.encode({ error = "missing token" }))
        return
    end

    ngx.header["Access-Control-Allow-Origin"]  = "*"
    ngx.header["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    ngx.header["Access-Control-Allow-Headers"] = "Content-Type"

    if ngx.req.get_method() == "OPTIONS" then
        ngx.status = 204
        return
    end

    local row = storage.get_share_by_token(token)
    if not row then
        ngx.status = 404
        ngx.header["Content-Type"] = "application/json"
        ngx.print(json.encode({ error = "not found" }))
        return
    end

    local snapshot = json.decode(row.snapshot_json)
    if not snapshot then
        ngx.status = 500
        ngx.header["Content-Type"] = "application/json"
        ngx.print(json.encode({ error = "invalid snapshot" }))
        return
    end

    ngx.status = 200
    ngx.header["Content-Type"] = "application/json"
    ngx.print(json.encode(snapshot))
end

return M
