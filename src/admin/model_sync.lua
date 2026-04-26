-- admin/model_sync.lua — Automatic model list updater
--
-- Fetches model lists from provider APIs and upserts into model_price
-- with pricing inferred from model family patterns.
--
-- Runs daily via ngx.timer (started from init_worker on worker 0).
-- Also callable via POST /admin/v1/model-prices/sync.

local storage = require("storage")
local crypto  = require("utils.crypto")
local cfg     = require("core.app_config")
local cjson   = require("cjson.safe")

local M = {}

-- ---------------------------------------------------------------------------
-- Provider models-endpoint registry
-- ---------------------------------------------------------------------------
local PROVIDERS = {
    anthropic  = { url = "https://api.anthropic.com/v1/models",            auth = "anthropic" },
    openai     = { url = "https://api.openai.com/v1/models",              auth = "bearer" },
    mistral    = { url = "https://api.mistral.ai/v1/models",              auth = "bearer" },
    groq       = { url = "https://api.groq.com/openai/v1/models",         auth = "bearer" },
    deepseek   = { url = "https://api.deepseek.com/v1/models",            auth = "bearer" },
    xai        = { url = "https://api.x.ai/v1/models",                    auth = "bearer" },
    together   = { url = "https://api.together.xyz/v1/models",            auth = "bearer" },
    fireworks  = { url = "https://api.fireworks.ai/inference/v1/models",   auth = "bearer" },
    perplexity = { url = "https://api.perplexity.ai/v1/models",           auth = "bearer" },
    openrouter = { url = "https://openrouter.ai/api/v1/models",           auth = "bearer" },
}

-- Stable iteration order
local PROVIDER_ORDER = {
    "anthropic", "openai", "mistral", "groq", "deepseek",
    "xai", "together", "fireworks", "perplexity", "openrouter",
}

-- ---------------------------------------------------------------------------
-- Pricing tiers — first match wins (check more specific patterns first)
-- i = input_per_1k, o = output_per_1k, cw = cache_write_per_1k (5m), cr = cache_read_per_1k, cw1h = cache_write_1h_per_1k
-- ---------------------------------------------------------------------------
local PRICING_TIERS = {
    -- ── Anthropic ────────────────────────────────────────────────────────────
    { p = "anthropic", pat = "^claude%-opus%-4%-[56]",             i = 0.005,   o = 0.025,   cw = 0.00625,  cr = 0.0005,  cw1h = 0.01     },
    { p = "anthropic", pat = "^claude%-opus%-4",                   i = 0.015,   o = 0.075,   cw = 0.01875,  cr = 0.0015,  cw1h = 0.03     },
    { p = "anthropic", pat = "^claude%-4%-opus",                   i = 0.015,   o = 0.075,   cw = 0.01875,  cr = 0.0015,  cw1h = 0.03     },
    { p = "anthropic", pat = "^claude%-sonnet%-4",                 i = 0.003,   o = 0.015,   cw = 0.00375,  cr = 0.0003,  cw1h = 0.006    },
    { p = "anthropic", pat = "^claude%-4%-sonnet",                 i = 0.003,   o = 0.015,   cw = 0.00375,  cr = 0.0003,  cw1h = 0.006    },
    { p = "anthropic", pat = "^claude%-haiku%-4",                  i = 0.001,   o = 0.005,   cw = 0.00125,  cr = 0.0001,  cw1h = 0.002    },
    { p = "anthropic", pat = "^claude%-3%-7%-sonnet",              i = 0.003,   o = 0.015,   cw = 0.00375,  cr = 0.0003,  cw1h = 0.006    },
    { p = "anthropic", pat = "^claude%-3%-5%-sonnet",              i = 0.003,   o = 0.015,   cw = 0.00375,  cr = 0.0003,  cw1h = 0.006    },
    { p = "anthropic", pat = "^claude%-3%-5%-haiku",               i = 0.0008,  o = 0.004,   cw = 0.001,    cr = 0.00008, cw1h = 0.0016   },
    { p = "anthropic", pat = "^claude%-3%-opus",                   i = 0.015,   o = 0.075,   cw = 0.01875,  cr = 0.0015,  cw1h = 0.03     },
    { p = "anthropic", pat = "^claude%-3%-sonnet",                 i = 0.003,   o = 0.015,   cw = 0.00375,  cr = 0.0003,  cw1h = 0.006    },
    { p = "anthropic", pat = "^claude%-3%-haiku",                  i = 0.00025, o = 0.00125, cw = 0.0003,   cr = 0.00003, cw1h = 0.00048  },

    -- ── OpenAI ───────────────────────────────────────────────────────────────
    { p = "openai", pat = "^gpt%-4%.1%-mini",    i = 0.0004,  o = 0.0016 },
    { p = "openai", pat = "^gpt%-4%.1%-nano",    i = 0.0001,  o = 0.0004 },
    { p = "openai", pat = "^gpt%-4%.1",          i = 0.002,   o = 0.008 },
    { p = "openai", pat = "^gpt%-4o%-mini",      i = 0.00015, o = 0.0006 },
    { p = "openai", pat = "^gpt%-4o",            i = 0.0025,  o = 0.01 },
    { p = "openai", pat = "^o4%-mini",           i = 0.0011,  o = 0.0044 },
    { p = "openai", pat = "^o3%-mini",           i = 0.0011,  o = 0.0044 },
    { p = "openai", pat = "^o3%-pro",            i = 0.02,    o = 0.08 },
    { p = "openai", pat = "^o3",                 i = 0.01,    o = 0.04 },
    { p = "openai", pat = "^o1%-mini",           i = 0.0011,  o = 0.0044 },
    { p = "openai", pat = "^o1%-pro",            i = 0.02,    o = 0.08 },
    { p = "openai", pat = "^o1",                 i = 0.015,   o = 0.06 },

    -- ── Mistral ──────────────────────────────────────────────────────────────
    { p = "mistral", pat = "^mistral%-large",    i = 0.002,   o = 0.006 },
    { p = "mistral", pat = "^mistral%-medium",   i = 0.0004,  o = 0.002 },
    { p = "mistral", pat = "^mistral%-small",    i = 0.0001,  o = 0.0003 },
    { p = "mistral", pat = "^pixtral%-large",    i = 0.002,   o = 0.006 },
    { p = "mistral", pat = "^pixtral",           i = 0.0001,  o = 0.0003 },
    { p = "mistral", pat = "^codestral",         i = 0.0003,  o = 0.0009 },
    { p = "mistral", pat = "^ministral",         i = 0.00004, o = 0.00004 },

    -- ── DeepSeek ─────────────────────────────────────────────────────────────
    { p = "deepseek", pat = "^deepseek%-chat",       i = 0.00027, o = 0.0011 },
    { p = "deepseek", pat = "^deepseek%-reasoner",   i = 0.00055, o = 0.0022 },

    -- ── Groq ─────────────────────────────────────────────────────────────────
    { p = "groq", pat = "^llama%-3%.3%-70b",     i = 0.00059, o = 0.00079 },
    { p = "groq", pat = "^llama%-3%.1%-8b",      i = 0.00005, o = 0.00008 },
    { p = "groq", pat = "^llama%-3%.1%-70b",     i = 0.00059, o = 0.00079 },
    { p = "groq", pat = "^gemma2%-9b",           i = 0.0002,  o = 0.0002 },
    { p = "groq", pat = "^mistral%-saba",        i = 0.0002,  o = 0.0006 },

    -- ── xAI ──────────────────────────────────────────────────────────────────
    { p = "xai", pat = "^grok%-3%-mini",  i = 0.0003, o = 0.0005 },
    { p = "xai", pat = "^grok%-3",        i = 0.003,  o = 0.015 },
    { p = "xai", pat = "^grok%-2",        i = 0.002,  o = 0.01 },
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Get a decrypted API key for a provider (first available across gateways).
function M.get_api_key(provider)
    local gw_id, enc_key, _, key_err = storage.get_first_provider_key(provider)
    if not gw_id then
        return nil, "no key configured for " .. provider .. ": " .. tostring(key_err)
    end
    local plaintext, dec_err = crypto.decrypt(enc_key, cfg.master_key)
    if not plaintext then
        return nil, "decrypt failed for " .. provider .. ": " .. tostring(dec_err)
    end
    return plaintext
end

--- Fetch model list from a provider's API.
--- Returns array of model ID strings, or nil + error.
function M.fetch_models(provider, api_key)
    local spec = PROVIDERS[provider]
    if not spec then return nil, "unknown provider: " .. provider end

    local headers = { ["Accept"] = "application/json" }
    if spec.auth == "anthropic" then
        headers["x-api-key"] = api_key
        headers["anthropic-version"] = "2023-06-01"
    else
        headers["Authorization"] = "Bearer " .. api_key
    end

    local httpc = require("resty.http").new()
    httpc:set_timeout(15000)
    local res, err = httpc:request_uri(spec.url, {
        method     = "GET",
        headers    = headers,
        ssl_verify = true,
    })
    if not res then return nil, "HTTP error: " .. tostring(err) end
    if res.status >= 400 then
        return nil, "HTTP " .. res.status .. ": " .. (res.body or ""):sub(1, 200)
    end

    local body = cjson.decode(res.body)
    if not body or not body.data then
        return nil, "unexpected response format"
    end

    local models = {}
    for _, m in ipairs(body.data) do
        local id = m.id
        if id and type(id) == "string" then
            -- Filter out OpenAI fine-tuned models and system models
            local dominated_by = m.owned_by or ""
            if provider ~= "openai" or (dominated_by == "openai" or dominated_by == "system" or dominated_by == "") then
                models[#models + 1] = id
            end
        end
    end
    return models
end

--- Match a model ID against pricing tiers for a provider.
--- Returns { input, output, cache_write, cache_read, cache_write_1h } or nil.
function M.infer_pricing(provider, model_id)
    for _, tier in ipairs(PRICING_TIERS) do
        if tier.p == provider and model_id:find(tier.pat) then
            return {
                input          = tier.i,
                output         = tier.o,
                cache_write    = tier.cw,
                cache_read     = tier.cr,
                cache_write_1h = tier.cw1h,
            }
        end
    end
    return nil
end

--- Sync one provider: fetch models → infer pricing → upsert new ones.
function M.sync_provider(provider)
    local result = { provider = provider, added = 0, updated = 0, skipped = 0, errors = {} }

    local api_key, key_err = M.get_api_key(provider)
    if not api_key then
        result.errors[#result.errors + 1] = key_err
        return result
    end

    local models, fetch_err = M.fetch_models(provider, api_key)
    if not models then
        result.errors[#result.errors + 1] = fetch_err
        return result
    end

    -- Load existing models for this provider to detect new vs. existing
    local existing = {}
    local all = storage.list_models(provider)
    for _, row in ipairs(all) do
        existing[row.model] = row
    end

    for _, model_id in ipairs(models) do
        local pricing = M.infer_pricing(provider, model_id)
        if not pricing then
            -- Unknown pricing — add with zero so it appears in the list
            pricing = { input = 0, output = 0, cache_write = nil, cache_read = nil, cache_write_1h = nil }
        end

        local ex = existing[model_id]
        if ex then
            -- Model exists — only update if current pricing matches a tier
            -- (preserves manual edits)
            local ex_pricing = M.infer_pricing(provider, model_id)
            if ex_pricing
                and ex.input_per_1k == ex_pricing.input
                and ex.output_per_1k == ex_pricing.output then
                -- Pricing matches tier — safe to update
                local upsert_err = storage.upsert_model_price(
                    provider, model_id,
                    pricing.input, pricing.output,
                    pricing.cache_write, pricing.cache_read, pricing.cache_write_1h
                )
                if upsert_err then
                    result.errors[#result.errors + 1] = model_id .. ": " .. tostring(upsert_err)
                else
                    result.updated = result.updated + 1
                end
            else
                result.skipped = result.skipped + 1
            end
        else
            -- New model — insert
            local upsert_err = storage.upsert_model_price(
                provider, model_id,
                pricing.input, pricing.output,
                pricing.cache_write, pricing.cache_read
            )
            if upsert_err then
                result.errors[#result.errors + 1] = model_id .. ": " .. tostring(upsert_err)
            else
                result.added = result.added + 1
            end
        end
    end

    return result
end

--- Sync all providers (or a single one if only_provider is given).
--- Returns { results = [ {provider, added, updated, skipped, errors}, ... ] }
function M.sync_all(only_provider)
    local results = {}
    for _, provider in ipairs(PROVIDER_ORDER) do
        if not only_provider or only_provider == provider then
            local ok, result = pcall(M.sync_provider, provider)
            if ok then
                results[#results + 1] = result
                local n = result.added
                if n > 0 then
                    ngx.log(ngx.NOTICE, "model_sync: ", provider, " — ", n, " new models added")
                end
            else
                results[#results + 1] = {
                    provider = provider,
                    added = 0, updated = 0, skipped = 0,
                    errors = { tostring(result) },
                }
                ngx.log(ngx.WARN, "model_sync: ", provider, " failed: ", tostring(result))
            end
        end
    end
    return { results = results }
end

-- ---------------------------------------------------------------------------
-- Self-scheduling timer (called from init_worker on worker 0)
-- ---------------------------------------------------------------------------
local SYNC_INTERVAL = 86400  -- 24 hours

function M.start_timer()
    -- Initial sync after 60 seconds (let the gateway fully start)
    ngx.timer.at(60, function(premature)
        if premature then return end
        ngx.log(ngx.NOTICE, "model_sync: initial sync starting")
        local ok, err = pcall(M.sync_all)
        if not ok then
            ngx.log(ngx.ERR, "model_sync: initial sync failed: ", tostring(err))
        end
    end)

    -- Recurring daily sync
    ngx.timer.every(SYNC_INTERVAL, function(premature)
        if premature then return end
        ngx.log(ngx.NOTICE, "model_sync: daily sync starting")
        local ok, err = pcall(M.sync_all)
        if not ok then
            ngx.log(ngx.ERR, "model_sync: daily sync failed: ", tostring(err))
        end
    end)
end

return M
