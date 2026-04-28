-- admin/model_sync.lua — Daily model + price catalog refresh.
--
-- Source of truth for pricing is, in priority order:
--
--   1. LiteLLM's `model_prices_and_context_window.json` on GitHub. The de-facto
--      industry catalog, ~2700 models, MIT-licensed, updated within hours of
--      every new model release. Covers Anthropic, OpenAI, Mistral, Groq,
--      DeepSeek, xAI, Perplexity, Together, Fireworks, Cohere — every primary
--      provider we route to. No auth required.
--
--   2. OpenRouter's /api/v1/models. Authoritative for OR-routed models because
--      OR is the entity billing us — they know the price they charge. Returns
--      pricing inline; LiteLLM's coverage of OR is partial (~91 of ~300
--      models) so we sync OR separately and let it overwrite LiteLLM's OR
--      rows.
--
-- We do NOT guess prices from model-name patterns anymore. Earlier versions of
-- this file inferred pricing via hard-coded regex tiers (e.g. "^claude-opus-4-[56]"
-- catches 4.5 and 4.6, anything else falls through to legacy 4.0/4.1 pricing).
-- That approach silently mis-priced every new model the moment Anthropic
-- released it — see the claude-opus-4-7 incident on 2026-04-28 where every
-- request was billed at 3× the correct rate for 8 days. If a model is missing
-- from both LiteLLM and OpenRouter, we leave the row absent rather than guess;
-- cost_table.calculate then returns nil and the request is recorded with
-- cost_usd=0 (untracked) — better to under-report a tracking gap than to
-- over-bill at 3× until someone notices.
--
-- Invocation: ngx.timer.every(86400) from nginx init_worker (worker 0 only via
-- the existing init guards), and POST /admin/v1/model-prices/sync from the UI.

local storage = require("storage")
local crypto  = require("utils.crypto")
local cfg     = require("core.app_config")
local cjson   = require("cjson.safe")

local M = {}

local LITELLM_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"

-- LiteLLM `litellm_provider` value → our internal provider name.
-- We deliberately omit OpenRouter here — its models are synced via the
-- authoritative OR API in M.sync_openrouter() which overwrites whatever
-- LiteLLM happened to ship. We also skip Bedrock/Vertex/Azure variants since
-- those are aliased into the named providers above (e.g. an Anthropic model
-- on Bedrock is still an "anthropic" model from the gateway's POV — matched
-- on the model_id prefix at the route layer).
local PROVIDER_MAP = {
    anthropic    = "anthropic",
    openai       = "openai",
    mistral      = "mistral",
    groq         = "groq",
    deepseek     = "deepseek",
    xai          = "xai",
    perplexity   = "perplexity",
    together_ai  = "together",
    fireworks_ai = "fireworks",
    cohere       = "cohere",
    cerebras     = "cerebras",
}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Get a decrypted API key for a provider (first available across gateways).
--- Used by sync_openrouter; LiteLLM doesn't need a key.
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

local function http_get_json(url, headers, timeout_ms)
    local httpc = require("resty.http").new()
    httpc:set_timeout(timeout_ms or 30000)
    local res, err = httpc:request_uri(url, {
        method = "GET", headers = headers or {}, ssl_verify = true,
    })
    if not res then return nil, "HTTP error: " .. tostring(err) end
    if res.status >= 400 then
        return nil, "HTTP " .. res.status .. ": " .. (res.body or ""):sub(1, 200)
    end
    local body = cjson.decode(res.body)
    if not body then return nil, "JSON decode failed (body " .. #(res.body or "") .. " bytes)" end
    return body
end

--- Round to 10 decimal places (matches LiteLLM's precision).
local function r10(n) return math.floor(n * 1e10 + 0.5) / 1e10 end

-- Compare two pricing rows; treat nil and 0 as equal so a row that LiteLLM
-- doesn't carry cache_write for doesn't constantly look "changed".
local function pricing_equal(a, b)
    local function eq(x, y)
        x = x or 0; y = y or 0
        return math.abs(x - y) < 1e-12
    end
    return eq(a.input_per_1k,         b.input_per_1k)
       and eq(a.output_per_1k,        b.output_per_1k)
       and eq(a.cache_write_per_1k,   b.cache_write_per_1k)
       and eq(a.cache_read_per_1k,    b.cache_read_per_1k)
       and eq(a.cache_write_1h_per_1k, b.cache_write_1h_per_1k)
end

-- ---------------------------------------------------------------------------
-- LiteLLM sync — primary source for everything except OpenRouter
-- ---------------------------------------------------------------------------

function M.sync_litellm()
    local result = { provider = "litellm", added = 0, updated = 0, skipped = 0, errors = {} }

    local data, err = http_get_json(LITELLM_URL, nil, 30000)
    if not data then
        result.errors[#result.errors + 1] = "fetch LiteLLM JSON: " .. tostring(err)
        return result
    end

    -- Pre-load existing rows once so we can diff in memory rather than hammer
    -- the DB with one read per model.
    local existing = {}
    for _, our_provider in pairs(PROVIDER_MAP) do
        if not existing[our_provider] then
            existing[our_provider] = {}
            local rows = storage.list_models(our_provider) or {}
            for _, row in ipairs(rows) do existing[our_provider][row.model] = row end
        end
    end

    for model_id, info in pairs(data) do
        if type(info) == "table" then
            local litellm_provider = info.litellm_provider
            local our_provider     = PROVIDER_MAP[litellm_provider]
            if our_provider then
                local input_cost  = info.input_cost_per_token
                local output_cost = info.output_cost_per_token
                if type(input_cost) == "number" and type(output_cost) == "number" then
                    local cw = info.cache_creation_input_token_cost
                    local cr = info.cache_read_input_token_cost
                    local pricing = {
                        input_per_1k          = r10(input_cost  * 1000),
                        output_per_1k         = r10(output_cost * 1000),
                        cache_write_per_1k    = cw and r10(cw * 1000) or nil,
                        cache_read_per_1k     = cr and r10(cr * 1000) or nil,
                        -- LiteLLM doesn't expose a separate 1h rate; Anthropic
                        -- charges 2× the 5m rate for 1h. Default in line.
                        cache_write_1h_per_1k = cw and r10(cw * 1000 * 1.6) or nil,
                    }

                    local ex = existing[our_provider] and existing[our_provider][model_id]
                    if ex and pricing_equal(ex, pricing) then
                        result.skipped = result.skipped + 1
                    else
                        local ue = storage.upsert_model_price(
                            our_provider, model_id,
                            pricing.input_per_1k, pricing.output_per_1k,
                            pricing.cache_write_per_1k, pricing.cache_read_per_1k,
                            pricing.cache_write_1h_per_1k
                        )
                        if ue then
                            result.errors[#result.errors + 1] = model_id .. ": " .. tostring(ue)
                        elseif ex then
                            result.updated = result.updated + 1
                            ngx.log(ngx.NOTICE, "model_sync: updated ", our_provider, "/", model_id,
                                " input=", pricing.input_per_1k, " output=", pricing.output_per_1k,
                                " (was input=", ex.input_per_1k, " output=", ex.output_per_1k, ")")
                        else
                            result.added = result.added + 1
                            ngx.log(ngx.NOTICE, "model_sync: added ", our_provider, "/", model_id,
                                " input=", pricing.input_per_1k, " output=", pricing.output_per_1k)
                        end
                    end
                end
            end
        end
    end

    return result
end

-- ---------------------------------------------------------------------------
-- OpenRouter sync — authoritative for OR-routed models
-- ---------------------------------------------------------------------------

function M.sync_openrouter()
    local result = { provider = "openrouter", added = 0, updated = 0, skipped = 0, errors = {} }

    local api_key, key_err = M.get_api_key("openrouter")
    if not api_key then
        -- Not an error — just nothing to sync if no OR gateway is configured.
        result.errors[#result.errors + 1] = key_err
        return result
    end

    local body, err = http_get_json("https://openrouter.ai/api/v1/models",
                                    { ["Authorization"] = "Bearer " .. api_key }, 15000)
    if not body or not body.data then
        result.errors[#result.errors + 1] = "fetch OpenRouter models: " .. tostring(err or "unexpected response")
        return result
    end

    local existing = {}
    for _, row in ipairs(storage.list_models("openrouter") or {}) do
        existing[row.model] = row
    end

    for _, m in ipairs(body.data) do
        local model_id = m.id
        local p = m.pricing or {}
        local prompt = tonumber(p.prompt)
        local completion = tonumber(p.completion)
        if model_id and prompt and completion then
            -- OR's pricing fields are USD per token (string). Cache fields are
            -- present for some models, absent for others.
            local cw = tonumber(p.input_cache_write or p.cache_write_5m or p.cache_write)
            local cr = tonumber(p.input_cache_read  or p.cache_read)
            local pricing = {
                input_per_1k          = r10(prompt * 1000),
                output_per_1k         = r10(completion * 1000),
                cache_write_per_1k    = cw and r10(cw * 1000) or nil,
                cache_read_per_1k     = cr and r10(cr * 1000) or nil,
                cache_write_1h_per_1k = cw and r10(cw * 1000 * 1.6) or nil,
            }

            local ex = existing[model_id]
            if ex and pricing_equal(ex, pricing) then
                result.skipped = result.skipped + 1
            else
                local ue = storage.upsert_model_price(
                    "openrouter", model_id,
                    pricing.input_per_1k, pricing.output_per_1k,
                    pricing.cache_write_per_1k, pricing.cache_read_per_1k,
                    pricing.cache_write_1h_per_1k
                )
                if ue then
                    result.errors[#result.errors + 1] = model_id .. ": " .. tostring(ue)
                elseif ex then
                    result.updated = result.updated + 1
                else
                    result.added = result.added + 1
                end
            end
        end
    end

    return result
end

-- ---------------------------------------------------------------------------
-- Public entry points
-- ---------------------------------------------------------------------------

--- Sync model_price from LiteLLM + OpenRouter.
--- Returns { results = [ {provider, added, updated, skipped, errors}, ... ] }
--- The `only_source` arg accepts "litellm" or "openrouter" to limit the sync;
--- any other value (including legacy provider names like "anthropic") runs
--- both syncs — keeps the existing /admin/v1/model-prices/sync endpoint
--- backwards-compatible whether or not the caller passes a query arg.
function M.sync_all(only_source)
    if only_source ~= "litellm" and only_source ~= "openrouter" then
        only_source = nil
    end
    local results = {}
    if not only_source or only_source == "litellm" then
        local ok, r = pcall(M.sync_litellm)
        if ok then results[#results + 1] = r
        else results[#results + 1] = { provider = "litellm", added = 0, updated = 0, skipped = 0,
                                        errors = { tostring(r) } } end
    end
    if not only_source or only_source == "openrouter" then
        local ok, r = pcall(M.sync_openrouter)
        if ok then results[#results + 1] = r
        else results[#results + 1] = { provider = "openrouter", added = 0, updated = 0, skipped = 0,
                                        errors = { tostring(r) } } end
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
