-- tests/unit/test_middleware_response.lua — covers:
--   src/middleware/send_response.lua
--   src/middleware/guardrails.lua
--   src/middleware/guardrails_response.lua
--   src/middleware/request_id.lua
--   src/middleware/log.lua
-- Run with: resty tests/runner.lua tests/unit/test_middleware_response.lua

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

local cjson = require("cjson.safe")

local _printed_chunks = {}
local _exited  = nil
local _headers = {}
local _log_buf = {}
local _flushed = 0

_G.ngx = {
    log    = function(_, ...) _log_buf[#_log_buf + 1] = table.concat({...}) end,
    exit   = function(c) _exited = c; error(c, 0) end,
    print  = function(s) _printed_chunks[#_printed_chunks + 1] = s end,
    flush  = function() _flushed = _flushed + 1 end,
    status = 200,
    header = setmetatable({}, { __newindex = function(t, k, v)
        _headers[k] = v; rawset(t, k, v) end }),
    var    = { http_x_request_id = nil },
    req    = { get_headers = function() return {} end, set_header = function() end },
    ctx    = {},
    ERR    = 0, WARN = 1, INFO = 2,
    timer  = { at = function(_, fn, ...) pcall(fn, nil, ...) end },
}

for _, n in ipairs({"middleware.send_response","middleware.guardrails",
                    "middleware.guardrails_response","middleware.request_id",
                    "middleware.log","core.errors","utils.json","utils.trace",
                    "utils.uuid","core.app_config","guardrails.orchestrator",
                    "observability.logger"}) do
    package.loaded[n] = nil; package.preload[n] = nil
end

package.preload["core.app_config"] = function() return {} end

package.preload["utils.json"] = function()
    return { encode=cjson.encode, decode=cjson.decode, null=cjson.null }
end

package.preload["core.errors"] = function()
    return {
        send = function(code, detail) error(code, 0) end,
        codes = {},
    }
end

local _trace_steps = {}
package.preload["utils.trace"] = function()
    return {
        step = function(ctx, name, fields)
            _trace_steps[#_trace_steps + 1] = { name=name, fields=fields }
        end,
        done = function() end,
    }
end

package.preload["utils.uuid"] = function()
    local n = 0
    return { v4 = function() n = n + 1; return "uuid-" .. n end }
end

package.preload["observability.logger"] = function()
    return { emit = function(ctx) end }
end

-- Orchestrator mock: controlled result
local _orchestrator_result = "pass"
local _orchestrator_phase  = nil
package.preload["guardrails.orchestrator"] = function()
    return {
        run_phase = function(ctx, phase)
            _orchestrator_phase = phase
            ctx.log_fields = ctx.log_fields or {}
            if _orchestrator_result == "block" then
                ctx.log_fields.blocked_by   = "test-guardrail"
                ctx.log_fields.block_reason = "S10"
            end
            return _orchestrator_result
        end,
    }
end

local function reset()
    _printed_chunks = {}
    _exited  = nil
    _headers = {}
    _log_buf = {}
    _flushed = 0
    _trace_steps = {}
    _orchestrator_result = "pass"
    _orchestrator_phase  = nil
    _G.ngx.status = 200
    _G.ngx.header = setmetatable({}, { __newindex = function(t, k, v)
        _headers[k] = v; rawset(t, k, v) end })
    _G.ngx.ctx    = {}
    _G.ngx.var.http_x_request_id = nil
end

local function printed() return table.concat(_printed_chunks) end

local send_resp  = require("middleware.send_response")
local guardrails = require("middleware.guardrails")
local gr_resp    = require("middleware.guardrails_response")
local req_id     = require("middleware.request_id")
local log_mw     = require("middleware.log")

-- ============================================================================
-- send_response
-- ============================================================================

describe("middleware.send_response", function()

    it("skips (no-op) when ctx.is_streaming=true", function()
        reset()
        local ctx = { is_streaming=true, response_body='{}', gateway_config={} }
        local ok = pcall(send_resp.run, ctx)
        assert.is_true(ok)
        assert.equal("", printed(), "no output when streaming")
    end)

    it("sends GUARDRAIL_BLOCKED when ctx.guardrail_response_blocked is set", function()
        reset()
        local ctx = { is_streaming=false,
                      guardrail_response_blocked="test-guardrail",
                      response_body=nil, gateway_config={} }
        local ok, err = pcall(send_resp.run, ctx)
        assert.is_false(ok)
        assert.equal("GUARDRAIL_BLOCKED", tostring(err))
    end)

    it("prints response_body directly for non-streaming non-pii response", function()
        reset()
        local body = cjson.encode({ choices={{message={content="answer"}}} })
        local ctx  = { is_streaming=false, response_body=body,
                       buffered_needs_sse_reemit=false, pii_force_buffered=false,
                       gateway_config={} }
        pcall(send_resp.run, ctx)
        assert.equal(body, printed())
    end)

    it("does nothing when response_body is nil and not streaming", function()
        reset()
        local ctx = { is_streaming=false, response_body=nil, gateway_config={} }
        local ok = pcall(send_resp.run, ctx)
        assert.is_true(ok)
        assert.equal("", printed())
    end)

    it("re-emits as SSE when buffered_needs_sse_reemit=true", function()
        reset()
        local body = cjson.encode({
            id      = "chatcmpl-123",
            model   = "gpt-4o",
            choices = {{ message = { role="assistant", content="hello" }, finish_reason="stop" }},
            usage   = { prompt_tokens=5, completion_tokens=3 },
        })
        local ctx = { is_streaming=false, response_body=body,
                      buffered_needs_sse_reemit=true, pii_force_buffered=false,
                      request_id="req-1", model="gpt-4o",
                      gateway_config={} }
        pcall(send_resp.run, ctx)
        local out = printed()
        assert.is_true(out:find("data: ") ~= nil, "SSE re-emit must produce 'data: ' lines")
        assert.is_true(out:find("%[DONE%]") ~= nil, "SSE must end with [DONE]")
        assert.is_true(out:find("chat.completion.chunk") ~= nil, "must produce chunk events")
    end)

    it("SSE re-emit includes content from the buffered response", function()
        reset()
        local body = cjson.encode({
            id      = "chatcmpl-x",
            model   = "gpt-4o",
            choices = {{ message = { role="assistant", content="the answer" }, finish_reason="stop" }},
        })
        local ctx = { is_streaming=false, response_body=body,
                      buffered_needs_sse_reemit=true,
                      request_id="r", model="gpt-4o", gateway_config={} }
        pcall(send_resp.run, ctx)
        assert.is_true(printed():find("the answer") ~= nil,
            "SSE chunks must contain the content from buffered response")
    end)

end)

-- ============================================================================
-- guardrails (request-phase blocking)
-- ============================================================================

describe("middleware.guardrails: blocking behavior", function()

    it("does not block when orchestrator returns pass", function()
        reset()
        _orchestrator_result = "pass"
        local ctx = { is_compat=false, log_fields={},
                      request_body={ stream=false, model="claude-3" },
                      gateway_config={}, trace_id=nil }
        local ok = pcall(guardrails.run, ctx)
        assert.is_true(ok, "pass result must not abort the request")
    end)

    it("sends synthetic 200 response when orchestrator returns block", function()
        reset()
        _orchestrator_result = "block"
        local ctx = { is_compat=false, log_fields={ blocked_by="gr", block_reason="S10" },
                      request_body={ stream=false, model="claude-3" },
                      gateway_config={} }
        local ok, err = pcall(guardrails.run, ctx)
        assert.is_false(ok)
        assert.equal(200, tonumber(tostring(err):match("(%d+)$") or ""))
        assert.equal(200, _G.ngx.status)
    end)

    it("produces JSON response body on non-streaming block", function()
        reset()
        _orchestrator_result = "block"
        local ctx = { is_compat=false, log_fields={ blocked_by="gr", block_reason="S10" },
                      request_body={ stream=false, model="claude-3" },
                      gateway_config={} }
        pcall(guardrails.run, ctx)
        local out = printed()
        assert.is_true(#out > 0, "must produce a response body")
        local parsed = cjson.decode(out)
        assert.not_nil(parsed)
    end)

    it("produces SSE response on streaming block (is_compat=true)", function()
        reset()
        _orchestrator_result = "block"
        local ctx = { is_compat=true, log_fields={ blocked_by="gr", block_reason="S2" },
                      request_body={ stream=true, model="gpt-4o" },
                      gateway_config={} }
        pcall(guardrails.run, ctx)
        assert.is_true(printed():find("data: ") ~= nil,
            "SSE response must contain 'data: ' lines")
    end)

    it("expands category code S10 to human-readable label", function()
        reset()
        _orchestrator_result = "block"
        local ctx = { is_compat=false, log_fields={ blocked_by="gr", block_reason="S10" },
                      request_body={ stream=false, model="m" },
                      gateway_config={} }
        pcall(guardrails.run, ctx)
        assert.is_true(printed():find("Hate Speech") ~= nil,
            "S10 must expand to 'Hate Speech'")
    end)

    it("calls run_phase with phase='request'", function()
        reset()
        _orchestrator_result = "pass"
        local ctx = { is_compat=false, log_fields={}, request_body={stream=false},
                      gateway_config={} }
        pcall(guardrails.run, ctx)
        assert.equal("request", _orchestrator_phase)
    end)

end)

-- ============================================================================
-- guardrails_response
-- ============================================================================

describe("middleware.guardrails_response", function()

    it("skips when ctx.is_streaming=true", function()
        reset()
        _orchestrator_result = "block"
        local ctx = { is_streaming=true, response_body='{}', log_fields={} }
        gr_resp.run(ctx)
        assert.is_nil(ctx.guardrail_response_blocked, "streaming must skip response guardrail")
    end)

    it("skips when no response_body", function()
        reset()
        _orchestrator_result = "block"
        local ctx = { is_streaming=false, response_body=nil, log_fields={} }
        gr_resp.run(ctx)
        assert.is_nil(ctx.guardrail_response_blocked)
    end)

    it("sets guardrail_response_blocked when response is blocked", function()
        reset()
        _orchestrator_result = "block"
        local ctx = { is_streaming=false, response_body='{"content":"bad stuff"}',
                      log_fields={} }
        gr_resp.run(ctx)
        assert.not_nil(ctx.guardrail_response_blocked,
            "guardrail_response_blocked must be set on block")
        -- Value comes from ctx.log_fields.blocked_by which the orchestrator sets
        assert.equal("test-guardrail", ctx.guardrail_response_blocked)
    end)

    it("does NOT set guardrail_response_blocked when response passes", function()
        reset()
        _orchestrator_result = "pass"
        local ctx = { is_streaming=false, response_body='{"content":"ok"}', log_fields={} }
        gr_resp.run(ctx)
        assert.is_nil(ctx.guardrail_response_blocked)
    end)

end)

-- ============================================================================
-- request_id
-- ============================================================================

describe("middleware.request_id", function()

    it("generates a UUID v4 request_id when no header is present", function()
        reset()
        _G.ngx.var.http_x_request_id = nil
        local ctx = { gateway_config={} }
        req_id.run(ctx)
        assert.not_nil(ctx.request_id)
        assert.is_true(#ctx.request_id > 0)
    end)

    it("uses the incoming x-request-id header when present", function()
        reset()
        _G.ngx.var.http_x_request_id = "incoming-req-id"
        local ctx = { gateway_config={} }
        req_id.run(ctx)
        assert.equal("incoming-req-id", ctx.request_id)
    end)

    it("sets X-Request-Id response header", function()
        reset()
        _G.ngx.var.http_x_request_id = nil
        local ctx = { gateway_config={} }
        req_id.run(ctx)
        assert.not_nil(_headers["X-Request-Id"])
        assert.equal(ctx.request_id, _headers["X-Request-Id"])
    end)

end)

-- ============================================================================
-- log middleware
-- ============================================================================

describe("middleware.log", function()

    it("calls logger.emit with ctx", function()
        reset()
        local emit_called_with = nil
        package.loaded["observability.logger"] = nil
        package.preload["observability.logger"] = function()
            return { emit = function(ctx) emit_called_with = ctx end }
        end
        package.loaded["middleware.log"] = nil
        local lm = require("middleware.log")
        local ctx = { sentinel = "log-test" }
        lm.run(ctx)
        assert.not_nil(emit_called_with)
        assert.equal("log-test", emit_called_with.sentinel)
    end)

end)
