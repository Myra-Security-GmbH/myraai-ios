-- core/config.lua — per-request gateway config loader
-- Fetches tenant+gateway config from storage, caches in state backend.

local storage = require("storage")
local state   = require("state")
local json    = require("utils.json")
local cfg     = require("core.app_config")

local CACHE_TTL = cfg.defaults.config_cache_ttl

local M = {}

-- Called from init_worker_by_lua_block to open DB handles.
function M.init()
    storage.init(cfg)
end

-- Returns merged gateway config table for (tenant_slug, gateway_slug).
-- Uses state backend as hot cache, falls back to storage on miss.
-- Returns config table on success, or calls errors.send() on failure.
function M.get_gateway(tenant_slug, gateway_slug)
    local cache_key = "gwcfg:" .. tenant_slug .. ":" .. gateway_slug

    local cached = state.config_get(cache_key)
    if cached then
        return json.decode(cached)
    end

    local config, err = storage.get_gateway(tenant_slug, gateway_slug)
    if not config then
        if err == "not_found" then
            require("core.errors").send("TENANT_NOT_FOUND")
        else
            ngx.log(ngx.ERR, "config.get_gateway storage error: ", err)
            require("core.errors").send("INTERNAL")
        end
        return nil
    end

    -- Apply defaults for any unset fields
    config.cache_ttl    = config.cache_ttl    or cfg.defaults.cache_ttl
    config.retry_count  = config.retry_count  or cfg.defaults.retry_count
    config.timeout_ms   = config.timeout_ms   or cfg.defaults.timeout_ms
    config.log_payloads = (config.log_payloads ~= false)

    state.config_set(cache_key, json.encode(config), CACHE_TTL)
    return config
end

return M
