-- providers/compat.lua — OpenAI-compatible unified endpoint normaliser
-- Maps /compat/{path} to the gateway's configured default provider.
-- The request body stays in OpenAI format; provider adapters translate it.
--
-- Supported compat paths:
--   /chat/completions
--   /completions
--   /embeddings

local M = {}

-- Exact model-id → provider mapping checked before prefix heuristics.
-- Use this for models where the name is fully unambiguous, or where a prefix
-- would route to the wrong provider.
local MODEL_EXACT_MAP = {
    -- OpenAI
    ["gpt-4o"]                                          = "openai",
    ["gpt-4o-mini"]                                     = "openai",
    ["gpt-4-turbo"]                                     = "openai",
    ["gpt-3.5-turbo"]                                   = "openai",
    ["o1"]                                              = "openai",
    ["o1-mini"]                                         = "openai",
    ["o3-mini"]                                         = "openai",
    -- Anthropic
    ["claude-opus-4-6"]                                 = "anthropic",
    ["claude-sonnet-4-6"]                               = "anthropic",
    ["claude-haiku-4-5"]                                = "anthropic",
    ["claude-3-5-sonnet-20241022"]                      = "anthropic",
    ["claude-3-5-haiku-20241022"]                       = "anthropic",
    ["claude-3-opus-20240229"]                          = "anthropic",
    -- Gemini
    ["gemini-2.0-flash"]                                = "gemini",
    ["gemini-2.0-flash-lite"]                           = "gemini",
    ["gemini-1.5-pro"]                                  = "gemini",
    ["gemini-1.5-flash"]                                = "gemini",
    -- Mistral
    ["mistral-large-latest"]                            = "mistral",
    ["mistral-small-latest"]                            = "mistral",
    ["codestral-latest"]                                = "mistral",
    ["mistral-embed"]                                   = "mistral",
    -- Cohere
    ["command-r-plus"]                                  = "cohere",
    ["command-r"]                                       = "cohere",
    ["command-a-03-2025"]                               = "cohere",
    -- Groq (models served exclusively on Groq)
    ["llama-3.3-70b-versatile"]                         = "groq",
    ["llama-3.1-8b-instant"]                            = "groq",
    ["mixtral-8x7b-32768"]                              = "groq",
    ["gemma2-9b-it"]                                    = "groq",
    -- DeepSeek
    ["deepseek-chat"]                                   = "deepseek",
    ["deepseek-reasoner"]                               = "deepseek",
    -- xAI
    ["grok-3"]                                          = "xai",
    ["grok-3-mini"]                                     = "xai",
    ["grok-2-1212"]                                     = "xai",
    -- Perplexity
    ["sonar-pro"]                                       = "perplexity",
    ["sonar"]                                           = "perplexity",
    ["sonar-reasoning-pro"]                             = "perplexity",
    ["r1-1776"]                                         = "perplexity",
    -- Together AI (namespaced model IDs)
    ["meta-llama/Llama-3.3-70B-Instruct-Turbo"]        = "together",
    ["meta-llama/Meta-Llama-3.1-8B-Instruct-Turbo"]    = "together",
    ["deepseek-ai/DeepSeek-V3"]                         = "together",
    ["Qwen/Qwen2.5-72B-Instruct-Turbo"]                 = "together",
    -- Fireworks AI (namespaced model IDs)
    ["accounts/fireworks/models/llama-v3p3-70b-instruct"]   = "fireworks",
    ["accounts/fireworks/models/llama-v3p1-8b-instruct"]    = "fireworks",
    ["accounts/fireworks/models/deepseek-v3"]               = "fireworks",
    ["accounts/fireworks/models/qwen2p5-72b-instruct"]      = "fireworks",
    -- Cerebras
    ["llama3.1-8b"]                                     = "cerebras",
    ["llama3.3-70b"]                                    = "cerebras",
    -- NVIDIA NIM
    ["meta/llama-3.3-70b-instruct"]                     = "nvidia",
    ["meta/llama-3.1-8b-instruct"]                      = "nvidia",
    ["nvidia/llama-3.1-nemotron-70b-instruct"]          = "nvidia",
    -- SambaNova
    ["Meta-Llama-3.3-70B-Instruct"]                     = "sambanova",
    ["Meta-Llama-3.1-8B-Instruct"]                      = "sambanova",
    ["DeepSeek-R1"]                                     = "sambanova",
    -- vLLM local models
    ["qwen3-235b"]                                      = "vllm",
    ["qwen3.6-35b-a3b"]                                 = "vllm",
}

-- Model prefix → provider mapping (fallback when exact match fails).
-- Longer/more-specific prefixes must come before shorter ones that share a prefix.
local MODEL_PREFIX_MAP = {
    -- OpenAI
    ["gpt"]                  = "openai",
    ["o1"]                   = "openai",
    ["o3"]                   = "openai",
    ["o4"]                   = "openai",
    -- Anthropic
    ["claude"]               = "anthropic",
    -- Google
    ["gemini"]               = "gemini",
    -- Cohere
    ["command"]              = "cohere",
    ["embed-"]               = "cohere",
    -- AWS Bedrock (model IDs contain a dot, e.g. "anthropic.claude-3-5-sonnet")
    ["anthropic."]           = "bedrock",
    ["meta."]                = "bedrock",
    ["amazon."]              = "bedrock",
    ["mistral."]             = "bedrock",
    ["cohere."]              = "bedrock",
    ["ai21."]                = "bedrock",
    ["stability."]           = "bedrock",
    -- OpenAI-compatible providers
    ["mistral"]              = "mistral",
    ["mixtral"]              = "mistral",
    ["codestral"]            = "mistral",
    ["groq/"]                = "groq",
    ["deepseek"]             = "deepseek",
    ["grok"]                 = "xai",
    ["sonar"]                = "perplexity",
    ["r1-1776"]              = "perplexity",
    -- Namespaced model IDs for multi-model providers
    ["meta-llama/"]          = "together",
    ["deepseek-ai/"]         = "together",
    ["Qwen/"]                = "together",
    ["accounts/fireworks/"]  = "fireworks",
    ["meta/"]                = "nvidia",
    ["nvidia/"]              = "nvidia",
    -- Ollama local models use ollama/ prefix
    ["ollama/"]              = "ollama",
    -- vLLM local models use vllm/ prefix
    ["vllm/"]                = "vllm",
    -- Cloudflare models use @cf/ prefix
    ["@cf/"]                 = "cloudflare",
    -- HuggingFace hosted inference — org/model format.
    -- Only org prefixes that don't conflict with Together AI's catalog.
    -- (meta-llama/ already routes to Together above.)
    ["sentence-transformers/"] = "huggingface",
    ["HuggingFaceH4/"]       = "huggingface",
    ["tiiuae/"]              = "huggingface",
    ["bigcode/"]             = "huggingface",
    ["EleutherAI/"]          = "huggingface",
    ["microsoft/"]           = "huggingface",
    ["google/"]              = "huggingface",   -- HF-hosted Google models (not Gemini)
    ["stabilityai/"]         = "huggingface",
    ["mistralai/"]           = "huggingface",   -- HF direct; Together uses full namespaced form
}

-- Sorted prefix list: longest prefix first so more-specific entries win.
-- Built once at module load time from MODEL_PREFIX_MAP.
local SORTED_PREFIXES = (function()
    local t = {}
    for prefix, provider in pairs(MODEL_PREFIX_MAP) do
        t[#t + 1] = { prefix = prefix, lower = prefix:lower(), provider = provider }
    end
    table.sort(t, function(a, b) return #a.prefix > #b.prefix end)
    return t
end)()

-- Infer provider from model name using three-tier resolution:
--   1. Exact match  — MODEL_EXACT_MAP (case-sensitive)
--   2. Prefix match — MODEL_PREFIX_MAP (longest prefix wins, case-insensitive)
--   3. OpenRouter   — universal fallback; aggregates 300+ models from 30+ providers.
--                     Requires an OpenRouter BYOK key on the gateway.
-- Returns a provider name string (never nil).
function M.infer_provider(model)
    if not model or model == "" then return "openrouter" end

    -- 1. Exact match (case-sensitive — model IDs are case-sensitive)
    if MODEL_EXACT_MAP[model] then
        return MODEL_EXACT_MAP[model]
    end

    -- 2. Prefix heuristics — longest prefix wins (case-insensitive comparison)
    local lower = model:lower()
    for _, entry in ipairs(SORTED_PREFIXES) do
        if lower:sub(1, #entry.prefix) == entry.lower then
            return entry.provider
        end
    end

    -- 3. Universal fallback: route through OpenRouter which aggregates 300+ models.
    return "openrouter"
end

-- Normalise compat path to provider_path.
-- /compat/chat/completions → /v1/chat/completions (for OpenAI)
-- Other providers handle the path mapping in their base_url().
function M.provider_path(compat_path)
    local path = compat_path:gsub("^/compat", "")
    return "/v1" .. path
end

return M
