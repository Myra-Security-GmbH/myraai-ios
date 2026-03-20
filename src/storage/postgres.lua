-- storage/postgres.lua — Postgres backend (production swap for sqlite.lua)
-- Exposes the same interface as storage/sqlite.lua.
-- Stub: implement when switching storage = "postgres" in config.

local M = {}

local function not_impl(name)
    return function()
        error("storage/postgres: " .. name .. " not yet implemented")
    end
end

M.init                = not_impl("init")
M.get_gateway         = not_impl("get_gateway")
M.get_provider_key    = not_impl("get_provider_key")
M.get_auth_token      = not_impl("get_auth_token")
M.get_routing_rules   = not_impl("get_routing_rules")
M.get_model_pricing   = not_impl("get_model_pricing")
M.insert_log          = not_impl("insert_log")
M.upsert_tenant       = not_impl("upsert_tenant")
M.upsert_gateway      = not_impl("upsert_gateway")
M.upsert_provider_config = not_impl("upsert_provider_config")
M.insert_auth_token   = not_impl("insert_auth_token")

return M
