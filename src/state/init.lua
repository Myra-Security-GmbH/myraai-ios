-- state/init.lua — selects backend based on config.state
-- Usage:  local state = require("state")
--         state.cache_get("some-key")

local cfg = require("core.app_config")

if cfg.state == "shared_dict" then
    return require("state.shared_dict")
elseif cfg.state == "redis" then
    return require("state.redis")
else
    error("state/init: unknown backend '" .. tostring(cfg.state) .. "'")
end
