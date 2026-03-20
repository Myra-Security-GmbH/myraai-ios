-- core/app_config.lua — loads config/gateway.lua once and caches it.
-- All other modules do:  local cfg = require("core.app_config")

local CONFIG_PATH = os.getenv("AIG_CONFIG") or "/opt/ai-gateway/config/gateway.lua"

local ok, cfg = pcall(dofile, CONFIG_PATH)
if not ok then
    error("Failed to load AI Gateway config from " .. CONFIG_PATH .. ": " .. tostring(cfg))
end

return cfg
