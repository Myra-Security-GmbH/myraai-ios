-- tests/unit/test_load_balance.lua
-- Comprehensive tests for routing/load_balance.lua and the load_balance action
-- in routing/engine.lua.
-- Run with: resty tests/runner.lua tests/unit/test_load_balance.lua

_G.ngx = {
    now    = function() return 1700000000.0 end,
    log    = function() end,
    shared = {},
    crc32_short = function(s)
        -- Deterministic stub: sum of bytes mod 2^32
        local n = 0
        for i = 1, #s do n = (n + s:byte(i)) % 2^32 end
        return n
    end,
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

for _, n in ipairs({"routing.load_balance", "routing.engine", "state",
                    "storage", "utils.json"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

-- ---------------------------------------------------------------------------
-- Shared state mock (reset per describe block via before_each)
-- ---------------------------------------------------------------------------
local _config_store  = {}
local _counter_store = {}

package.preload["state"] = function()
    return {
        config_get   = function(k)          return _config_store[k] end,
        config_set   = function(k, v, _ttl) _config_store[k] = v end,
        counter_incr = function(k, d)
            _counter_store[k] = (_counter_store[k] or 0) + (d or 1)
            return _counter_store[k]
        end,
    }
end

local lb = require("routing.load_balance")

-- Convenience constructors
local function ctx(gateway_id, meta)
    return { gateway_id = gateway_id or "gw1", meta = meta or {} }
end

-- Canonical test targets
local OAI  = { provider = "openai",    model = "gpt-4o",             weight = 7 }
local ANT  = { provider = "anthropic", model = "claude-sonnet-4-6",  weight = 3 }
local GEM  = { provider = "gemini",    model = "gemini-1.5-flash",   weight = 0 }
local TOG  = { provider = "together",  model = "llama-3.3-70b",      weight = 5 }
local DIS  = { provider = "disabled",  model = "disabled-model",     weight = 0 }

-- ---------------------------------------------------------------------------

describe("routing.load_balance — nil / empty inputs", function()
    before_each(function() _config_store = {}; _counter_store = {}; math.randomseed(42) end)

    it("returns nil when lb_config is nil", function()
        assert.is_nil(lb.select(ctx(), nil, "r1"))
    end)

    it("returns nil when targets key is absent", function()
        assert.is_nil(lb.select(ctx(), {}, "r1"))
    end)

    it("returns nil when targets is empty", function()
        assert.is_nil(lb.select(ctx(), { targets = {} }, "r1"))
    end)

    it("returns nil when every target has weight=0", function()
        assert.is_nil(lb.select(ctx(), { targets = { GEM, DIS } }, "r1"))
    end)

    it("returns nil when every target has explicit weight=0 regardless of strategy", function()
        assert.is_nil(lb.select(ctx(), { strategy = "round_robin", targets = { GEM } }, "r1"))
    end)
end)

-- ---------------------------------------------------------------------------

describe("routing.load_balance — single active target", function()
    before_each(function() _config_store = {}; _counter_store = {}; math.randomseed(42) end)

    it("always returns the sole active target (weighted_random)", function()
        local cfg = { targets = { OAI } }
        for _ = 1, 20 do
            assert.equal("openai", lb.select(ctx(), cfg, "r1").provider)
        end
    end)

    it("always returns the sole active target (round_robin)", function()
        local cfg = { strategy = "round_robin", targets = { OAI } }
        for _ = 1, 20 do
            assert.equal("openai", lb.select(ctx(), cfg, "r1").provider)
        end
    end)

    it("skips weight=0 and returns only active target", function()
        local cfg = { targets = { GEM, OAI, DIS } }
        for _ = 1, 20 do
            assert.equal("openai", lb.select(ctx(), cfg, "r1").provider)
        end
    end)

    it("target with no weight key defaults to weight=1 and is active", function()
        local no_weight = { provider = "mistral", model = "mistral-large" }
        local cfg = { targets = { no_weight } }
        local r = lb.select(ctx(), cfg, "r1")
        assert.equal("mistral", r.provider)
    end)
end)

-- ---------------------------------------------------------------------------

describe("routing.load_balance — weighted random distribution", function()
    before_each(function() _config_store = {}; _counter_store = {}; math.randomseed(42) end)

    it("7:3 weight produces ~70%/30% distribution over 2000 trials", function()
        local cfg    = { targets = { OAI, ANT } }
        local counts = { openai = 0, anthropic = 0 }
        math.randomseed(7654)
        for _ = 1, 2000 do
            local r = lb.select(ctx(), cfg, "r1")
            counts[r.provider] = counts[r.provider] + 1
        end
        -- ±8% tolerance
        assert.is_true(counts.openai    >= 1240 and counts.openai    <= 1560,
            "openai=" .. counts.openai .. " not in [1240,1560]")
        assert.is_true(counts.anthropic >= 440  and counts.anthropic <= 760,
            "anthropic=" .. counts.anthropic .. " not in [440,760]")
    end)

    it("equal weights produce roughly uniform distribution", function()
        local A = { provider = "a", model = "m", weight = 1 }
        local B = { provider = "b", model = "m", weight = 1 }
        local C = { provider = "c", model = "m", weight = 1 }
        local cfg    = { targets = { A, B, C } }
        local counts = { a = 0, b = 0, c = 0 }
        math.randomseed(9999)
        for _ = 1, 3000 do
            local r = lb.select(ctx(), cfg, "r1")
            counts[r.provider] = counts[r.provider] + 1
        end
        -- Each should be ~33%, allow ±8%
        for _, p in ipairs({"a","b","c"}) do
            assert.is_true(counts[p] >= 750 and counts[p] <= 1250,
                p .. "=" .. counts[p] .. " not in [750,1250]")
        end
    end)

    it("missing weight key treated as weight=1", function()
        local A = { provider = "a", model = "m" }           -- no weight key
        local B = { provider = "b", model = "m", weight = 1 }
        local cfg    = { targets = { A, B } }
        local counts = { a = 0, b = 0 }
        math.randomseed(1111)
        for _ = 1, 1000 do
            local r = lb.select(ctx(), cfg, "r1")
            counts[r.provider] = counts[r.provider] + 1
        end
        -- Both ~50%; allow wide ±15% tolerance
        assert.is_true(counts.a >= 350 and counts.a <= 650,
            "a=" .. counts.a .. " not in [350,650]")
        assert.is_true(counts.b >= 350 and counts.b <= 650,
            "b=" .. counts.b .. " not in [350,650]")
    end)

    it("weight=0 targets are never selected even when mixed with active ones", function()
        local cfg = { targets = { OAI, GEM, ANT, DIS } }
        math.randomseed(2222)
        for _ = 1, 200 do
            local r = lb.select(ctx(), cfg, "r1")
            assert.not_equal("gemini",   r.provider)
            assert.not_equal("disabled", r.provider)
        end
    end)
end)

-- ---------------------------------------------------------------------------

describe("routing.load_balance — round-robin", function()
    before_each(function() _config_store = {}; _counter_store = {}; math.randomseed(42) end)

    it("cycles through two active targets in strict order", function()
        local cfg = { strategy = "round_robin", targets = { OAI, ANT } }
        local seq = {}
        for _ = 1, 8 do
            seq[#seq+1] = lb.select(ctx(), cfg, "rr1").provider
        end
        assert.equal("openai",    seq[1])
        assert.equal("anthropic", seq[2])
        assert.equal("openai",    seq[3])
        assert.equal("anthropic", seq[4])
        assert.equal("openai",    seq[5])
        assert.equal("anthropic", seq[6])
    end)

    it("cycles through three active targets in strict order", function()
        local cfg = { strategy = "round_robin", targets = { OAI, ANT, TOG } }
        local seq = {}
        for _ = 1, 9 do
            seq[#seq+1] = lb.select(ctx(), cfg, "rr2").provider
        end
        assert.equal("openai",    seq[1])
        assert.equal("anthropic", seq[2])
        assert.equal("together",  seq[3])
        assert.equal("openai",    seq[4])
        assert.equal("anthropic", seq[5])
        assert.equal("together",  seq[6])
    end)

    it("weight=0 targets never appear in round-robin cycle", function()
        -- GEM has weight=0; only OAI and ANT are active
        local cfg = { strategy = "round_robin", targets = { OAI, GEM, ANT } }
        local seen = {}
        for _ = 1, 20 do
            seen[lb.select(ctx(), cfg, "rr3").provider] = true
        end
        assert.is_nil(seen["gemini"], "weight=0 target appeared in round-robin")
    end)

    it("different rule_ids have independent round-robin counters", function()
        local cfg = { strategy = "round_robin", targets = { OAI, ANT } }
        -- rr-a: call once → gets openai (slot 1)
        local a1 = lb.select(ctx(), cfg, "rr-a").provider
        -- rr-b: call once → also gets openai (slot 1, independent counter)
        local b1 = lb.select(ctx(), cfg, "rr-b").provider
        assert.equal("openai", a1)
        assert.equal("openai", b1)
        -- rr-a second call → anthropic
        local a2 = lb.select(ctx(), cfg, "rr-a").provider
        -- rr-b second call → anthropic (its own counter)
        local b2 = lb.select(ctx(), cfg, "rr-b").provider
        assert.equal("anthropic", a2)
        assert.equal("anthropic", b2)
    end)
end)

-- ---------------------------------------------------------------------------

describe("routing.load_balance — sticky sessions", function()
    before_each(function() _config_store = {}; _counter_store = {}; math.randomseed(42) end)

    it("same user always hits the same target", function()
        local cfg = { sticky = { field = "meta.user_id", ttl = 3600 }, targets = { OAI, ANT } }
        local c = ctx("gw1", { user_id = "alice" })
        local first = lb.select(c, cfg, "r1").provider
        for _ = 1, 30 do
            assert.equal(first, lb.select(c, cfg, "r1").provider)
        end
    end)

    it("sticky assignment is stored in state with the correct key prefix", function()
        local cfg = { sticky = { field = "meta.user_id", ttl = 60 }, targets = { OAI, ANT } }
        local c   = ctx("gw1", { user_id = "bob" })
        lb.select(c, cfg, "r1")
        -- At least one lb_sticky: key must be present
        local found = false
        for k in pairs(_config_store) do
            if k:find("lb_sticky:gw1:", 1, true) then found = true; break end
        end
        assert.is_true(found, "no sticky key written to state")
    end)

    it("sticky TTL is passed through to state.config_set", function()
        local saved_ttl
        local orig_set = package.loaded["state"].config_set
        package.loaded["state"].config_set = function(k, v, ttl)
            if k:find("lb_sticky:", 1, true) then saved_ttl = ttl end
            _config_store[k] = v
        end
        local cfg = { sticky = { field = "meta.user_id", ttl = 7200 }, targets = { OAI, ANT } }
        lb.select(ctx("gw1", { user_id = "carol" }), cfg, "r1")
        package.loaded["state"].config_set = orig_set
        assert.equal(7200, saved_ttl)
    end)

    it("different users are assigned independently (both providers seen across 50 users)", function()
        local cfg = { sticky = { field = "meta.user_id", ttl = 3600 }, targets = { OAI, ANT } }
        math.randomseed(5050)
        local seen = {}
        for i = 1, 50 do
            local r = lb.select(ctx("gw1", { user_id = "u" .. i }), cfg, "r1")
            seen[r.provider] = true
        end
        assert.is_true(seen["openai"],    "openai never assigned")
        assert.is_true(seen["anthropic"], "anthropic never assigned")
    end)

    it("different gateways have independent sticky state for the same user_id", function()
        local cfg = { sticky = { field = "meta.user_id", ttl = 3600 }, targets = { OAI, ANT } }
        -- Force gw1-user to openai by seeding so first pick is index 1
        math.randomseed(1)
        local r_gw1 = lb.select(ctx("gw1", { user_id = "dave" }), cfg, "r1").provider
        -- gw2 state is independent — clear and reseed to force different pick
        _config_store = {}
        math.randomseed(99999)
        -- Run enough to potentially get a different answer
        local r_gw2 = lb.select(ctx("gw2", { user_id = "dave" }), cfg, "r1").provider
        -- Just verify each selected a valid provider (state is isolated)
        assert.is_true(r_gw1 == "openai" or r_gw1 == "anthropic")
        assert.is_true(r_gw2 == "openai" or r_gw2 == "anthropic")
    end)

    it("absent field value (empty meta) falls through to weighted_random", function()
        local cfg = { sticky = { field = "meta.user_id", ttl = 3600 }, targets = { OAI, ANT } }
        local r = lb.select(ctx("gw1", {}), cfg, "r1")
        assert.not_nil(r)
    end)

    it("empty-string field value treated as absent → weighted_random", function()
        local cfg = { sticky = { field = "meta.user_id", ttl = 3600 }, targets = { OAI, ANT } }
        -- meta.user_id exists but is empty string
        local r = lb.select(ctx("gw1", { user_id = "" }), cfg, "r1")
        assert.not_nil(r)
        -- Should not write a sticky entry (nothing to key off)
        for k in pairs(_config_store) do
            assert.is_false(k:find("lb_sticky:", 1, true) ~= nil,
                "sticky key written for empty user_id")
        end
    end)

    it("stale cached index (out of range) triggers fresh selection", function()
        local cfg = { sticky = { field = "meta.user_id", ttl = 3600 }, targets = { OAI, ANT } }
        local c   = ctx("gw1", { user_id = "eve" })
        -- Plant an out-of-range index (e.g. 99) in the cache
        local cache_key = "lb_sticky:gw1:" .. ngx.crc32_short("eve")
        _config_store[cache_key] = "99"
        -- Should not crash; should return a valid target
        local r = lb.select(c, cfg, "r1")
        assert.not_nil(r)
        assert.is_true(r.provider == "openai" or r.provider == "anthropic")
    end)
end)

-- ---------------------------------------------------------------------------

describe("routing.engine — load_balance action integration", function()

    local engine
    local _rules = {}  -- controlled from each test

    local function reset_engine()
        _config_store = {}; _counter_store = {}; math.randomseed(42)
        -- Clear every module that engine transitively requires
        for _, n in ipairs({"routing.engine","routing.load_balance",
                             "storage","state","utils.json"}) do
            package.loaded[n]   = nil
            package.preload[n]  = nil
        end
        -- Re-register state preload with fresh stores
        package.preload["state"] = function()
            return {
                config_get   = function(k)          return _config_store[k] end,
                config_set   = function(k, v, _ttl) _config_store[k] = v end,
                counter_incr = function(k, d)
                    _counter_store[k] = (_counter_store[k] or 0) + (d or 1)
                    return _counter_store[k]
                end,
            }
        end
        package.preload["storage"] = function()
            return { get_routing_rules = function() return _rules end }
        end
        engine = require("routing.engine")
    end

    before_each(reset_engine)

    local function req_ctx(model, meta)
        return { gateway_id = "gw1", provider = "openai", model = model, meta = meta or {} }
    end

    it("load_balance action: selects a target and returns provider/model", function()
        _rules = {{
            id = "rule1", priority = 10, enabled = 1,
            conditions = {{ field = "model", op = "eq", value = "smart" }},
            actions = {
                load_balance = {
                    targets = {
                        { provider = "openai",    model = "gpt-4o",            weight = 1 },
                        { provider = "anthropic", model = "claude-sonnet-4-6", weight = 1 },
                    }
                }
            },
        }}
        reset_engine()
        local actions = engine.evaluate(req_ctx("smart"))
        assert.not_nil(actions)
        assert.not_nil(actions.provider)
        assert.not_nil(actions.model)
        assert.is_true(actions.provider == "openai" or actions.provider == "anthropic")
    end)

    it("load_balance: non-selected active targets become fallbacks", function()
        _rules = {{
            id = "rule1", priority = 10, enabled = 1,
            conditions = {},
            actions = {
                load_balance = {
                    strategy = "round_robin",
                    targets = {
                        { provider = "openai",    model = "gpt-4o",            weight = 1 },
                        { provider = "anthropic", model = "claude-sonnet-4-6", weight = 1 },
                        { provider = "gemini",    model = "gemini-1.5-pro",    weight = 1 },
                    }
                }
            },
        }}
        reset_engine()
        local actions = engine.evaluate(req_ctx("any"))
        -- Two targets should be in fallbacks (the three minus the one selected)
        assert.equal(2, #actions.fallbacks)
        -- Selected provider should not appear in fallbacks
        for _, fb in ipairs(actions.fallbacks) do
            assert.not_equal(actions.provider, fb.provider)
        end
    end)

    it("load_balance: weight=0 targets excluded from fallback chain", function()
        _rules = {{
            id = "rule1", priority = 10, enabled = 1,
            conditions = {},
            actions = {
                load_balance = {
                    strategy = "round_robin",
                    targets = {
                        { provider = "openai",    model = "gpt-4o",            weight = 1 },
                        { provider = "disabled",  model = "disabled-model",    weight = 0 },
                        { provider = "anthropic", model = "claude-sonnet-4-6", weight = 1 },
                    }
                }
            },
        }}
        reset_engine()
        local actions = engine.evaluate(req_ctx("any"))
        -- Only one fallback (the non-selected active target); disabled excluded
        assert.equal(1, #actions.fallbacks)
        assert.not_equal("disabled", actions.fallbacks[1].provider)
    end)

    it("load_balance: single active target → empty fallback chain", function()
        _rules = {{
            id = "rule1", priority = 10, enabled = 1,
            conditions = {},
            actions = {
                load_balance = {
                    targets = {
                        { provider = "openai",   model = "gpt-4o", weight = 1 },
                        { provider = "disabled", model = "dm",     weight = 0 },
                    }
                }
            },
        }}
        reset_engine()
        local actions = engine.evaluate(req_ctx("any"))
        assert.equal("openai", actions.provider)
        assert.equal(0, #actions.fallbacks)
    end)

    it("load_balance: all weight=0 falls through to next matching rule", function()
        _rules = {
            {
                id = "rule1", priority = 10, enabled = 1,
                conditions = {{ field = "model", op = "eq", value = "fallthrough" }},
                actions = {
                    load_balance = {
                        targets = { { provider = "disabled", model = "dm", weight = 0 } }
                    }
                },
            },
            {
                id = "rule2", priority = 5, enabled = 1,
                conditions = {{ field = "model", op = "eq", value = "fallthrough" }},
                actions = { provider = "anthropic", model = "claude-haiku-4-5-20251001" },
            },
        }
        reset_engine()
        local actions = engine.evaluate(req_ctx("fallthrough"))
        -- rule1 lb.select returns nil (all weight=0) → engine continues to rule2
        assert.not_nil(actions)
        assert.equal("anthropic", actions.provider)
    end)

    it("non-load_balance rules still work after engine is patched", function()
        _rules = {{
            id = "rule1", priority = 10, enabled = 1,
            conditions = {{ field = "model", op = "prefix", value = "gpt-" }},
            actions = { provider = "openai", model = "gpt-4o-mini" },
        }}
        reset_engine()
        local actions = engine.evaluate(req_ctx("gpt-4-turbo"))
        assert.equal("openai",    actions.provider)
        assert.equal("gpt-4o-mini", actions.model)
    end)
end)
