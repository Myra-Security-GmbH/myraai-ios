-- middleware/detectors.lua — Request-phase detector middleware entry point.
-- Runs request-phase detectors. Intended to complement (not replace) middleware.dlp
-- and middleware.guardrails_request for backward compatibility.
-- On block: sends a synthetic blocked response in the same format as guardrails_request.lua.

local json = require("utils.json")

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

function M.run(ctx)
    local result = require("detectors.orchestrator").run_phase(ctx, "request")
    if result == "block" then
        local reason = ctx.log_fields.block_reason or "policy"
        send_synthetic(ctx, "Request blocked by content policy (" ..
            (ctx.log_fields.blocked_by or "detector") .. "): " .. reason)
    end
end

return M
