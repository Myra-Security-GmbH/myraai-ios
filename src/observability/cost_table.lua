-- observability/cost_table.lua — model pricing lookup with storage fallback
-- Prices are USD per 1,000 tokens.

local storage = require("storage")
local state   = require("state")
local json    = require("utils.json")

local M = {}

-- In-process fallback for when storage is unavailable.
-- Per 1,000 tokens: { input, output, cache_write, cache_read }
-- cache_write/cache_read default to input/0 when absent.
local FALLBACK = {
    openai = {
        ["gpt-4o"]                   = { 0.0025,   0.010   },
        ["gpt-4o-mini"]              = { 0.00015,  0.0006  },
        ["gpt-4-turbo"]              = { 0.010,    0.030   },
        ["gpt-3.5-turbo"]            = { 0.0005,   0.0015  },
    },
    anthropic = {
        -- Claude 4.6 (latest)
        ["claude-opus-4-6"]              = { 0.005,    0.025,   0.00625, 0.0005  },
        ["claude-opus-4-6-20260205"]     = { 0.005,    0.025,   0.00625, 0.0005  },
        ["claude-sonnet-4-6"]            = { 0.003,    0.015,   0.00375, 0.0003  },
        ["claude-haiku-4-5"]             = { 0.001,    0.005,   0.00125, 0.0001  },
        ["claude-haiku-4-5-20251001"]    = { 0.001,    0.005,   0.00125, 0.0001  },
        -- Claude 4.5
        ["claude-opus-4-5"]              = { 0.005,    0.025,   0.00625, 0.0005  },
        ["claude-opus-4-5-20251101"]     = { 0.005,    0.025,   0.00625, 0.0005  },
        ["claude-sonnet-4-5"]            = { 0.003,    0.015,   0.00375, 0.0003  },
        ["claude-sonnet-4-5-20250929"]   = { 0.003,    0.015,   0.00375, 0.0003  },
        -- Claude 4.1 / 4.0 (legacy)
        ["claude-opus-4-1"]              = { 0.015,    0.075,   0.01875, 0.0015  },
        ["claude-opus-4-1-20250805"]     = { 0.015,    0.075,   0.01875, 0.0015  },
        ["claude-opus-4-0"]              = { 0.015,    0.075,   0.01875, 0.0015  },
        ["claude-opus-4-20250514"]       = { 0.015,    0.075,   0.01875, 0.0015  },
        ["claude-sonnet-4-0"]            = { 0.003,    0.015,   0.00375, 0.0003  },
        ["claude-sonnet-4-20250514"]     = { 0.003,    0.015,   0.00375, 0.0003  },
        -- Claude 3.x (legacy/deprecated)
        ["claude-3-7-sonnet-20250219"]   = { 0.003,    0.015,   0.00375, 0.0003  },
        ["claude-3-haiku-20240307"]      = { 0.00025,  0.00125, 0.0003,  0.00003 },
    },
    gemini = {
        ["gemini-1.5-pro"]           = { 0.00125,  0.005   },
        ["gemini-1.5-flash"]         = { 0.000075, 0.0003  },
        ["gemini-2.0-flash"]         = { 0.0001,   0.0004  },
    },
    -- Vertex AI uses same models as Gemini — prices are identical
    vertex = {
        ["gemini-1.5-pro"]           = { 0.00125,  0.005   },
        ["gemini-1.5-flash"]         = { 0.000075, 0.0003  },
        ["gemini-2.0-flash"]         = { 0.0001,   0.0004  },
    },
    cohere = {
        ["command-r-plus"]           = { 0.003,    0.015   },
        ["command-r"]                = { 0.00015,  0.0006  },
        ["command-a-03-2025"]        = { 0.0025,   0.010   },
    },
    mistral = {
        ["mistral-large-latest"]     = { 0.002,    0.006   },
        ["mistral-small-latest"]     = { 0.0002,   0.0006  },
        ["codestral-latest"]         = { 0.0003,   0.0009  },
    },
    groq = {
        ["llama-3.3-70b-versatile"]  = { 0.00059,  0.00079 },
        ["llama-3.1-8b-instant"]     = { 0.00005,  0.00008 },
        ["mixtral-8x7b-32768"]       = { 0.00024,  0.00024 },
    },
    together = {
        ["meta-llama/Llama-3.3-70B-Instruct-Turbo"] = { 0.00088, 0.00088 },
        ["meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo"] = { 0.00018, 0.00018 },
        ["deepseek-ai/DeepSeek-V3"]  = { 0.00135,  0.00135 },
    },
    fireworks = {
        ["accounts/fireworks/models/llama-v3p3-70b-instruct"] = { 0.0009,  0.0009  },
        ["accounts/fireworks/models/llama-v3p1-8b-instruct"]  = { 0.0002,  0.0002  },
        ["accounts/fireworks/models/deepseek-v3"]             = { 0.0009,  0.0009  },
    },
    deepseek = {
        ["deepseek-chat"]            = { 0.00027,  0.0011  },
        ["deepseek-reasoner"]        = { 0.00055,  0.00219 },
    },
    xai = {
        ["grok-3"]                   = { 0.003,    0.015   },
        ["grok-3-mini"]              = { 0.0003,   0.0005  },
        ["grok-2-1212"]              = { 0.002,    0.010   },
    },
    perplexity = {
        ["sonar-pro"]                = { 0.003,    0.015   },
        ["sonar"]                    = { 0.001,    0.001   },
        ["sonar-reasoning-pro"]      = { 0.002,    0.008   },
    },
    openrouter = {
        -- OpenRouter passes through to underlying providers; prices vary.
        -- Actual costs should be retrieved from OpenRouter API; nil means unknown.
    },
    ollama = {
        -- Ollama runs locally; no token cost.
    },
    azure = {
        -- Azure OpenAI: same models/prices as OpenAI, keyed by deployment name.
        ["gpt-4o"]                   = { 0.0025,   0.010   },
        ["gpt-4o-mini"]              = { 0.00015,  0.0006  },
        ["gpt-4-turbo"]              = { 0.010,    0.030   },
        ["gpt-3.5-turbo"]            = { 0.0005,   0.0015  },
    },
    huggingface = {
        -- HuggingFace serverless inference — most models are free or pay-per-token.
        -- Dedicated endpoints have custom pricing set via DB.
    },
    cerebras = {
        ["llama3.1-8b"]              = { 0.0001,   0.0001  },
        ["llama3.3-70b"]             = { 0.0006,   0.0006  },
    },
    nvidia = {
        ["meta/llama-3.3-70b-instruct"]              = { 0.00049, 0.00049 },
        ["meta/llama-3.1-8b-instruct"]               = { 0.00010, 0.00010 },
        ["nvidia/llama-3.1-nemotron-70b-instruct"]   = { 0.00035, 0.00035 },
    },
    cloudflare = {
        -- Cloudflare Workers AI: free tier for most models; no per-token price.
    },
    sambanova = {
        ["Meta-Llama-3.3-70B-Instruct"] = { 0.0006,  0.0006  },
        ["Meta-Llama-3.1-8B-Instruct"]  = { 0.00010, 0.00010 },
        ["DeepSeek-R1"]                 = { 0.0005,  0.0015  },
    },
    -- AWS Bedrock: prices vary by model family and region.
    -- These are us-east-1 on-demand prices.
    bedrock = {
        ["anthropic.claude-3-5-sonnet-20241022-v2:0"] = { 0.003,   0.015,  0.00375, 0.0003  },
        ["anthropic.claude-3-5-haiku-20241022-v1:0"]  = { 0.0008,  0.004,  0.001,   0.00008 },
        ["anthropic.claude-3-opus-20240229-v1:0"]     = { 0.015,   0.075,  0.01875, 0.0015  },
        ["meta.llama3-3-70b-instruct-v1:0"]           = { 0.00072, 0.00072 },
        ["meta.llama3-1-8b-instruct-v1:0"]            = { 0.00022, 0.00022 },
        ["amazon.nova-pro-v1:0"]                      = { 0.0008,  0.0032  },
        ["amazon.nova-lite-v1:0"]                     = { 0.00006, 0.00024 },
        ["amazon.nova-micro-v1:0"]                    = { 0.000035,0.00014 },
        ["mistral.mistral-large-2402-v1:0"]           = { 0.004,   0.012   },
    },
}

-- Returns { input_per_1k, output_per_1k } or nil
function M.get(provider, model)
    local key    = "price:" .. provider .. ":" .. model
    local cached = state.config_get(key)
    if cached then
        return json.decode(cached)
    end

    local row = storage.get_model_pricing(provider, model)
    if row then
        local pricing = {
            input_per_1k        = tonumber(row.input_per_1k),
            output_per_1k       = tonumber(row.output_per_1k),
            cache_write_per_1k  = tonumber(row.cache_write_per_1k),
            cache_read_per_1k   = tonumber(row.cache_read_per_1k),
            cache_delete_per_1k = tonumber(row.cache_delete_per_1k),
        }
        state.config_set(key, json.encode(pricing), 3600)
        return pricing
    end

    -- Try fallback table
    local fb_provider = FALLBACK[provider]
    if fb_provider and fb_provider[model] then
        local p = fb_provider[model]
        return {
            input_per_1k        = p[1],
            output_per_1k       = p[2],
            cache_write_per_1k  = p[3] or p[1],
            cache_read_per_1k   = p[4] or 0,
            cache_delete_per_1k = p[5] or 0,
        }
    end

    return nil
end

-- Calculate cost in USD given token counts.
-- Returns nil when pricing is unknown (distinguishes "free" from "untracked").
-- cache_creation, cache_read, and cache_deletion are optional (Anthropic prompt-caching tokens).
function M.calculate(provider, model, input_tokens, output_tokens,
                     cache_creation_tokens, cache_read_tokens, cache_deletion_tokens)
    local pricing = M.get(provider, model)
    if not pricing then return nil end
    return (input_tokens          / 1000 * pricing.input_per_1k)
         + (output_tokens         / 1000 * pricing.output_per_1k)
         + ((cache_creation_tokens or 0) / 1000 * (pricing.cache_write_per_1k or pricing.input_per_1k))
         + ((cache_read_tokens     or 0) / 1000 * (pricing.cache_read_per_1k  or 0))
         + ((cache_deletion_tokens or 0) / 1000 * (pricing.cache_delete_per_1k or 0))
end

return M
