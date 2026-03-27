-- providers/init.lua — provider registry
-- Returns the provider module for a given provider name.

local M = {}

local REGISTRY = {
    -- Native adapters
    openai      = { module = "providers.openai",      requires_key = true  },
    anthropic   = { module = "providers.anthropic",   requires_key = true  },
    gemini      = { module = "providers.gemini",      requires_key = true  },
    cohere      = { module = "providers.cohere",      requires_key = true  },
    bedrock     = { module = "providers.bedrock",     requires_key = true  },
    vertex      = { module = "providers.vertex",      requires_key = true  },
    -- OpenAI-compatible (established)
    mistral     = { module = "providers.mistral",     requires_key = true  },
    groq        = { module = "providers.groq",        requires_key = true  },
    together    = { module = "providers.together",    requires_key = true  },
    fireworks   = { module = "providers.fireworks",   requires_key = true  },
    deepseek    = { module = "providers.deepseek",    requires_key = true  },
    xai         = { module = "providers.xai",         requires_key = true  },
    perplexity  = { module = "providers.perplexity",  requires_key = true  },
    openrouter  = { module = "providers.openrouter",  requires_key = true  },
    ollama      = { module = "providers.ollama",      requires_key = false },
    vllm        = { module = "providers.vllm",        requires_key = false },
    -- OpenAI-compatible (new)
    azure       = { module = "providers.azure",       requires_key = true  },
    huggingface = { module = "providers.huggingface", requires_key = true  },
    cerebras    = { module = "providers.cerebras",    requires_key = true  },
    nvidia      = { module = "providers.nvidia",      requires_key = true  },
    cloudflare  = { module = "providers.cloudflare",  requires_key = true  },
    sambanova   = { module = "providers.sambanova",   requires_key = true  },
}

-- Returns provider module or nil, err
function M.get(name)
    local entry = REGISTRY[name]
    if not entry then
        return nil, "unknown provider: " .. tostring(name)
    end
    local ok, mod = pcall(require, entry.module)
    if not ok then
        return nil, "load provider " .. entry.module .. ": " .. tostring(mod)
    end
    return mod
end

function M.known(name)
    return REGISTRY[name] ~= nil
end

-- Returns the raw registry entry table (with requires_key etc.) or nil.
function M.registry_entry(name)
    return REGISTRY[name]
end

-- Returns list of { name, requires_key } for all registered providers, sorted by name.
function M.list()
    local result = {}
    for name, entry in pairs(REGISTRY) do
        result[#result + 1] = { name = name, requires_key = entry.requires_key }
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

return M
