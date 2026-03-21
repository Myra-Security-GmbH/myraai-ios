-- core/circuit_breaker.lua — per-provider circuit breaker
--
-- State machine per (gateway_id, provider):
--
--   CLOSED ──(failures >= threshold)──▶ OPEN
--   OPEN   ──(cooldown elapsed)────────▶ HALF_OPEN  (probe: one request through)
--   HALF_OPEN ──(probe succeeds)───────▶ CLOSED
--   HALF_OPEN ──(probe fails)──────────▶ OPEN  (restart cooldown)
--
-- "Closed" is the default/healthy state — no key stored.
-- "Open" and "half_open" are stored explicitly in the config dict.
--
-- Gateway config shape (all fields optional):
--   circuit_breaker = {
--     enabled              = true,
--     failure_threshold    = 5,          -- failures within window_sec before opening
--     window_sec           = 60,         -- sliding failure-count window
--     cooldown_ms          = 30000,      -- ms to wait in OPEN before probing
--     failure_status_codes = {500, 502, 503, 504},  -- HTTP codes that count as failures
--   }
-- Connection/timeout errors (nil status) always count regardless of failure_status_codes.

local cfg_mod = require("core.app_config")

local M = {}

local DEFAULT_THRESHOLD    = 5
local DEFAULT_WINDOW_SEC   = 60
local DEFAULT_COOLDOWN_MS  = 30000
local DEFAULT_FAIL_CODES   = { [500]=true, [502]=true, [503]=true, [504]=true }

-- Build a set from the failure_status_codes list for O(1) lookup.
local function build_fail_set(codes)
    if not codes then return DEFAULT_FAIL_CODES end
    local s = {}
    for _, c in ipairs(codes) do s[c] = true end
    return s
end

-- Shared dict accessors.  We reuse existing dicts — no new allocation needed.
--   Failure counter → aig_ratelimit (supports incr with TTL, auto-expires)
--   State string    → aig_config    (supports string set/get)
local function rl_dict()
    return ngx.shared[cfg_mod.shared_dict.rate_limit]
end

local function cfg_dict()
    return ngx.shared[cfg_mod.shared_dict.config]
end

-- Key helpers
local function k_fail(gw_id, provider)
    return "cb:fail:" .. gw_id .. ":" .. provider
end
local function k_state(gw_id, provider)
    return "cb:state:" .. gw_id .. ":" .. provider
end
local function k_opened(gw_id, provider)
    return "cb:opened:" .. gw_id .. ":" .. provider
end

-- Returns "allow" or "deny".
-- Call this before attempting an upstream call for `provider`.
function M.check(gw_id, provider, cfg)
    if not cfg or not cfg.enabled then return "allow" end

    local cooldown_sec = ((cfg.cooldown_ms or DEFAULT_COOLDOWN_MS) / 1000)
    local state_val    = cfg_dict():get(k_state(gw_id, provider))

    -- No state key → closed (healthy)
    if not state_val then return "allow" end

    if state_val == "open" then
        local opened_at = tonumber(cfg_dict():get(k_opened(gw_id, provider))) or 0
        if ngx.now() - opened_at >= cooldown_sec then
            -- Cooldown elapsed → transition to half_open, let one probe through
            local state_ttl = cooldown_sec * 10
            cfg_dict():set(k_state(gw_id, provider),  "half_open", state_ttl)
            ngx.log(ngx.INFO, "circuit_breaker: half-open probe gw=", gw_id,
                    " provider=", provider)
            return "allow"
        end
        return "deny"
    end

    if state_val == "half_open" then
        return "allow"  -- probe already in progress; let it through
    end

    return "allow"  -- unknown state: fail open
end

-- Call after an upstream failure (5xx or connection error).
-- `status_code` is the HTTP status number, or nil for connection/timeout errors.
function M.record_failure(gw_id, provider, cfg, status_code)
    if not cfg or not cfg.enabled then return end

    -- Check if this status code should count as a failure
    if status_code ~= nil then
        local fail_set = build_fail_set(cfg.failure_status_codes)
        if not fail_set[status_code] then return end  -- not a counted failure
    end
    -- nil status (connection error) always counts

    local threshold    = cfg.failure_threshold or DEFAULT_THRESHOLD
    local window_sec   = cfg.window_sec        or DEFAULT_WINDOW_SEC
    local cooldown_sec = (cfg.cooldown_ms or DEFAULT_COOLDOWN_MS) / 1000
    local state_ttl    = cooldown_sec * 10

    local state_val = cfg_dict():get(k_state(gw_id, provider))

    if state_val == "half_open" then
        -- Probe failed → re-open, restart cooldown
        cfg_dict():set(k_state(gw_id, provider),  "open",            state_ttl)
        cfg_dict():set(k_opened(gw_id, provider), tostring(ngx.now()), state_ttl)
        ngx.log(ngx.WARN, "circuit_breaker: re-opened (probe failed) gw=",
                gw_id, " provider=", provider)
        return
    end

    if state_val == "open" then
        return  -- already open; don't overwrite the opened_at timestamp
    end

    -- Closed state: increment failure counter with sliding window TTL
    -- incr(key, delta, init_value, exptime) — sets TTL on first creation
    local count = rl_dict():incr(k_fail(gw_id, provider), 1, 0, window_sec * 2)
    if count and count >= threshold then
        cfg_dict():set(k_state(gw_id, provider),  "open",            state_ttl)
        cfg_dict():set(k_opened(gw_id, provider), tostring(ngx.now()), state_ttl)
        ngx.log(ngx.WARN, "circuit_breaker: opened gw=", gw_id,
                " provider=", provider, " failures=", count,
                "/", threshold, " in ", window_sec, "s")
    end
end

-- Call after a successful upstream response.
function M.record_success(gw_id, provider, cfg)
    if not cfg or not cfg.enabled then return end

    local state_val = cfg_dict():get(k_state(gw_id, provider))
    if state_val == "half_open" or state_val == "open" then
        -- Reset to closed: remove state keys and failure counter
        cfg_dict():delete(k_state(gw_id, provider))
        cfg_dict():delete(k_opened(gw_id, provider))
        rl_dict():delete(k_fail(gw_id, provider))
        ngx.log(ngx.INFO, "circuit_breaker: closed gw=", gw_id,
                " provider=", provider)
    end
end

return M
