-- state/shared_dict.lua — ngx.shared.dict backend for ephemeral hot state
--
-- Public interface (mirrors state/redis.lua):
--   M.cache_get(key)               → value | nil
--   M.cache_set(key, value, ttl)   → true | nil, err
--   M.cache_del(key)
--   M.rate_limit_check(key, window_sec, limit) → allowed (bool), count
--   M.counter_incr(key, delta)     → new_value
--   M.counter_get(key)             → value (number)
--   M.byok_get(key)                → value | nil
--   M.byok_set(key, value, ttl)
--   M.config_get(key)              → value | nil
--   M.config_set(key, value, ttl)
--   M.metrics_incr(key, delta)     → new_value

local cfg = require("core.app_config")
local sd  = cfg.shared_dict

local M = {}

local function dict(name)
    local d = ngx.shared[name]
    if not d then
        error("ngx.shared." .. name .. " not defined — add to nginx config")
    end
    return d
end

-- Generic cache dict
function M.cache_get(key)
    return dict(sd.cache):get(key)
end

function M.cache_set(key, value, ttl)
    local ok, err, _ = dict(sd.cache):set(key, value, ttl or 0)
    return ok, err
end

function M.cache_del(key)
    dict(sd.cache):delete(key)
end

-- Rate limiting — sliding window approximation using two fixed buckets.
-- For exact sliding window use Redis; this is good enough for dev/test.
-- Returns: allowed (bool), current_count (number)
function M.rate_limit_check(key, window_sec, limit)
    local d     = dict(sd.rate_limit)
    local now   = ngx.now()
    local slot  = math.floor(now / window_sec)  -- current window bucket
    local k_cur = key .. ":" .. slot
    local k_prv = key .. ":" .. (slot - 1)

    -- Weighted count: full previous bucket + current bucket, normalised by
    -- how far through the current window we are.
    local elapsed = now - (slot * window_sec)
    local weight  = 1 - (elapsed / window_sec)

    local cur = d:get(k_cur) or 0
    local prv = d:get(k_prv) or 0
    local count = math.floor(prv * weight + cur)

    if count >= limit then
        return false, count
    end

    -- Increment current bucket (TTL = 2 windows so previous stays readable)
    local new_cur, err = d:incr(k_cur, 1, 0, window_sec * 2)
    if err then
        ngx.log(ngx.ERR, "rate_limit incr error: ", err)
    end
    return true, (new_cur or cur + 1)
end

-- Generic counter (for budget tracking, token totals, etc.)
function M.counter_incr(key, delta)
    local val, err = dict(sd.metrics):incr(key, delta or 1, 0)
    if err then
        ngx.log(ngx.WARN, "counter_incr err: ", err)
        return 0
    end
    return val
end

function M.counter_get(key)
    return dict(sd.metrics):get(key) or 0
end

-- BYOK decrypted-key short-lived cache
function M.byok_get(key)
    return dict(sd.byok):get(key)
end

function M.byok_set(key, value, ttl)
    dict(sd.byok):set(key, value, ttl or 60)
end

-- Config hot cache
function M.config_get(key)
    return dict(sd.config):get(key)
end

function M.config_set(key, value, ttl)
    dict(sd.config):set(key, value, ttl or 30)
end

-- Prometheus-style metric increment
function M.metrics_incr(key, delta)
    return M.counter_incr(key, delta)
end

return M
