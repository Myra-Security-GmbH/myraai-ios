-- observability/metrics.lua — Prometheus-style counters via ngx.shared.dict
-- Expose at GET /metrics in Prometheus text format.

local cfg = require("core.app_config")

local M = {}

local DICT_NAME = cfg.shared_dict and cfg.shared_dict.metrics or "aig_metrics"

local function dict()
    return ngx.shared[DICT_NAME]
end

-- Called from init_by_lua_block
function M.init()
    -- Nothing needed: shared dict is pre-allocated in nginx config
end

-- Increment a counter by delta (default 1)
function M.incr(name, delta, labels)
    local key = name
    if labels then
        local parts = {}
        for k, v in pairs(labels) do parts[#parts + 1] = k .. "=" .. v end
        table.sort(parts)
        key = name .. "{" .. table.concat(parts, ",") .. "}"
    end
    local d = dict()
    if not d then return end
    local _, err = d:incr(key, delta or 1, 0)
    if err then
        ngx.log(ngx.WARN, "metrics incr error: ", err)
    end
end

-- Record a histogram sample (approximation: just count and sum)
function M.observe(name, value, labels)
    local key = name
    if labels then
        local parts = {}
        for k, v in pairs(labels) do parts[#parts + 1] = k .. "=" .. v end
        table.sort(parts)
        key = name .. "{" .. table.concat(parts, ",") .. "}"
    end
    local d = dict()
    if not d then return end
    d:incr(key .. "_count", 1,     0)
    d:incr(key .. "_sum",   value, 0)
end

-- Called from log_by_lua_block after each request
function M.record(ctx)
    if not ctx then return end

    local labels = {
        provider  = ctx.provider  or "unknown",
        tenant_id = ctx.tenant_id or "unknown",
        status    = tostring(ctx.provider_status or ngx.status),
        cached    = ctx.cache_hit and "1" or "0",
    }

    M.incr("aig_requests_total", 1, labels)
    M.observe("aig_latency_ms",  M.latency_ms(ctx), labels)
    M.incr("aig_input_tokens_total",  ctx.input_tokens  or 0, labels)
    M.incr("aig_output_tokens_total", ctx.output_tokens or 0, labels)
end

function M.latency_ms(ctx)
    if not ctx or not ctx.start_ms then return 0 end
    return math.floor(ngx.now() * 1000 - ctx.start_ms)
end

-- Expose Prometheus text format at /metrics
function M.expose()
    local d = dict()
    if not d then
        ngx.say("# no metrics dict")
        return
    end

    ngx.header["Content-Type"] = "text/plain; version=0.0.4"

    local keys = d:get_keys(0)  -- 0 = all keys
    table.sort(keys)

    local current_metric
    for _, key in ipairs(keys) do
        -- Derive metric name (strip labels)
        local metric_name = key:match("^([^{]+)")
        if metric_name ~= current_metric then
            ngx.say("# TYPE " .. metric_name .. " counter")
            current_metric = metric_name
        end
        local val = d:get(key) or 0
        ngx.say(key .. " " .. val)
    end
end

return M
