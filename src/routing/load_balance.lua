-- routing/load_balance.lua — weighted random / round-robin / sticky-session target selection
--
-- Called by routing/engine.lua when a matched rule has an `actions.load_balance` block.
--
-- load_balance config shape:
--   {
--     strategy = "weighted_random" | "round_robin",   -- default: weighted_random
--     sticky   = { field = "meta.user_id", ttl = 3600 },  -- optional
--     targets  = [
--       { provider = "openai",    model = "gpt-4o",          weight = 7 },
--       { provider = "anthropic", model = "claude-sonnet-4-6", weight = 3 },
--     ]
--   }
--
-- weight = 0 disables a target without removing it from config.
-- Remaining active (weight > 0) targets that were not selected are
-- returned as `fallbacks` by engine.lua so upstream can try them on failure.

local state = require("state")
local M = {}

-- Build a cumulative weight array for O(n) weighted random selection.
-- Returns cum[i] = sum of weights[1..i], total = sum of all weights.
local function build_cum_weights(targets)
    local total = 0
    local cum   = {}
    for i, t in ipairs(targets) do
        total   = total + (t.weight or 1)
        cum[i]  = total
    end
    return cum, total
end

-- Weighted random selection from `targets`.  Returns the chosen index.
local function pick_weighted(targets, cum, total)
    local r = math.random() * total
    for i, c in ipairs(cum) do
        if r <= c then return i end
    end
    return #targets  -- fallback for floating-point edge case
end

-- Round-robin selection using a shared-dict counter keyed by rule_id.
-- Returns the chosen index into `targets`.
local function pick_round_robin(targets, rule_id)
    local key = "lb_rr:" .. (rule_id or "default")
    local n   = state.counter_incr(key, 1)  -- atomic, wraps at maxint (harmless)
    return ((n - 1) % #targets) + 1
end

-- Resolve the sticky-session field value from ctx.
-- Supports "meta.<key>" notation.
local function get_sticky_value(ctx, field)
    if not field or field == "" then return nil end
    local meta_key = field:match("^meta%.(.+)$")
    if meta_key then
        return ctx.meta and ctx.meta[meta_key] or nil
    end
    -- Could extend here: "header:<name>", "user_id", etc.
    return nil
end

-- Select one target from lb_config.targets.
-- Returns the selected {provider, model, weight} table, or nil if no active targets.
function M.select(ctx, lb_config, rule_id)
    local targets = lb_config and lb_config.targets
    if not targets or #targets == 0 then return nil end

    -- Filter to active (weight > 0) targets only
    local active = {}
    for _, t in ipairs(targets) do
        if (t.weight or 1) > 0 then
            active[#active + 1] = t
        end
    end
    if #active == 0 then return nil end
    if #active == 1 then return active[1] end

    local strategy = lb_config.strategy or "weighted_random"
    local sticky   = lb_config.sticky

    -- Sticky session: return the cached target for this user/session value
    if sticky and sticky.field then
        local val = get_sticky_value(ctx, sticky.field)
        if val and val ~= "" then
            local cache_key = "lb_sticky:" .. ctx.gateway_id .. ":"
                              .. ngx.crc32_short(val)
            local cached_idx = state.config_get(cache_key)
            if cached_idx then
                local idx = tonumber(cached_idx)
                -- Validate the cached index is still valid (target count may have changed)
                if idx and idx >= 1 and idx <= #active then
                    return active[idx]
                end
            end
            -- No valid cached assignment — select and store
            local cum, total = build_cum_weights(active)
            local idx = pick_weighted(active, cum, total)
            state.config_set(cache_key, tostring(idx), sticky.ttl or 3600)
            return active[idx]
        end
    end

    -- Weighted random (default)
    if strategy == "round_robin" then
        local idx = pick_round_robin(active, rule_id)
        return active[idx]
    else
        local cum, total = build_cum_weights(active)
        local idx = pick_weighted(active, cum, total)
        return active[idx]
    end
end

return M
