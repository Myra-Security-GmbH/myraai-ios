-- routing/engine.lua — evaluate ordered routing rules against the request context
-- Rules are fetched from storage and cached in state.
-- Each rule: { priority, conditions: [{field, op, value}], actions: {provider, model, fallbacks:[]} }
--
-- Condition fields: "model", "tenant_id", "header:{name}", "meta:{key}"
-- Operators: "eq", "neq", "prefix", "contains", "regex"
--
-- actions may also contain a "load_balance" block (see routing/load_balance.lua).
-- When present, a target is selected and the remaining active targets become fallbacks.

local storage = require("storage")
local state   = require("state")
local json    = require("utils.json")

local M = {}

local function get_field(ctx, field)
    if field == "model"     then return ctx.model     end
    if field == "provider"  then return ctx.provider  end
    if field == "tenant_id" then return ctx.tenant_id end

    local hdr = field:match("^header:(.+)$")
    if hdr then return ngx.var["http_" .. hdr:gsub("-", "_")] end

    local meta = field:match("^meta:(.+)$")
    if meta then return ctx.meta and ctx.meta[meta] end

    return nil
end

local function eval_condition(ctx, cond)
    local val = get_field(ctx, cond.field or "")
    local op  = cond.op    or "eq"
    local ref = cond.value or ""

    if op == "eq"       then return val == ref end
    if op == "neq"      then return val ~= ref end
    if op == "prefix"   then return type(val) == "string" and val:sub(1, #ref) == ref end
    if op == "contains" then return type(val) == "string" and val:find(ref, 1, true) ~= nil end
    if op == "regex"    then
        if type(val) ~= "string" then return false end
        local ok, m = pcall(string.find, val, ref)
        return ok and m ~= nil
    end
    return false
end

local function eval_rule(ctx, rule)
    local conditions = type(rule.conditions) == "table"
        and rule.conditions
        or json.decode(rule.conditions or "[]") or {}
    for _, cond in ipairs(conditions) do
        if not eval_condition(ctx, cond) then return false end
    end
    return true
end

-- Returns the matched actions table or nil (no rule matched).
function M.evaluate(ctx)
    local cache_key = "rules:" .. ctx.gateway_id
    local cached    = state.config_get(cache_key)
    local rules

    if cached then
        rules = json.decode(cached) or {}
    else
        local rows, err = storage.get_routing_rules(ctx.gateway_id)
        if err then
            ngx.log(ngx.ERR, "routing engine: load rules error: ", err)
            return nil
        end
        rules = rows or {}
        state.config_set(cache_key, json.encode(rules), 30)
    end

    for _, rule in ipairs(rules) do
        if eval_rule(ctx, rule) then
            local actions = type(rule.actions) == "table"
                and rule.actions
                or json.decode(rule.actions or "{}") or {}

            -- Load-balance action: select one target; remaining become fallbacks
            if actions.load_balance then
                local lb     = require("routing.load_balance")
                local chosen = lb.select(ctx, actions.load_balance, rule.id)
                if chosen then
                    local fallbacks = {}
                    for _, t in ipairs(actions.load_balance.targets or {}) do
                        if t ~= chosen and (t.weight or 1) > 0 then
                            fallbacks[#fallbacks + 1] = t
                        end
                    end
                    return {
                        provider  = chosen.provider,
                        model     = chosen.model,
                        fallbacks = fallbacks,
                    }
                end
                -- No active targets (all weight=0): fall through to next rule
            else
                return actions
            end
        end
    end

    return nil  -- no rule matched; caller uses defaults
end

return M
