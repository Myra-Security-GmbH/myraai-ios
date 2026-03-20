-- middleware/request_id.lua — inject a unique request ID into context and headers
local uuid = require("utils.uuid")

local M = {}

function M.run(ctx)
    local id = ngx.var.http_x_request_id
    if not id or id == "" then
        id = uuid.v4()
    end
    ctx.request_id = id
    ngx.req.set_header("X-Request-Id", id)
    ngx.header["X-Request-Id"] = id
end

return M
