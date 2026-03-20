-- providers/init.lua — provider registry
-- Returns the provider module for a given provider name.

local M = {}

local REGISTRY = {
    openai    = "providers.openai",
    anthropic = "providers.anthropic",
    gemini    = "providers.gemini",
    mistral   = "providers.mistral",
    groq      = "providers.groq",
    -- extend here as more providers are implemented
}

-- Returns provider module or nil, err
function M.get(name)
    local mod_name = REGISTRY[name]
    if not mod_name then
        return nil, "unknown provider: " .. tostring(name)
    end
    local ok, mod = pcall(require, mod_name)
    if not ok then
        return nil, "load provider " .. mod_name .. ": " .. tostring(mod)
    end
    return mod
end

function M.known(name)
    return REGISTRY[name] ~= nil
end

return M
