-- storage/init.lua — selects backend based on config.storage
-- Usage:  local storage = require("storage")
--         storage.get_gateway("acme", "main")

local cfg = require("core.app_config")

if cfg.storage == "sqlite" then
    return require("storage.sqlite")
elseif cfg.storage == "postgres" then
    return require("storage.postgres")
elseif cfg.storage == "mysql" then
    return require("storage.mysql")
else
    error("storage/init: unknown backend '" .. tostring(cfg.storage) .. "'")
end
