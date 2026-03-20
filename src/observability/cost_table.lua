-- observability/cost_table.lua — model pricing lookup with storage fallback
-- Prices are USD per 1,000 tokens.

local storage = require("storage")
local state   = require("state")
local json    = require("utils.json")

local M = {}

-- In-process fallback for when storage is unavailable
local FALLBACK = {
    openai    = { ["gpt-4o"] = {0.0025, 0.010}, ["gpt-4o-mini"] = {0.00015, 0.0006} },
    anthropic = { ["claude-sonnet-4-6"] = {0.003, 0.015} },
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
        local pricing = { input_per_1k = row.input_per_1k, output_per_1k = row.output_per_1k }
        state.config_set(key, json.encode(pricing), 3600)  -- price rarely changes
        return pricing
    end

    -- Try fallback table
    local fb_provider = FALLBACK[provider]
    if fb_provider and fb_provider[model] then
        local p = fb_provider[model]
        return { input_per_1k = p[1], output_per_1k = p[2] }
    end

    return nil
end

-- Calculate cost in USD given token counts
function M.calculate(provider, model, input_tokens, output_tokens)
    local pricing = M.get(provider, model)
    if not pricing then return 0 end
    return (input_tokens  / 1000 * pricing.input_per_1k)
         + (output_tokens / 1000 * pricing.output_per_1k)
end

return M
