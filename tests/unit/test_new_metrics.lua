-- tests/unit/test_new_metrics.lua — tests for new observability fields
-- Run with: resty tests/runner.lua tests/unit/test_new_metrics.lua

_G.ngx = {
    now    = function() return 1700000000.0 end,
    log    = function() end,
    exit   = function(s) error(s) end,
    print  = function() end,
    flush  = function() end,
    status = 200,
    header = {},
    req    = {
        read_body     = function() end,
        get_body_data = function() return nil end,
        get_headers   = function() return {} end,
    },
    var = {},
    ctx = {},
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;;" .. package.path

local function clear(names)
    for _, n in ipairs(names) do
        package.loaded[n]  = nil
        package.preload[n] = nil
    end
end

-- =========================================================================
-- upstream: upstream_attempts, fallback_provider, provider_request_id
-- =========================================================================
describe("middleware.upstream: attempt tracking and provider_request_id", function()
    clear({"middleware.upstream","providers","utils.http","core.errors","utils.json","auth.byok","state"})

    _G.ngx.print  = function() end
    _G.ngx.flush  = function() end
    _G.ngx.header = {}

    local store = {}
    package.preload["state"] = function()
        return {
            config_get = function(k) return store[k] end,
            config_set = function(k, v) store[k] = v end,
        }
    end

    package.preload["providers"] = function()
        return {
            get = function()
                return {
                    base_url      = function() return "http://mock/v1/chat" end,
                    build_headers = function() return {} end,
                    build_request = function() return '{"model":"x"}' end,
                    parse_response = function()
                        return { input_tokens = 10, output_tokens = 5,
                                 cache_creation_tokens = 0, cache_read_tokens = 0 }, nil
                    end,
                    parse_sse_chunk = function() return nil end,
                }, nil
            end,
        }
    end

    package.preload["utils.json"] = function()
        return { encode = function() return "{}" end,
                 decode = function() return {} end }
    end

    package.preload["core.errors"] = function()
        return { send = function(c) error(c) end, codes = {} }
    end

    package.preload["utils.http"] = function()
        return {
            request = function()
                return 200,
                    { ["x-request-id"] = "req-abc-123" },
                    '{"choices":[]}',
                    nil,
                    { set_keepalive = function() end }
            end,
        }
    end

    local upstream = require("middleware.upstream")

    it("sets upstream_attempts=1 on first-try success", function()
        local ctx = {
            gateway_config   = { retry_count = 0, timeout_ms = 5000, provider_base_urls = nil },
            provider         = "openai",
            model            = "gpt-4o",
            request_body     = { stream = false },
            provider_api_key = "test-key",
            fallback_chain   = {},
            start_ms         = ngx.now() * 1000,
            log_fields       = {},
        }
        upstream.run(ctx)
        assert.equal(1, ctx.upstream_attempts)
    end)

    it("sets upstream_latency_ms >= 0", function()
        local ctx = {
            gateway_config   = { retry_count = 0, timeout_ms = 5000, provider_base_urls = nil },
            provider         = "openai",
            model            = "gpt-4o",
            request_body     = { stream = false },
            provider_api_key = "test-key",
            fallback_chain   = {},
            start_ms         = ngx.now() * 1000,
            log_fields       = {},
        }
        upstream.run(ctx)
        assert.not_nil(ctx.upstream_latency_ms)
        assert.is_true(ctx.upstream_latency_ms >= 0)
    end)

    it("extracts provider_request_id from x-request-id header", function()
        local ctx = {
            gateway_config   = { retry_count = 0, timeout_ms = 5000, provider_base_urls = nil },
            provider         = "openai",
            model            = "gpt-4o",
            request_body     = { stream = false },
            provider_api_key = "test-key",
            fallback_chain   = {},
            start_ms         = ngx.now() * 1000,
            log_fields       = {},
        }
        upstream.run(ctx)
        assert.equal("req-abc-123", ctx.provider_request_id)
    end)

    it("stores avg_upstream_ms in state after success", function()
        store = {}
        local ctx = {
            gateway_config   = { retry_count = 0, timeout_ms = 5000, provider_base_urls = nil },
            provider         = "openai",
            model            = "gpt-4o",
            request_body     = { stream = false },
            provider_api_key = "test-key",
            fallback_chain   = {},
            start_ms         = ngx.now() * 1000,
            log_fields       = {},
        }
        upstream.run(ctx)
        assert.not_nil(store["avg_upstream_ms:openai:gpt-4o"])
    end)

    it("fallback_provider is nil when primary succeeds", function()
        local ctx = {
            gateway_config   = { retry_count = 0, timeout_ms = 5000, provider_base_urls = nil },
            provider         = "openai",
            model            = "gpt-4o",
            request_body     = { stream = false },
            provider_api_key = "test-key",
            fallback_chain   = {},
            start_ms         = ngx.now() * 1000,
            log_fields       = {},
        }
        upstream.run(ctx)
        assert.is_nil(ctx.fallback_provider)
    end)
end)

describe("middleware.upstream: fallback_provider set when primary fails", function()
    clear({"middleware.upstream","providers","utils.http","core.errors","utils.json","auth.byok","state"})

    _G.ngx.print  = function() end
    _G.ngx.flush  = function() end
    _G.ngx.header = {}

    local call_count = 0
    package.preload["state"] = function()
        local s = {}
        return {
            config_get = function(k) return s[k] end,
            config_set = function(k, v) s[k] = v end,
        }
    end

    package.preload["providers"] = function()
        return {
            get = function()
                return {
                    base_url      = function() return "http://mock/v1" end,
                    build_headers = function() return {} end,
                    build_request = function() return "{}" end,
                    parse_response = function()
                        return { input_tokens = 5, output_tokens = 3,
                                 cache_creation_tokens = 0, cache_read_tokens = 0 }, nil
                    end,
                    parse_sse_chunk = function() return nil end,
                }, nil
            end,
        }
    end

    package.preload["utils.json"] = function()
        return { encode = function() return "{}" end, decode = function() return {} end }
    end
    package.preload["core.errors"] = function()
        return { send = function(c) error(c) end, codes = {} }
    end
    package.preload["auth.byok"] = function()
        return { get_key = function() return "fallback-key", nil end }
    end

    package.preload["utils.http"] = function()
        return {
            request = function()
                call_count = call_count + 1
                if call_count == 1 then
                    return 500, {}, "error", nil, { set_keepalive = function() end }
                end
                return 200, { ["x-request-id"] = "fb-req" }, '{}',
                       nil, { set_keepalive = function() end }
            end,
        }
    end

    local upstream = require("middleware.upstream")

    it("sets fallback_provider when fallback is used", function()
        call_count = 0
        local ctx = {
            gateway_config   = { retry_count = 0, timeout_ms = 5000, provider_base_urls = nil },
            provider         = "openai",
            model            = "gpt-4o",
            request_body     = { stream = false },
            provider_api_key = "primary-key",
            fallback_chain   = {{ provider = "anthropic", model = "claude-haiku-4-5-20251001" }},
            gateway_id       = "gw1",
            start_ms         = ngx.now() * 1000,
            log_fields       = {},
        }
        upstream.run(ctx)
        assert.equal("anthropic", ctx.fallback_provider)
        assert.equal("claude-haiku-4-5-20251001", ctx.fallback_model)
    end)

    it("upstream_attempts=2 after one failure and one fallback success", function()
        call_count = 0
        local ctx = {
            gateway_config   = { retry_count = 0, timeout_ms = 5000, provider_base_urls = nil },
            provider         = "openai",
            model            = "gpt-4o",
            request_body     = { stream = false },
            provider_api_key = "primary-key",
            fallback_chain   = {{ provider = "anthropic", model = "claude-haiku-4-5-20251001" }},
            gateway_id       = "gw1",
            start_ms         = ngx.now() * 1000,
            log_fields       = {},
        }
        upstream.run(ctx)
        assert.equal(2, ctx.upstream_attempts)
    end)
end)

-- =========================================================================
-- quota: quota_remaining
-- =========================================================================
describe("middleware.quota: quota_remaining", function()
    clear({"middleware.quota","state","core.errors"})

    package.preload["core.errors"] = function()
        return { send = function(c) error(c) end, codes = {} }
    end

    package.preload["state"] = function()
        return {
            counter_get = function(k)
                if k == "budget:gw1" then return 250000 end  -- $0.25 spent
                return 0
            end,
        }
    end

    local quota = require("middleware.quota")

    it("sets quota_remaining = budget - spent", function()
        local ctx = {
            gateway_config = { budget_usd = 1.0 },
            gateway_id     = "gw1",
            log_fields     = {},
        }
        quota.run(ctx)
        -- spent = 250000 micro = $0.25; remaining = $0.75
        assert.not_nil(ctx.log_fields.quota_remaining)
        assert.equal(0.75, ctx.log_fields.quota_remaining)
    end)

    it("quota_remaining=0 when budget fully exhausted", function()
        clear({"middleware.quota","state","core.errors"})
        package.preload["core.errors"] = function()
            return { send = function() end, codes = {} }
        end
        package.preload["state"] = function()
            return { counter_get = function() return 1000000 end }  -- $1.00 spent
        end
        local q = require("middleware.quota")
        local ctx = {
            gateway_config = { budget_usd = 1.0 },
            gateway_id     = "gw1",
            log_fields     = {},
        }
        pcall(q.run, ctx)
        assert.equal(0, ctx.log_fields.quota_remaining)
    end)

    it("does not set quota_remaining when no budget configured", function()
        clear({"middleware.quota","state","core.errors"})
        package.preload["core.errors"] = function()
            return { send = function() end, codes = {} }
        end
        package.preload["state"] = function()
            return { counter_get = function() return 0 end }
        end
        local q = require("middleware.quota")
        local ctx = {
            gateway_config = {},
            gateway_id     = "gw1",
            log_fields     = {},
        }
        q.run(ctx)
        assert.is_nil(ctx.log_fields.quota_remaining)
    end)
end)

-- =========================================================================
-- cache_check: saved_cost_usd and saved_latency_ms on cache hit
-- =========================================================================
describe("cache_check: saved_cost_usd and saved_latency_ms", function()
    clear({"middleware.cache_check","cache.key","state","utils.json","utils.request"})

    local avg_store = { ["avg_upstream_ms:openai:gpt-4o"] = "123" }

    package.preload["cache.key"] = function()
        return { build = function() return "testkey" end }
    end

    package.preload["state"] = function()
        local cache = { testkey = '{"body":"{}", "cost_usd": 0.0015}' }
        return {
            cache_get  = function(k) return cache[k] end,
            cache_set  = function() end,
            config_get = function(k) return avg_store[k] end,
        }
    end

    package.preload["utils.request"] = function()
        return { read_body = function()
            return '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'
        end }
    end

    package.preload["utils.json"] = function()
        local M = {}
        function M.decode(s)
            if s:find("gpt%-4o") then
                return { model = "gpt-4o", messages = {{ role="user", content="hi" }} }
            end
            if s:find("cost_usd") then
                return { body = "{}", cost_usd = 0.0015 }
            end
            return nil
        end
        function M.encode(v) return "{}" end
        return M
    end

    local printed = {}
    _G.ngx.print = function(s) printed[#printed+1] = s end

    local mw = require("middleware.cache_check")

    it("sets saved_cost_usd from cache entry on hit", function()
        local ctx = {
            gateway_config = { cache_ttl = 60 },
            provider       = "openai",
            model          = nil,
            log_fields     = {},
        }
        pcall(mw.run, ctx)
        assert.not_nil(ctx.log_fields.saved_cost_usd)
        assert.equal(0.0015, ctx.log_fields.saved_cost_usd)
    end)

    it("sets saved_latency_ms from state avg on hit", function()
        local ctx = {
            gateway_config = { cache_ttl = 60 },
            provider       = "openai",
            model          = nil,
            log_fields     = {},
        }
        pcall(mw.run, ctx)
        assert.equal(123, ctx.log_fields.saved_latency_ms)
    end)
end)

-- =========================================================================
-- logger: request_size_bytes and upstream fields emitted
-- =========================================================================
describe("observability.logger: new fields in emitted record", function()
    clear({"observability.logger","storage","utils.json","utils.uuid"})

    local logged = nil

    package.preload["storage"] = function()
        return { insert_log = function(f) logged = f; return nil end }
    end

    package.preload["utils.uuid"] = function()
        return { v4 = function() return "test-uuid" end }
    end

    package.preload["utils.json"] = function()
        local M = {}
        function M.encode(v) return "{}" end
        function M.decode(s) return {} end
        return M
    end

    local logger = require("observability.logger")

    it("emits request_size_bytes from raw_request_body length", function()
        logged = nil
        local ctx = {
            skip_log          = false,
            gateway_config    = { log_payloads = false },
            raw_request_body  = '{"model":"gpt-4o"}',  -- 18 bytes
            request_id        = "r1",
            tenant_id         = "t1",
            gateway_id        = "g1",
            provider          = "openai",
            model             = "gpt-4o",
            provider_status   = 200,
            cache_hit         = false,
            input_tokens      = 10,
            output_tokens     = 5,
            cost_usd          = 0.001,
            start_ms          = ngx.now() * 1000,
            meta              = {},
            log_fields        = {},
            upstream_latency_ms    = 250,
            upstream_attempts      = 1,
            fallback_provider      = nil,
            fallback_model         = nil,
            provider_request_id    = "prov-req-1",
            time_to_first_token_ms = nil,
        }
        logger.emit(ctx)
        assert.not_nil(logged)
        assert.equal(18, logged.request_size_bytes)
    end)

    it("emits upstream_latency_ms", function()
        assert.equal(250, logged.upstream_latency_ms)
    end)

    it("emits upstream_attempts", function()
        assert.equal(1, logged.upstream_attempts)
    end)

    it("emits provider_request_id", function()
        assert.equal("prov-req-1", logged.provider_request_id)
    end)
end)
