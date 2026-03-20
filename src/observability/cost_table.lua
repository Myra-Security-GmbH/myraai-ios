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
        ["gpt-4o"]      = { 0.0025,   0.010  },
        ["gpt-4o-mini"] = { 0.00015,  0.0006 },
    },
    anthropic = {
        ["claude-opus-4-6"]              = { 0.015,    0.075,   0.01875, 0.0015  },
        ["claude-sonnet-4-6"]            = { 0.003,    0.015,   0.00375, 0.0003  },
        ["claude-haiku-4-5-20251001"]    = { 0.0008,   0.004,   0.001,   0.00008 },
        ["claude-haiku-4-5"]             = { 0.0008,   0.004,   0.001,   0.00008 },
        ["claude-3-5-sonnet-20241022"]   = { 0.003,    0.015,   0.00375, 0.0003  },
        ["claude-3-5-haiku-20241022"]    = { 0.0008,   0.004,   0.001,   0.00008 },
        ["claude-3-opus-20240229"]       = { 0.015,    0.075,   0.01875, 0.0015  },
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
            input_per_1k       = tonumber(row.input_per_1k),
            output_per_1k      = tonumber(row.output_per_1k),
            cache_write_per_1k = tonumber(row.cache_write_per_1k),
            cache_read_per_1k  = tonumber(row.cache_read_per_1k),
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
        }
    end

    return nil
end

-- Calculate cost in USD given token counts.
-- cache_creation and cache_read are optional (Anthropic prompt-caching tokens).
function M.calculate(provider, model, input_tokens, output_tokens,
                     cache_creation_tokens, cache_read_tokens)
    local pricing = M.get(provider, model)
    if not pricing then return 0 end
    return (input_tokens          / 1000 * pricing.input_per_1k)
         + (output_tokens         / 1000 * pricing.output_per_1k)
         + ((cache_creation_tokens or 0) / 1000 * (pricing.cache_write_per_1k or pricing.input_per_1k))
         + ((cache_read_tokens     or 0) / 1000 * (pricing.cache_read_per_1k  or 0))
end

return M
