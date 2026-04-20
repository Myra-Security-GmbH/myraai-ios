-- middleware/guardrails.lua — Request-phase guardrail middleware entry point.
-- Runs request-phase guardrails (regex, keyword, presidio, prompt_guard, pii_protector).
-- On block: sends a synthetic blocked response (same format for all guardrail types).

local json  = require("utils.json")
local trace = require("utils.trace")

local CATEGORY_LABELS = {
    S1  = "Violent Crimes",
    S2  = "Non-Violent Crimes",
    S3  = "Sex-Related Crimes",
    S4  = "Child Sexual Exploitation",
    S5  = "Defamation",
    S6  = "Specialized Advice (medical / legal / financial)",
    S7  = "Privacy Violations",
    S8  = "Intellectual Property Infringement",
    S9  = "Weapons of Mass Destruction (CBRN)",
    S10 = "Hate Speech",
    S11 = "Suicide and Self-Harm",
    S12 = "Explicit Sexual Content",
    S13 = "Elections Integrity",
    S14 = "Code Interpreter Abuse",
}

local function expand_categories(reason)
    if not reason then return "policy" end
    local labels = {}
    for code in reason:gmatch("[^,]+") do
        local c = code:match("^%s*(.-)%s*$")
        labels[#labels + 1] = CATEGORY_LABELS[c] and (c .. " – " .. CATEGORY_LABELS[c]) or c
    end
    return #labels > 0 and table.concat(labels, ", ") or reason
end

local M = {}

-- Send a synthetic 200 assistant response so the client sees a normal reply,
-- not a hard error. Handles streaming and non-streaming for both Anthropic and
-- OpenAI-compat formats.
local function send_synthetic(ctx, text)
    local is_streaming = ctx.request_body and ctx.request_body.stream == true
    local is_compat    = ctx.is_compat

    ngx.status = 200

    if is_streaming then
        ngx.header["Content-Type"]      = "text/event-stream"
        ngx.header["Cache-Control"]     = "no-cache"
        ngx.header["X-Accel-Buffering"] = "no"

        local function sse(t) ngx.print("data: " .. json.encode(t) .. "\n\n") end

        if is_compat then
            local id = "chatcmpl_guardrail"
            sse({ id = id, object = "chat.completion.chunk",
                  choices = {{ index = 0, delta = { role = "assistant", content = "" }, finish_reason = json.null }} })
            sse({ id = id, object = "chat.completion.chunk",
                  choices = {{ index = 0, delta = { content = text }, finish_reason = json.null }} })
            sse({ id = id, object = "chat.completion.chunk",
                  choices = {{ index = 0, delta = {}, finish_reason = "stop" }} })
        else
            local model = (ctx.request_body and ctx.request_body.model) or "unknown"
            sse({ type = "message_start", message = { id = "msg_guardrail", type = "message",
                  role = "assistant", content = {}, model = model,
                  stop_reason = json.null, usage = { input_tokens = 0, output_tokens = 0 } } })
            sse({ type = "content_block_start", index = 0,
                  content_block = { type = "text", text = "" } })
            sse({ type = "content_block_delta", index = 0,
                  delta = { type = "text_delta", text = text } })
            sse({ type = "content_block_stop", index = 0 })
            sse({ type = "message_delta",
                  delta = { stop_reason = "end_turn", stop_sequence = json.null },
                  usage = { output_tokens = #text } })
            sse({ type = "message_stop" })
        end
        ngx.print("data: [DONE]\n\n")
        ngx.flush(true)
    else
        ngx.header["Content-Type"] = "application/json"
        local body
        if is_compat then
            body = json.encode({
                id      = "chatcmpl_guardrail",
                object  = "chat.completion",
                choices = {{ index = 0, message = { role = "assistant", content = text },
                             finish_reason = "stop" }},
                usage   = { prompt_tokens = 0, completion_tokens = 0, total_tokens = 0 },
            })
        else
            local model = (ctx.request_body and ctx.request_body.model) or "unknown"
            body = json.encode({
                id           = "msg_guardrail",
                type         = "message",
                role         = "assistant",
                model        = model,
                content      = {{ type = "text", text = text }},
                stop_reason  = "end_turn",
                usage        = { input_tokens = 0, output_tokens = #text },
            })
        end
        ngx.print(body)
    end

    ngx.exit(200)
end

-- Set X-Aig-Guardrail-Warning when a guardrail was unreachable but fail_open
-- let the request proceed. Must be called before headers are sent upstream;
-- safe in access/rewrite phase because upstream hasn't run yet.
local function set_degraded_header(ctx)
    local info = ctx.log_fields and ctx.log_fields.guardrail_error
    if not info then return end
    ngx.header["X-Aig-Guardrail-Warning"] =
        (info.name or "guardrail") .. " unavailable (" ..
        (info.error_class or "unknown") ..
        "); request processed without this guardrail"
end

function M.run(ctx)
    local result = require("guardrails.orchestrator").run_phase(ctx, "request")

    -- TRACE: guardrail outcome
    if ctx.trace_id then
        local lf = ctx.log_fields or {}
        trace.step(ctx, "guardrail_result", {
            verdict      = lf.guardrail_verdict or (result == "block" and "unsafe" or "safe"),
            blocked      = result == "block",
            blocked_by   = lf.blocked_by,
            block_reason = lf.block_reason,
            latency_ms   = lf.guardrail_latency_ms,
        })
    end

    if result == "block" then
        local br = ctx.log_fields.block_reason or ""
        local text
        if type(br) == "string" and br:sub(1, 22) == "guardrail_unavailable:" then
            -- Service-down block: be explicit that this is an outage, not policy.
            text = "The safety guardrail \"" ..
                   (ctx.log_fields.blocked_by or "guardrail") ..
                   "\" is temporarily unavailable and the request has been rejected " ..
                   "because this gateway is configured to fail closed. " ..
                   "Please retry in a few moments."
        else
            text = "Request blocked by content policy (" ..
                (ctx.log_fields.blocked_by or "guardrail") .. "): " ..
                expand_categories(br)
        end
        send_synthetic(ctx, text)
        return
    end

    -- Non-block path: if a guardrail was degraded (fail_open kept the request
    -- alive), surface an advisory header so clients can warn the user.
    if ctx.log_fields and ctx.log_fields.guardrail_degraded then
        set_degraded_header(ctx)
    end
end

return M
