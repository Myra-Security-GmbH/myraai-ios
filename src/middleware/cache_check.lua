-- middleware/cache_check.lua — exact-match cache lookup
-- On hit: serves cached response immediately and exits pipeline.
-- On miss: sets ctx.cache_key for cache_store.lua to fill later.

local cache_key_builder = require("cache.key")
local state             = require("state")
local json              = require("utils.json")
local req_util          = require("utils.request")

local M = {}

function M.run(ctx)
    local ttl = ctx.gateway_config.cache_ttl or 0
    if ttl <= 0 then return end  -- caching disabled

    -- Body isn't parsed yet — parse it now (cheaply; it's small for cache check)
    local raw = req_util.read_body()
    if not raw then return end

    ctx.raw_request_body = raw
    local body = json.decode(raw)
    if not body then return end

    ctx.request_body = body
    ctx.model        = body.model

    local key = cache_key_builder.build(ctx)
    if not key then return end

    ctx.cache_key = key

    local cached = state.cache_get(key)
    if not cached then
        -- Semantic cache check (vector similarity, only on exact-match miss)
        local sem_cfg = ctx.gateway_config.semantic_cache
        if sem_cfg and sem_cfg.enabled then
            local ok, sem = pcall(require, "cache.semantic")
            if ok then
                local hit = sem.check(ctx, sem_cfg)
                if hit then
                    ctx.cache_hit          = true
                    ctx.semantic_cache_hit = true
                    ctx.log_fields         = ctx.log_fields or {}
                    ctx.log_fields.saved_cost_usd = hit.cost_usd
                    ngx.status = 200
                    ngx.header["Content-Type"]     = "application/json"
                    ngx.header["X-AIG-Cache"]      = "SEMANTIC_HIT"
                    ngx.header["X-AIG-Similarity"] = string.format("%.4f", hit.similarity)
                    ngx.print(hit.response_body)
                    ngx.exit(200)
                end
            end
        end
        return
    end

    -- Cache hit — return the stored response and stop processing
    ctx.cache_hit = true

    local entry = json.decode(cached)
    if not entry then return end  -- corrupted entry; fall through to upstream

    -- Record what the upstream call would have cost/taken
    ctx.log_fields.saved_cost_usd = entry.cost_usd or 0
    local avg_ms = tonumber(state.config_get(
        "avg_upstream_ms:" .. (ctx.provider or "") .. ":" .. (ctx.model or "")))
    if avg_ms then
        ctx.log_fields.saved_latency_ms = avg_ms
    end

    ngx.status = 200
    ngx.header["Content-Type"]    = "application/json"
    ngx.header["X-AIG-Cache"]     = "HIT"
    ngx.header["X-Cache-Key"]     = key
    if not entry.body then return end  -- corrupted entry: no body field
    ngx.print(entry.body)
    ngx.exit(200)
end

return M
