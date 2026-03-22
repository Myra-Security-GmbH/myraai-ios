-- tests/unit/test_routing_middleware.lua
-- Tests for middleware/routing.lua, including per-rule timeout_ms propagation.
-- Run with: resty tests/runner.lua tests/unit/test_routing_middleware.lua

_G.ngx = {
    now    = function() return 1700000000.0 end,
    log    = function() end,
    var    = {},
    shared = {},
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- Fixture rules table — tests replace this before reloading the engine
local _rules = {}

-- Stubs
for _, n in ipairs({
    "middleware.routing", "routing.engine", "routing.load_balance",
    "storage", "state", "utils.json",
}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["storage"] = function()
    return { init = function() end, get_routing_rules = function() return _rules end }
end

package.preload["state"] = function()
    local store = {}
    return {
        config_get = function(k)       return store[k] end,
        config_set = function(k, v, _) store[k] = v    end,
    }
end

-- Helpers to reload modules between tests (rules fixture changes)
local function reload()
    package.loaded["routing.engine"]   = nil
    package.loaded["middleware.routing"] = nil
    return require("middleware.routing")
end

local function make_ctx(model)
    return {
        gateway_id   = "gw-test",
        provider     = "openai",
        model        = model,
        request_body = { model = model },
        meta         = {},
    }
end

-- ─── basic routing ────────────────────────────────────────────────────────────

describe("middleware.routing: provider/model dispatch", function()
    -- Must clear state between tests: routing.engine caches rules in the state
    -- dict keyed by gateway_id.  Stale cache causes subsequent tests to pick
    -- up the previous test's rules even after _rules is replaced.
    before_each(function()
        package.loaded["routing.engine"]     = nil
        package.loaded["middleware.routing"] = nil
        package.loaded["state"]              = nil  -- flush rule cache
    end)

    it("sets ctx.provider and ctx.model from matched rule", function()
        _rules = {{
            priority   = 10,
            conditions = {{ field = "model", op = "eq", value = "gpt-4o" }},
            actions    = { provider = "anthropic", model = "claude-haiku", fallbacks = {} },
        }}
        local routing = reload()
        local ctx = make_ctx("gpt-4o")
        routing.run(ctx)
        assert.equal("anthropic",    ctx.provider)
        assert.equal("claude-haiku", ctx.model)
    end)

    it("also updates request_body.model to the routed model", function()
        _rules = {{
            priority   = 10,
            conditions = {{ field = "model", op = "eq", value = "input-model" }},
            actions    = { provider = "openai", model = "output-model", fallbacks = {} },
        }}
        local routing = reload()
        local ctx = make_ctx("input-model")
        routing.run(ctx)
        assert.equal("output-model", ctx.request_body.model)
    end)

    it("builds fallback_chain from actions.fallbacks", function()
        _rules = {{
            priority   = 10,
            conditions = {{ field = "model", op = "eq", value = "m" }},
            actions    = {
                provider  = "openai",
                model     = "gpt-4o",
                fallbacks = {
                    { provider = "anthropic", model = "claude-haiku" },
                    { provider = "groq",      model = "llama3"       },
                },
            },
        }}
        local routing = reload()
        local ctx = make_ctx("m")
        routing.run(ctx)
        assert.equal(2,            #ctx.fallback_chain)
        assert.equal("anthropic",  ctx.fallback_chain[1].provider)
        assert.equal("groq",       ctx.fallback_chain[2].provider)
    end)

    it("sets empty fallback_chain when no rule matches", function()
        _rules = {}
        local routing = reload()
        local ctx = make_ctx("unknown-model")
        routing.run(ctx)
        assert.equal(0, #ctx.fallback_chain)
    end)

    it("leaves provider/model unchanged when no rule matches", function()
        _rules = {}
        local routing = reload()
        local ctx = make_ctx("my-model")
        routing.run(ctx)
        assert.equal("openai",   ctx.provider)
        assert.equal("my-model", ctx.model)
    end)
end)

-- ─── per-rule timeout_ms ──────────────────────────────────────────────────────

describe("middleware.routing: per-rule timeout_ms", function()
    before_each(function()
        package.loaded["routing.engine"]     = nil
        package.loaded["middleware.routing"] = nil
        package.loaded["state"]              = nil
    end)

    it("sets ctx.rule_timeout_ms from actions.timeout_ms (number)", function()
        _rules = {{
            priority   = 10,
            conditions = {{ field = "model", op = "eq", value = "slow" }},
            actions    = { provider = "openai", model = "gpt-4o", timeout_ms = 5000, fallbacks = {} },
        }}
        local routing = reload()
        local ctx = make_ctx("slow")
        routing.run(ctx)
        assert.equal(5000, ctx.rule_timeout_ms)
    end)

    it("converts string timeout_ms to number", function()
        _rules = {{
            priority   = 10,
            conditions = {{ field = "model", op = "eq", value = "any" }},
            actions    = { provider = "openai", model = "gpt-4o", timeout_ms = "8000", fallbacks = {} },
        }}
        local routing = reload()
        local ctx = make_ctx("any")
        routing.run(ctx)
        assert.equal(8000, ctx.rule_timeout_ms)
        assert.equal("number", type(ctx.rule_timeout_ms))
    end)

    it("does not set ctx.rule_timeout_ms when actions has no timeout_ms", function()
        _rules = {{
            priority   = 10,
            conditions = {{ field = "model", op = "eq", value = "fast" }},
            actions    = { provider = "openai", model = "gpt-4o", fallbacks = {} },
        }}
        local routing = reload()
        local ctx = make_ctx("fast")
        routing.run(ctx)
        assert.is_nil(ctx.rule_timeout_ms)
    end)

    it("does not set ctx.rule_timeout_ms when no rule matches", function()
        _rules = {}
        local routing = reload()
        local ctx = make_ctx("unmatched")
        routing.run(ctx)
        assert.is_nil(ctx.rule_timeout_ms)
    end)

    it("timeout_ms = 0 is propagated (Lua treats 0 as truthy)", function()
        _rules = {{
            priority   = 10,
            conditions = {{ field = "model", op = "eq", value = "instant" }},
            actions    = { provider = "openai", model = "gpt-4o", timeout_ms = 0, fallbacks = {} },
        }}
        local routing = reload()
        local ctx = make_ctx("instant")
        routing.run(ctx)
        -- In Lua, `if 0 then` is truthy, so timeout_ms=0 is propagated.
        assert.equal(0, ctx.rule_timeout_ms)
    end)

    it("large timeout (120000 ms) is preserved exactly", function()
        _rules = {{
            priority   = 10,
            conditions = {{ field = "model", op = "eq", value = "long" }},
            actions    = { provider = "openai", model = "gpt-4o", timeout_ms = 120000, fallbacks = {} },
        }}
        local routing = reload()
        local ctx = make_ctx("long")
        routing.run(ctx)
        assert.equal(120000, ctx.rule_timeout_ms)
    end)
end)

-- ─── condition operators ──────────────────────────────────────────────────────

describe("middleware.routing: condition operators", function()
    before_each(function()
        package.loaded["routing.engine"]     = nil
        package.loaded["middleware.routing"] = nil
        package.loaded["state"]              = nil
    end)

    it("'prefix' op matches model prefix", function()
        _rules = {{
            priority   = 1,
            conditions = {{ field = "model", op = "prefix", value = "gpt" }},
            actions    = { provider = "openai", model = "gpt-4o-mini", fallbacks = {} },
        }}
        local routing = reload()
        local ctx = make_ctx("gpt-4-turbo")
        routing.run(ctx)
        assert.equal("openai",     ctx.provider)
        assert.equal("gpt-4o-mini", ctx.model)
    end)

    it("'neq' op routes when model does NOT match", function()
        _rules = {{
            priority   = 1,
            conditions = {{ field = "model", op = "neq", value = "gpt-4o" }},
            actions    = { provider = "anthropic", model = "claude-haiku", fallbacks = {} },
        }}
        local routing = reload()
        local ctx = make_ctx("gpt-3.5-turbo")
        routing.run(ctx)
        assert.equal("anthropic", ctx.provider)
    end)

    it("'contains' op matches substring", function()
        _rules = {{
            priority   = 1,
            conditions = {{ field = "model", op = "contains", value = "claude" }},
            actions    = { provider = "anthropic", model = "claude-haiku", fallbacks = {} },
        }}
        local routing = reload()
        local ctx = make_ctx("my-claude-wrapper")
        routing.run(ctx)
        assert.equal("anthropic", ctx.provider)
    end)
end)
