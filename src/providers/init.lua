-- providers/init.lua — provider registry
-- Returns the provider module for a given provider name.

local M = {}

local REGISTRY = {
    -- Native adapters
    openai      = "providers.openai",
    anthropic   = "providers.anthropic",
    gemini      = "providers.gemini",
    cohere      = "providers.cohere",
    bedrock     = "providers.bedrock",
    vertex      = "providers.vertex",
    -- OpenAI-compatible (established)
    mistral     = "providers.mistral",
    groq        = "providers.groq",
    together    = "providers.together",
    fireworks   = "providers.fireworks",
    deepseek    = "providers.deepseek",
    xai         = "providers.xai",
    perplexity  = "providers.perplexity",
    openrouter  = "providers.openrouter",
    ollama      = "providers.ollama",
    -- OpenAI-compatible (new)
    azure       = "providers.azure",
    huggingface = "providers.huggingface",
    cerebras    = "providers.cerebras",
    nvidia      = "providers.nvidia",
    cloudflare  = "providers.cloudflare",
    sambanova   = "providers.sambanova",
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
