-- tests/unit/test_spend_budget.lua — unit tests for the period-aware budget system
-- Run with: resty tests/runner.lua tests/unit/test_spend_budget.lua
--
-- Tests:
--   1.  budget.current_period("monthly")  → "YYYY-MM"
--   2.  budget.current_period("daily")    → "YYYY-MM-DD"
--   3.  budget.current_period("total")    → "total"
--   4.  budget.current_period(nil)        → falls back to monthly
--   5.  cost.run records spend per gateway, tenant, and token
--   6.  cost.run with nil cost does NOT write to storage
--   7.  quota.run blocks when gateway budget exceeded
--   8.  quota.run blocks when tenant budget exceeded
--   9.  quota.run blocks when token budget exceeded
--  10.  quota.run allows when under budget
--  11.  quota.run skips when no budget_usd configured
--  12.  Previous period spend does NOT affect current-period check
--  13.  Cache hit path in quota.run avoids storage.get_spend call
--  14.  cost.run does not crash when tenant_id is nil

-- ---------------------------------------------------------------------------
-- Minimal ngx stub
-- ---------------------------------------------------------------------------
local shared_store = {}

_G.ngx = {
    now    = function() return 1700000000.0 end,
    time   = function() return 1700000000 end,
    log    = function() end,
    exit   = function(code) error("ngx.exit:" .. tostring(code)) end,
    status = 200,
    header = {},
    req    = {
        read_body     = function() end,
        get_body_data = function() return nil end,
        get_headers   = function() return {} end,
    },
    var  = {},
    ctx  = {},
    ERR  = 0, WARN = 1, INFO = 2,
    shared = setmetatable({}, {
        __index = function(_, name)
            if not shared_store[name] then
                local t = {}
                shared_store[name] = setmetatable({}, {
                    __index = {
                        get    = function(s, k)       return t[k] end,
                        set    = function(s, k, v, _) t[k] = v; return true end,
                        delete = function(s, k)       t[k] = nil end,
                        incr   = function(s, k, d, i) t[k] = (t[k] or (i or 0)) + d; return t[k] end,
                    }
                })
            end
            return shared_store[name]
        end
    }),
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local pass, fail = 0, 0

local function ok(name, cond, msg)
    if cond then
        pass = pass + 1
        print("PASS  " .. name)
    else
        fail = fail + 1
        print("FAIL  " .. name .. (msg and (" — " .. tostring(msg)) or ""))
    end
end

local function err_ok(name, fn)
    local ok2, err = pcall(fn)
    if not ok2 then
        pass = pass + 1
        print("PASS  " .. name .. " (raised: " .. tostring(err) .. ")")
    else
        fail = fail + 1
        print("FAIL  " .. name .. " (expected error, got none)")
    end
end

-- Reset module cache between tests
local function clear(names)
    for _, n in ipairs(names) do
        package.loaded[n]  = nil
        package.preload[n] = nil  -- clear stubs left by other test files
    end
    -- reset shared dict store
    shared_store = {}
end

-- ---------------------------------------------------------------------------
-- Stub storage (in-memory spend ledger)
-- ---------------------------------------------------------------------------
local spend_db = {}

local storage_stub = {
    incr_spend = function(entity_type, entity_id, period, micro)
        local k = entity_type .. ":" .. entity_id .. ":" .. period
        spend_db[k] = (spend_db[k] or 0) + micro
    end,
    get_spend = function(entity_type, entity_id, period)
        local k = entity_type .. ":" .. entity_id .. ":" .. period
        return spend_db[k] or 0
    end,
}

-- Stub cost_table
local cost_table_stub = {
    calculate = function(provider, model, it, ot, cc, cr)
        -- Returns 0.001 (1000 micro) for any real call
        return 0.001
    end
}

-- Stub errors
local errors_stub = {
    send = function(code, msg) error("QUOTA:" .. code .. ":" .. tostring(msg)) end
}

-- Stub state (shared dict wrapper)
local state_stub = {
    cache_get = function(k)
        return ngx.shared.cache:get(k)
    end,
    cache_set = function(k, v, ttl)
        ngx.shared.cache:set(k, v, ttl)
    end,
    cache_del = function(k)
        ngx.shared.cache:delete(k)
    end,
}

-- ---------------------------------------------------------------------------
-- 1-4. utils/budget.lua — period computation
-- ---------------------------------------------------------------------------

clear({"utils.budget"})
local budget_lib = require("utils.budget")

-- Freeze os.time so we get deterministic output
-- 2026-03-22 is the current date per context
local real_os_date = os.date
-- 2026-03-22 00:00:00 UTC = 1742601600 + 365*24*3600 = 1774137600
local FROZEN_TS = 1774137600
os.date = function(fmt, t)
    return real_os_date(fmt, FROZEN_TS)
end

ok("1. monthly period format",
    budget_lib.current_period("monthly") == "2026-03",
    budget_lib.current_period("monthly"))

ok("2. daily period format",
    budget_lib.current_period("daily") == "2026-03-22",
    budget_lib.current_period("daily"))

ok("3. total period",
    budget_lib.current_period("total") == "total")

ok("4. nil defaults to monthly",
    budget_lib.current_period(nil) == "2026-03",
    budget_lib.current_period(nil))

-- Restore os.date
os.date = real_os_date

-- ---------------------------------------------------------------------------
-- 5. cost.run records spend for gateway, tenant, and token
-- ---------------------------------------------------------------------------
clear({"middleware.cost", "utils.budget", "storage", "state", "observability.cost_table"})
spend_db = {}

package.loaded["storage"]               = storage_stub
package.loaded["state"]                 = state_stub
package.loaded["observability.cost_table"] = cost_table_stub
package.loaded["utils.budget"]          = budget_lib

local cost_mw = require("middleware.cost")
local ctx5 = {
    provider = "openai", model = "gpt-4o",
    input_tokens = 100, output_tokens = 50,
    cache_creation_tokens = 0, cache_read_tokens = 0,
    gateway_id = "gw-1", tenant_id = "tn-1",
    token_id = "tk-1", token_budget_usd = 10.0, token_budget_period = "monthly",
    gateway_config = { budget_period = "monthly", tenant_budget_period = "monthly" },
    log_fields = {},
}

os.date = function(fmt, t) return real_os_date(fmt, FROZEN_TS) end
cost_mw.run(ctx5)
os.date = real_os_date

ok("5. cost.run records gateway spend",
    (spend_db["gateway:gw-1:2026-03"] or 0) > 0,
    spend_db["gateway:gw-1:2026-03"])

ok("5b. cost.run records tenant spend",
    (spend_db["tenant:tn-1:2026-03"] or 0) > 0)

ok("5c. cost.run records token spend",
    (spend_db["token:tk-1:2026-03"] or 0) > 0)

ok("5d. ctx.cost_usd set",
    ctx5.cost_usd == 0.001)

-- ---------------------------------------------------------------------------
-- 6. cost.run with nil cost does NOT write storage
-- ---------------------------------------------------------------------------
clear({"middleware.cost", "utils.budget", "storage", "state", "observability.cost_table"})
spend_db = {}

local cost_table_zero = { calculate = function() return nil end }
package.loaded["storage"]               = storage_stub
package.loaded["state"]                 = state_stub
package.loaded["observability.cost_table"] = cost_table_zero
package.loaded["utils.budget"]          = budget_lib

local cost_mw6 = require("middleware.cost")
local ctx6 = {
    provider = "ollama", model = "llama3",
    input_tokens = 0, output_tokens = 0,
    gateway_id = "gw-2", tenant_id = "tn-2",
    gateway_config = {}, log_fields = {},
}
cost_mw6.run(ctx6)

ok("6. nil cost does not write spend",
    next(spend_db) == nil)

-- ---------------------------------------------------------------------------
-- 7. quota.run blocks when gateway budget exceeded
-- ---------------------------------------------------------------------------
clear({"middleware.quota", "utils.budget", "storage", "state"})
spend_db = {}

-- Pre-set spend so gateway is over budget
spend_db["gateway:gw-3:2026-03"] = 2000001  -- > 2.0 USD (2000000 micro)

package.loaded["storage"]      = storage_stub
package.loaded["state"]        = state_stub
package.loaded["utils.budget"] = budget_lib
package.loaded["core.errors"]  = errors_stub
package.loaded["utils.webhook"] = { fire = function() end }

local quota_mw = require("middleware.quota")
local ctx7 = {
    gateway_id = "gw-3", tenant_id = "tn-3",
    gateway_config = { budget_usd = 2.0, budget_period = "monthly" },
    log_fields = {},
}

os.date = function(fmt, t) return real_os_date(fmt, FROZEN_TS) end
local ok7, err7 = pcall(quota_mw.run, ctx7)
os.date = real_os_date

ok("7. quota blocks when gateway budget exceeded",
    not ok7 and tostring(err7):find("QUOTA"))

-- ---------------------------------------------------------------------------
-- 8. quota.run blocks when tenant budget exceeded
-- ---------------------------------------------------------------------------
clear({"middleware.quota", "utils.budget", "storage", "state"})
spend_db = {}

spend_db["tenant:tn-4:2026-03"] = 1000001  -- > 1.0 USD

package.loaded["storage"]      = storage_stub
package.loaded["state"]        = state_stub
package.loaded["utils.budget"] = budget_lib
package.loaded["core.errors"]  = errors_stub
package.loaded["utils.webhook"] = { fire = function() end }

local quota_mw8 = require("middleware.quota")
local ctx8 = {
    gateway_id = "gw-4", tenant_id = "tn-4",
    gateway_config = {
        tenant_budget_usd = 1.0, tenant_budget_period = "monthly",
        -- no gateway-level budget so only tenant check fires
    },
    log_fields = {},
}

os.date = function(fmt, t) return real_os_date(fmt, FROZEN_TS) end
local ok8, err8 = pcall(quota_mw8.run, ctx8)
os.date = real_os_date

ok("8. quota blocks when tenant budget exceeded",
    not ok8 and tostring(err8):find("QUOTA"))

-- ---------------------------------------------------------------------------
-- 9. quota.run blocks when token budget exceeded
-- ---------------------------------------------------------------------------
clear({"middleware.quota", "utils.budget", "storage", "state"})
spend_db = {}

spend_db["token:tk-5:2026-03"] = 501  -- > 0.0005 USD (500 micro)

package.loaded["storage"]      = storage_stub
package.loaded["state"]        = state_stub
package.loaded["utils.budget"] = budget_lib
package.loaded["core.errors"]  = errors_stub
package.loaded["utils.webhook"] = { fire = function() end }

local quota_mw9 = require("middleware.quota")
local ctx9 = {
    gateway_id = "gw-5", tenant_id = "tn-5",
    token_id = "tk-5", token_budget_usd = 0.0005, token_budget_period = "monthly",
    gateway_config = {},
    log_fields = {},
}

os.date = function(fmt, t) return real_os_date(fmt, FROZEN_TS) end
local ok9, err9 = pcall(quota_mw9.run, ctx9)
os.date = real_os_date

ok("9. quota blocks when token budget exceeded",
    not ok9 and tostring(err9):find("QUOTA"))

-- ---------------------------------------------------------------------------
-- 10. quota.run allows when under budget
-- ---------------------------------------------------------------------------
clear({"middleware.quota", "utils.budget", "storage", "state"})
spend_db = {}

spend_db["gateway:gw-6:2026-03"] = 100000  -- 0.10 USD, budget is 1.0 USD

package.loaded["storage"]      = storage_stub
package.loaded["state"]        = state_stub
package.loaded["utils.budget"] = budget_lib
package.loaded["core.errors"]  = errors_stub
package.loaded["utils.webhook"] = { fire = function() end }

local quota_mw10 = require("middleware.quota")
local ctx10 = {
    gateway_id = "gw-6", tenant_id = "tn-6",
    gateway_config = { budget_usd = 1.0, budget_period = "monthly" },
    log_fields = {},
}

os.date = function(fmt, t) return real_os_date(fmt, FROZEN_TS) end
local ok10, err10 = pcall(quota_mw10.run, ctx10)
os.date = real_os_date

ok("10. quota allows when under budget", ok10, err10)
ok("10b. quota_remaining set correctly",
    ctx10.log_fields.quota_remaining ~= nil and ctx10.log_fields.quota_remaining > 0.89)

-- ---------------------------------------------------------------------------
-- 11. quota.run skips when no budget_usd configured
-- ---------------------------------------------------------------------------
clear({"middleware.quota", "utils.budget", "storage", "state"})
spend_db = {}
package.loaded["storage"]      = storage_stub
package.loaded["state"]        = state_stub
package.loaded["utils.budget"] = budget_lib
package.loaded["core.errors"]  = errors_stub
package.loaded["utils.webhook"] = { fire = function() end }

local quota_mw11 = require("middleware.quota")
local ctx11 = {
    gateway_id = "gw-7", tenant_id = "tn-7",
    gateway_config = {},  -- no budget
    log_fields = {},
}

os.date = function(fmt, t) return real_os_date(fmt, FROZEN_TS) end
local ok11 = pcall(quota_mw11.run, ctx11)
os.date = real_os_date

ok("11. quota skips when no budget configured", ok11)

-- ---------------------------------------------------------------------------
-- 12. Previous period spend does NOT affect current-period check
-- ---------------------------------------------------------------------------
clear({"middleware.quota", "utils.budget", "storage", "state"})
spend_db = {}

-- Only last month spent (period "2026-02"), current month "2026-03" is clean
spend_db["gateway:gw-8:2026-02"] = 9999999

package.loaded["storage"]      = storage_stub
package.loaded["state"]        = state_stub
package.loaded["utils.budget"] = budget_lib
package.loaded["core.errors"]  = errors_stub
package.loaded["utils.webhook"] = { fire = function() end }

local quota_mw12 = require("middleware.quota")
local ctx12 = {
    gateway_id = "gw-8", tenant_id = "tn-8",
    gateway_config = { budget_usd = 5.0, budget_period = "monthly" },
    log_fields = {},
}

os.date = function(fmt, t) return real_os_date(fmt, FROZEN_TS) end
local ok12 = pcall(quota_mw12.run, ctx12)
os.date = real_os_date

ok("12. previous period spend does not block current period", ok12)

-- ---------------------------------------------------------------------------
-- 13. Cache hit path avoids storage.get_spend call
-- ---------------------------------------------------------------------------
clear({"middleware.quota", "utils.budget", "storage", "state"})
spend_db = {}

local get_spend_calls = 0
local storage_counting = {
    incr_spend = storage_stub.incr_spend,
    get_spend  = function(entity_type, entity_id, period)
        get_spend_calls = get_spend_calls + 1
        return spend_db[entity_type .. ":" .. entity_id .. ":" .. period] or 0
    end,
}

package.loaded["storage"]      = storage_counting
package.loaded["state"]        = state_stub
package.loaded["utils.budget"] = budget_lib
package.loaded["core.errors"]  = errors_stub
package.loaded["utils.webhook"] = { fire = function() end }

local quota_mw13 = require("middleware.quota")
local ctx13a = {
    gateway_id = "gw-9", tenant_id = "tn-9",
    gateway_config = { budget_usd = 5.0, budget_period = "monthly" },
    log_fields = {},
}
local ctx13b = {
    gateway_id = "gw-9", tenant_id = "tn-9",
    gateway_config = { budget_usd = 5.0, budget_period = "monthly" },
    log_fields = {},
}

os.date = function(fmt, t) return real_os_date(fmt, FROZEN_TS) end
pcall(quota_mw13.run, ctx13a)
local calls_after_first = get_spend_calls
pcall(quota_mw13.run, ctx13b)
os.date = real_os_date

ok("13. second call hits cache (no extra storage.get_spend)",
    get_spend_calls == calls_after_first,
    "calls=" .. get_spend_calls .. " after_first=" .. calls_after_first)

-- ---------------------------------------------------------------------------
-- 14. cost.run does not crash when tenant_id is nil
-- ---------------------------------------------------------------------------
clear({"middleware.cost", "utils.budget", "storage", "state", "observability.cost_table"})
spend_db = {}
package.loaded["storage"]                  = storage_stub
package.loaded["state"]                    = state_stub
package.loaded["observability.cost_table"] = cost_table_stub
package.loaded["utils.budget"]             = budget_lib

local cost_mw14 = require("middleware.cost")
local ctx14 = {
    provider = "openai", model = "gpt-4o",
    input_tokens = 10, output_tokens = 5,
    gateway_id = "gw-10", tenant_id = nil,  -- no tenant
    gateway_config = {}, log_fields = {},
}

os.date = function(fmt, t) return real_os_date(fmt, FROZEN_TS) end
local ok14 = pcall(cost_mw14.run, ctx14)
os.date = real_os_date

ok("14. cost.run handles nil tenant_id gracefully", ok14)
ok("14b. gateway spend still recorded",
    (spend_db["gateway:gw-10:2026-03"] or 0) > 0)

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
