-- tests/unit/test_upstream_retry.lua
-- Tests for upstream.lua: exponential backoff, 429 retry, per-rule timeout_ms.
-- Run with: resty tests/runner.lua tests/unit/test_upstream_retry.lua

-- ─── ngx stub ────────────────────────────────────────────────────────────────

local _sleep_calls  = {}
local _print_calls  = {}
local _log_calls    = {}
local _now_val      = 1700000000.0

_G.ngx = {
    now          = function() return _now_val end,
    log          = function(_, ...) _log_calls[#_log_calls + 1] = table.concat({...}) end,
    sleep        = function(s) _sleep_calls[#_sleep_calls + 1] = s end,
    print        = function(s) _print_calls[#_print_calls + 1] = s end,
    flush        = function() end,
    exit         = function(code) error("ngx.exit(" .. tostring(code) .. ")") end,
    status       = 200,
    header       = {},
    headers_sent = false,
    ERR = 0, WARN = 1, INFO = 2,
    req = { read_body = function() end, get_uri_args = function() return {} end,
            get_headers = function() return {} end },
    var = {},
    ctx = {},
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- ─── module stubs ─────────────────────────────────────────────────────────────

-- Track http_util call count and control responses
local _http_responses = {}   -- queue; each entry is { status, headers, body, err }
local _http_calls     = 0

local function reset()
    _sleep_calls  = {}
    _print_calls  = {}
    _log_calls    = {}
    _http_calls   = 0
    _http_responses = {}
    _now_val = 1700000000.0
    ngx.status = 200
    ngx.header = {}
    ngx.headers_sent = false
end

local function push_resp(status, headers, body)
    _http_responses[#_http_responses + 1] = { status = status, headers = headers or {}, body = body or "" }
end

for _, n in ipairs({
    "middleware.upstream", "utils.http", "providers", "core.errors",
    "utils.json", "state", "utils.thinking", "utils.trace",
    "core.circuit_breaker", "auth.byok",
}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

-- http_util stub — pops from _http_responses queue
package.preload["utils.http"] = function()
    return {
        request = function(opts)
            _http_calls = _http_calls + 1
            local r = table.remove(_http_responses, 1)
            if not r then return nil, nil, nil, "no more responses", nil end
            return r.status, r.headers, r.body, nil, {
                set_keepalive = function() end,
            }
        end,
    }
end

-- providers stub — minimal provider that always builds a valid request
package.preload["providers"] = function()
    local provider_mod = {
        base_url      = function() return "http://mock-provider/v1/chat" end,
        build_headers = function() return {} end,
        build_request = function() return '{"model":"gpt-4o"}' end,
        parse_response = function(body)
            return { content = "ok", input_tokens = 10, output_tokens = 20 }, nil
        end,
        parse_sse_chunk = function() return nil end,
    }
    return {
        get = function(name)
            return provider_mod, nil
        end,
    }
end

package.preload["core.errors"] = function()
    return {
        send = function(code, msg)
            error("errors.send: " .. tostring(code) .. " " .. tostring(msg))
        end,
    }
end

package.preload["utils.json"] = function()
    return require("cjson")
end

local _config_store = {}
package.preload["state"] = function()
    return {
        config_get = function(k)       return _config_store[k] end,
        config_set = function(k, v, _) _config_store[k] = v    end,
    }
end

package.preload["utils.thinking"] = function()
    return { strip = function(s, state) return s, state end }
end

package.preload["utils.trace"] = function()
    return {
        step = function() end,
        done = function() end,
    }
end

-- circuit breaker: always allow
package.preload["core.circuit_breaker"] = function()
    return {
        check          = function() return "allow" end,
        record_success = function() end,
        record_failure = function() end,
    }
end

-- byok: always returns a key
package.preload["auth.byok"] = function()
    return { get_key = function() return "sk-test", nil end }
end

local upstream = require("middleware.upstream")

-- ─── helpers ──────────────────────────────────────────────────────────────────

local function make_ctx(overrides)
    local ctx = {
        gateway_id     = "gw-test",
        tenant_id      = "t1",
        request_id     = "req-1",
        provider       = "openai",
        model          = "gpt-4o",
        provider_api_key = "sk-test",
        start_ms       = math.floor(ngx.now() * 1000),
        fallback_chain = {},
        request_body   = { model = "gpt-4o", stream = false },
        is_compat      = false,
        gateway_config = { timeout_ms = 10000, retry_count = 2 },
        log_fields     = {},
    }
    for k, v in pairs(overrides or {}) do ctx[k] = v end
    return ctx
end

local function reload_upstream()
    package.loaded["middleware.upstream"] = nil
    return require("middleware.upstream")
end

-- ─── 429 retry behaviour ──────────────────────────────────────────────────────

describe("upstream.run: 429 is retried instead of passed through", function()

    before_each(function()
        reset()
        upstream = reload_upstream()
    end)

    it("retries once after a 429 and succeeds on second call", function()
        push_resp(429, {}, '{"error":"rate limited"}')
        push_resp(200, {}, '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":10,"completion_tokens":20}}')

        local ctx = make_ctx({ gateway_config = { timeout_ms = 5000, retry_count = 1 } })
        upstream.run(ctx)

        assert.equal(2,   _http_calls,   "should have called http twice (1 retry)")
        assert.equal(200, ctx.provider_status)
    end)

    it("sleeps between the 429 and the retry", function()
        push_resp(429, {}, "rate limited")
        push_resp(200, {}, '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}')

        local ctx = make_ctx({ gateway_config = { timeout_ms = 5000, retry_count = 1 } })
        upstream.run(ctx)

        assert.equal(1, #_sleep_calls, "backoff_sleep should be called once for the retry")
        assert.is_true(_sleep_calls[1] > 0, "sleep duration must be positive")
    end)

    it("uses Retry-After-Ms header as the sleep duration", function()
        -- provider signals: wait 2000 ms
        push_resp(429, { ["retry-after-ms"] = "2000" }, "rate limited")
        push_resp(200, {}, '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}')

        local ctx = make_ctx({ gateway_config = { timeout_ms = 5000, retry_count = 1 } })
        upstream.run(ctx)

        assert.equal(1, #_sleep_calls)
        -- 2000ms = 2s; ngx.sleep receives seconds
        assert.equal(2.0, _sleep_calls[1])
    end)

    it("uses Retry-After (seconds) header when present", function()
        push_resp(429, { ["retry-after"] = "3" }, "rate limited")
        push_resp(200, {}, '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}')

        local ctx = make_ctx({ gateway_config = { timeout_ms = 5000, retry_count = 1 } })
        upstream.run(ctx)

        assert.equal(1, #_sleep_calls)
        assert.equal(3.0, _sleep_calls[1])
    end)

    it("exhausting all retries with 429 raises an error", function()
        -- retry_count = 1 → 2 total attempts; push two 429s
        push_resp(429, {}, "rate limited")
        push_resp(429, {}, "rate limited")

        local ctx = make_ctx({ gateway_config = { timeout_ms = 5000, retry_count = 1 } })
        local ok, err = pcall(upstream.run, ctx)
        assert.is_false(ok, "should raise when all retries exhausted")
        assert.is_true(err:find("ALL_PROVIDERS_FAILED") ~= nil or err:find("429") ~= nil,
            "error must mention exhaustion, got: " .. tostring(err))
    end)

    it("does NOT sleep after the last failed attempt", function()
        -- retry_count = 2 → 3 total attempts; all fail with 429
        push_resp(429, {}, "rl")
        push_resp(429, {}, "rl")
        push_resp(429, {}, "rl")

        local ctx = make_ctx({ gateway_config = { timeout_ms = 5000, retry_count = 2 } })
        local ok = pcall(upstream.run, ctx)
        assert.is_false(ok)
        -- 3 attempts: sleep after attempt 0 (before retry 1) and attempt 1 (before retry 2)
        -- No sleep after attempt 2 (last)
        assert.equal(2, #_sleep_calls, "sleep called once per inter-attempt gap, not after last")
    end)

    it("Retry-After-Ms is capped at 30 seconds", function()
        push_resp(429, { ["retry-after-ms"] = "999999" }, "rl")
        push_resp(200, {}, '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}')

        local ctx = make_ctx({ gateway_config = { timeout_ms = 5000, retry_count = 1 } })
        upstream.run(ctx)

        assert.equal(1, #_sleep_calls)
        assert.is_true(_sleep_calls[1] <= 30, "sleep must be capped at 30s")
    end)
end)

-- ─── 5xx retry still works with backoff ───────────────────────────────────────

describe("upstream.run: 5xx retry still uses backoff", function()

    before_each(function()
        reset()
        upstream = reload_upstream()
    end)

    it("retries once after 500 and succeeds", function()
        push_resp(500, {}, '{"error":"internal"}')
        push_resp(200, {}, '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}')

        local ctx = make_ctx({ gateway_config = { timeout_ms = 5000, retry_count = 1 } })
        upstream.run(ctx)

        assert.equal(2,   _http_calls)
        assert.equal(200, ctx.provider_status)
    end)

    it("sleeps between 500 and retry", function()
        push_resp(500, {}, "err")
        push_resp(200, {}, '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}')

        local ctx = make_ctx({ gateway_config = { timeout_ms = 5000, retry_count = 1 } })
        upstream.run(ctx)

        assert.equal(1, #_sleep_calls)
        assert.is_true(_sleep_calls[1] > 0)
    end)
end)

-- ─── 4xx (non-429) passes through immediately ────────────────────────────────

describe("upstream.run: non-429 4xx passes through without retry", function()

    before_each(function()
        reset()
        upstream = reload_upstream()
    end)

    it("401 is passed through without retry", function()
        push_resp(401, {}, '{"error":"unauthorized"}')

        local ctx = make_ctx({ gateway_config = { timeout_ms = 5000, retry_count = 2 } })
        upstream.run(ctx)

        assert.equal(1, _http_calls, "no retry for 401")
        assert.equal(0, #_sleep_calls, "no sleep for 401")
        assert.equal(401, ctx.provider_status)
    end)

    it("400 is passed through without retry", function()
        push_resp(400, {}, '{"error":"bad request"}')

        local ctx = make_ctx({ gateway_config = { timeout_ms = 5000, retry_count = 2 } })
        upstream.run(ctx)

        assert.equal(1, _http_calls)
        assert.equal(0, #_sleep_calls)
    end)
end)

-- ─── per-rule timeout_ms ──────────────────────────────────────────────────────

describe("upstream.run: per-rule timeout_ms overrides gateway timeout", function()

    before_each(function()
        reset()
        upstream = reload_upstream()
    end)

    it("passes ctx.rule_timeout_ms as timeout_ms to http_util when set", function()
        -- Override http_util to capture the opts it receives
        local captured_opts = {}
        package.loaded["utils.http"] = nil
        package.preload["utils.http"] = function()
            return {
                request = function(opts)
                    _http_calls = _http_calls + 1
                    captured_opts[#captured_opts + 1] = { timeout_ms = opts.timeout_ms }
                    return 200, {}, '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}', nil, { set_keepalive = function() end }
                end,
            }
        end
        upstream = reload_upstream()

        local ctx = make_ctx({
            rule_timeout_ms = 3000,
            gateway_config  = { timeout_ms = 60000, retry_count = 0 },
        })
        upstream.run(ctx)

        assert.equal(1, #captured_opts)
        assert.equal(3000, captured_opts[1].timeout_ms)
    end)

    it("falls back to gateway timeout when rule_timeout_ms is absent", function()
        local captured_opts = {}
        package.loaded["utils.http"] = nil
        package.preload["utils.http"] = function()
            return {
                request = function(opts)
                    _http_calls = _http_calls + 1
                    captured_opts[#captured_opts + 1] = { timeout_ms = opts.timeout_ms }
                    return 200, {}, '{"choices":[{"message":{"content":"ok"},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}', nil, { set_keepalive = function() end }
                end,
            }
        end
        upstream = reload_upstream()

        local ctx = make_ctx({
            -- rule_timeout_ms intentionally absent
            gateway_config = { timeout_ms = 45000, retry_count = 0 },
        })
        upstream.run(ctx)

        assert.equal(1, #captured_opts)
        assert.equal(45000, captured_opts[1].timeout_ms)
    end)
end)
