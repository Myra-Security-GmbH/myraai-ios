-- middleware/byok.lua — inject the decrypted provider API key into ctx
-- Reads x-aig-byok-alias header to select a non-default key alias.

local byok_vault = require("auth.byok")
local errors     = require("core.errors")

local M = {}

function M.run(ctx)
    local alias = ngx.var.http_x_aig_byok_alias or "default"

    local key, err = byok_vault.get_key(ctx.gateway_id, ctx.provider, alias)
    if not key then
        ngx.log(ngx.ERR, "byok: ", err, " provider=", ctx.provider,
                " gateway=", ctx.gateway_id)
        errors.send("INTERNAL", "Provider API key unavailable")
    end

    ctx.provider_api_key = key
end

return M
