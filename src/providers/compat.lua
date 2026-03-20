-- providers/compat.lua — OpenAI-compatible unified endpoint normaliser
-- Maps /compat/{path} to the gateway's configured default provider.
-- The request body stays in OpenAI format; provider adapters translate it.
--
-- Supported compat paths:
--   /chat/completions
--   /completions
--   /embeddings

local M = {}

-- Model prefix → provider mapping (override with routing rules)
local MODEL_PREFIX_MAP = {
    ["gpt"]          = "openai",
    ["o1"]           = "openai",
    ["o3"]           = "openai",
    ["claude"]       = "anthropic",
    ["gemini"]       = "gemini",
    ["mistral"]      = "mistral",
    ["mixtral"]      = "mistral",
    ["llama"]        = "groq",
    ["deepseek"]     = "deepseek",
    ["grok"]         = "xai",
}

-- Infer provider from model name prefix.
-- Returns provider name or nil.
function M.infer_provider(model)
    if not model then return nil end
    local lower = model:lower()
    for prefix, provider in pairs(MODEL_PREFIX_MAP) do
        if lower:sub(1, #prefix) == prefix then
            return provider
        end
    end
    return nil
end

-- Normalise compat path to provider_path.
-- /compat/chat/completions → /v1/chat/completions (for OpenAI)
-- Other providers handle the path mapping in their base_url().
function M.provider_path(compat_path)
    local path = compat_path:gsub("^/compat", "")
    return "/v1" .. path
end

return M
