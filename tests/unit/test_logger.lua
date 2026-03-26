-- tests/unit/test_logger.lua — unit tests for observability/logger.lua
-- Run with: resty tests/runner.lua tests/unit/test_logger.lua

-- ---------------------------------------------------------------------------
-- Minimal ngx stub
-- ---------------------------------------------------------------------------
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
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

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

-- ---------------------------------------------------------------------------
-- Stubs
-- ---------------------------------------------------------------------------

local log_store = {}      -- captures calls to storage.insert_log
local log_err   = nil     -- when non-nil, insert_log returns this error string
local ngx_log_calls = {}  -- captures ngx.log calls

local storage_stub = {
    insert_log = function(fields)
        table.insert(log_store, fields)
        return log_err
    end,
}

local uuid_n = 0
local uuid_stub = {
    v4 = function()
        uuid_n = uuid_n + 1
        return string.format("uuid-%04d", uuid_n)
    end,
}

local json_stub = (function()
    local cjson = require("cjson.safe")
    return { encode = cjson.encode, decode = cjson.decode }
end)()

local trace_calls = {}
local trace_stub = {
    done = function(ctx, status, reason)
        table.insert(trace_calls, { ctx = ctx, status = status, reason = reason })
    end,
}

local webhook_calls = {}
local webhook_stub = {
    fire = function(webhooks, event, payload, meta)
        table.insert(webhook_calls, { webhooks = webhooks, event = event, payload = payload, meta = meta })
    end,
}

local siem_calls = {}
local siem_stub = {
    emit = function(cfg, fields)
        table.insert(siem_calls, { cfg = cfg, fields = fields })
    end,
}

local tracer_calls = {}
local tracer_stub = {
    emit = function(ctx, tracing)
        table.insert(tracer_calls, { ctx = ctx, tracing = tracing })
    end,
}

-- ---------------------------------------------------------------------------
-- Helper: fresh require of logger with stubs in place
-- ---------------------------------------------------------------------------
local function reset()
    package.loaded["observability.logger"] = nil
    package.preload["observability.logger"] = nil
    package.loaded["storage"]              = nil
    package.loaded["utils.json"]           = nil
    package.loaded["utils.uuid"]           = nil
    package.loaded["utils.trace"]          = nil
    package.loaded["utils.webhook"]        = nil
    package.loaded["observability.siem"]   = nil
    package.loaded["observability.tracer"] = nil

    package.loaded["storage"]            = storage_stub
    package.loaded["utils.json"]         = json_stub
    package.loaded["utils.uuid"]         = uuid_stub
    package.loaded["utils.trace"]        = trace_stub
    package.loaded["utils.webhook"]      = webhook_stub
    package.loaded["observability.siem"] = siem_stub
    package.loaded["observability.tracer"] = tracer_stub

    log_store      = {}
    log_err        = nil
    ngx_log_calls  = {}
    trace_calls    = {}
    webhook_calls  = {}
    siem_calls     = {}
    tracer_calls   = {}

    return require("observability.logger")
end

-- ---------------------------------------------------------------------------
-- 1. skip_log early return — insert_log must NOT be called
-- ---------------------------------------------------------------------------
local logger = reset()
logger.emit({ skip_log = true, gateway_config = {} })
ok("1. skip_log=true skips insert_log", #log_store == 0)

-- ---------------------------------------------------------------------------
-- 2. Basic emit stores a log entry
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = {},
    gateway_id = "gw-1", tenant_id = "tn-1",
    provider = "openai", model = "gpt-4o",
    log_fields = {},
})
ok("2. basic emit calls insert_log once", #log_store == 1)
ok("2b. gateway_id forwarded", log_store[1].gateway_id == "gw-1")
ok("2c. tenant_id forwarded", log_store[1].tenant_id == "tn-1")

-- ---------------------------------------------------------------------------
-- 3. id comes from ctx.request_id if present
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = {},
    request_id = "req-abc",
    log_fields = {},
})
ok("3. request_id used as log id", log_store[1].id == "req-abc")

-- ---------------------------------------------------------------------------
-- 4. id falls back to uuid.v4() when request_id is absent
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({ gateway_config = {}, log_fields = {} })
ok("4. uuid.v4() used when no request_id", log_store[1].id ~= nil and log_store[1].id:match("^uuid%-"))

-- ---------------------------------------------------------------------------
-- 5. log_payloads=true + messages array → prompt assembled
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = { log_payloads = true },
    request_body = {
        messages = {
            { role = "user",      content = "Hello" },
            { role = "assistant", content = "Hi there" },
        },
    },
    log_fields = {},
})
ok("5. log_payloads assembles prompt from messages",
    log_store[1].prompt == "user: Hello\nassistant: Hi there",
    log_store[1].prompt)

-- ---------------------------------------------------------------------------
-- 6. log_payloads=true + message content is a table → json.encode used
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = { log_payloads = true },
    request_body = {
        messages = {
            { role = "user", content = { { type = "text", text = "hi" } } },
        },
    },
    log_fields = {},
})
ok("6. table content is json-encoded in prompt",
    log_store[1].prompt ~= nil and log_store[1].prompt:find("%["))

-- ---------------------------------------------------------------------------
-- 7. log_payloads=true + prompt field (completions-style API)
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = { log_payloads = true },
    request_body   = { prompt = "Tell me a story" },
    log_fields     = {},
})
ok("7. prompt field forwarded when log_payloads=true",
    log_store[1].prompt == "Tell me a story",
    log_store[1].prompt)

-- ---------------------------------------------------------------------------
-- 8. log_payloads=true + response_body captured
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = { log_payloads = true },
    response_body  = "Some response text",
    log_fields     = {},
})
ok("8. response_body captured when log_payloads=true",
    log_store[1].response == "Some response text",
    log_store[1].response)

-- ---------------------------------------------------------------------------
-- 9. log_payloads=false → prompt and response are nil
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = { log_payloads = false },
    request_body   = { messages = { { role = "user", content = "Hi" } } },
    response_body  = "hello",
    log_fields     = {},
})
ok("9. log_payloads=false leaves prompt nil",   log_store[1].prompt   == nil)
ok("9b. log_payloads=false leaves response nil", log_store[1].response == nil)

-- ---------------------------------------------------------------------------
-- 10. log_fields merged into fields
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = {},
    log_fields = { quota_remaining = 0.42, custom_key = "yes" },
})
ok("10. log_fields merged: quota_remaining",
    log_store[1].quota_remaining == 0.42,
    log_store[1].quota_remaining)
ok("10b. log_fields merged: custom_key",
    log_store[1].custom_key == "yes")

-- ---------------------------------------------------------------------------
-- 11. blocked_by in log_fields → fields.blocked = true
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = {},
    log_fields     = { blocked_by = "guardrail:keyword" },
})
ok("11. blocked_by sets blocked=true", log_store[1].blocked == true)

-- ---------------------------------------------------------------------------
-- 12. no blocked_by → fields.blocked = false
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({ gateway_config = {}, log_fields = {} })
ok("12. no blocked_by → blocked=false", log_store[1].blocked == false)

-- ---------------------------------------------------------------------------
-- 13. insert_log error → ngx.log(ERR) called
-- ---------------------------------------------------------------------------
local ngx_log_err_count = 0
local _saved_log = ngx.log
ngx.log = function(level, ...) if level == ngx.ERR then ngx_log_err_count = ngx_log_err_count + 1 end end

reset()
log_err = "disk full"
logger  = require("observability.logger")
logger.emit({ gateway_config = {}, log_fields = {} })
ok("13. insert_log error triggers ngx.log(ERR)", ngx_log_err_count > 0)
ngx.log = _saved_log

-- ---------------------------------------------------------------------------
-- 14. ctx.trace_id present + not blocked → trace.done("done")
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = {},
    trace_id       = "trace-xyz",
    log_fields     = {},
})
ok("14. trace.done called when trace_id set",
    #trace_calls == 1 and trace_calls[1].status == "done",
    #trace_calls)
ok("14b. trace.done reason is nil when not blocked",
    trace_calls[1].reason == nil)

-- ---------------------------------------------------------------------------
-- 15. blocked + trace_id → trace.done("blocked", reason)
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = {},
    trace_id       = "trace-abc",
    log_fields     = { blocked_by = "guardrail:pii", block_reason = "SSN found" },
})
ok("15. trace.done('blocked', reason) when blocked",
    #trace_calls == 1 and trace_calls[1].status == "blocked",
    trace_calls[1] and trace_calls[1].status)
ok("15b. block_reason forwarded to trace.done",
    trace_calls[1].reason == "SSN found",
    trace_calls[1].reason)

-- ---------------------------------------------------------------------------
-- 16. no trace_id → trace.done NOT called
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({ gateway_config = {}, log_fields = {} })
ok("16. trace.done NOT called when no trace_id", #trace_calls == 0)

-- ---------------------------------------------------------------------------
-- 17. webhook fires when blocked + webhooks configured
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = {
        webhooks = { { url = "https://example.com/hook" } },
    },
    log_fields = { blocked_by = "guardrail:keyword" },
})
ok("17. webhook.fire called when blocked", #webhook_calls == 1)
ok("17b. webhook event is 'blocked'", webhook_calls[1].event == "blocked")

-- ---------------------------------------------------------------------------
-- 18. webhook NOT fired when not blocked
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = { webhooks = { { url = "https://example.com/hook" } } },
    log_fields     = {},
})
ok("18. webhook NOT fired when not blocked", #webhook_calls == 0)

-- ---------------------------------------------------------------------------
-- 19. webhook NOT fired when webhooks is not a table
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = { webhooks = "bad" },
    log_fields     = { blocked_by = "guardrail:pii" },
})
ok("19. webhook NOT fired when webhooks is not a table", #webhook_calls == 0)

-- ---------------------------------------------------------------------------
-- 20. SIEM emit when siem configured
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = { siem = { endpoint = "https://siem.example.com" } },
    log_fields     = {},
})
ok("20. siem.emit called when siem configured", #siem_calls == 1)
ok("20b. siem cfg forwarded", siem_calls[1].cfg.endpoint == "https://siem.example.com")

-- ---------------------------------------------------------------------------
-- 21. SIEM NOT called when no siem config
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({ gateway_config = {}, log_fields = {} })
ok("21. siem.emit NOT called without siem config", #siem_calls == 0)

-- ---------------------------------------------------------------------------
-- 22. OTel tracer emit when tracing.otlp_endpoint configured
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = { tracing = { otlp_endpoint = "http://otel:4318" } },
    log_fields     = {},
})
ok("22. tracer.emit called when otlp_endpoint configured", #tracer_calls == 1)
ok("22b. tracing config forwarded", tracer_calls[1].tracing.otlp_endpoint == "http://otel:4318")

-- ---------------------------------------------------------------------------
-- 23. OTel NOT called without tracing config
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({ gateway_config = {}, log_fields = {} })
ok("23. tracer.emit NOT called without tracing config", #tracer_calls == 0)

-- ---------------------------------------------------------------------------
-- 24. latency_ms computed from start_ms
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
-- ngx.now() returns 1700000000.0 s → 1700000000000 ms
local start_ms = 1700000000.0 * 1000 - 250  -- 250ms ago
logger.emit({
    gateway_config = {},
    start_ms       = start_ms,
    log_fields     = {},
})
ok("24. latency_ms computed from start_ms",
    log_store[1].latency_ms == 250,
    log_store[1].latency_ms)

-- ---------------------------------------------------------------------------
-- 25. user_id and token_label forwarded
-- ---------------------------------------------------------------------------
reset()
logger = require("observability.logger")
logger.emit({
    gateway_config = {},
    user_id        = "u-42",
    token_label    = "my-laptop",
    log_fields     = {},
})
ok("25. user_id forwarded",    log_store[1].user_id     == "u-42")
ok("25b. token_label forwarded", log_store[1].token_label == "my-laptop")

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
print(string.format("\n%d passed, %d failed", pass, fail))
if fail > 0 then os.exit(1) end
