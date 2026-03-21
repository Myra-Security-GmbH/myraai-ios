-- middleware/send_response.lua — send the buffered non-streaming response
-- Runs after detectors_response so a blocked response is never sent.
-- Streaming responses are already sent by upstream.lua; this is a no-op for them.
--
-- Special case: pii_force_buffered
--   When pii_protector forced a buffered upstream call for a compat streaming
--   request, the client still expects SSE.  Re-emit ctx.response_body
--   (an OpenAI chat.completion JSON object) as a minimal SSE stream.

local errors = require("core.errors")
local json   = require("utils.json")

local M = {}

-- Re-emit an OpenAI chat.completion JSON as chat.completion.chunk SSE so that
-- clients that sent stream=true receive a valid stream despite the upstream
-- call being buffered.
local function reemit_as_sse(ctx)
    local parsed = json.decode(ctx.response_body)
    if not parsed then
        -- Fallback: send raw body as plain JSON (best-effort)
        ngx.header["Content-Type"] = "application/json"
        ngx.print(ctx.response_body)
        return
    end

    ngx.status = 200
    ngx.header["Content-Type"]      = "text/event-stream"
    ngx.header["Cache-Control"]     = "no-cache"
    ngx.header["X-Accel-Buffering"] = "no"

    local chat_id = (parsed.id or ("chatcmpl-" .. (ctx.request_id or "aig")))
    local model   = parsed.model or ctx.model or ""
    local choice  = parsed.choices and parsed.choices[1]
    local content = (choice and choice.message and choice.message.content) or ""
    local usage   = parsed.usage

    -- role delta
    ngx.print("data: " .. json.encode({
        id      = chat_id,
        object  = "chat.completion.chunk",
        model   = model,
        choices = {{ index = 0, delta = { role = "assistant", content = "" },
                     finish_reason = json.null }},
    }) .. "\n\n")

    -- content delta
    if content ~= "" then
        ngx.print("data: " .. json.encode({
            id      = chat_id,
            object  = "chat.completion.chunk",
            model   = model,
            choices = {{ index = 0, delta = { content = content },
                         finish_reason = json.null }},
        }) .. "\n\n")
    end

    -- usage chunk
    if usage then
        ngx.print("data: " .. json.encode({
            id     = chat_id,
            object = "chat.completion.chunk",
            model  = model,
            usage  = usage,
        }) .. "\n\n")
    end

    -- stop delta
    ngx.print("data: " .. json.encode({
        id      = chat_id,
        object  = "chat.completion.chunk",
        model   = model,
        choices = {{ index = 0, delta = {}, finish_reason = "stop" }},
    }) .. "\n\n")

    ngx.print("data: [DONE]\n\n")
    ngx.flush(true)
end

function M.run(ctx)
    if ctx.is_streaming then return end  -- already sent

    -- If guardrails flagged the response, block it now before sending
    if ctx.guardrail_response_blocked then
        errors.send("GUARDRAIL_BLOCKED",
            "Response blocked by content policy: " .. ctx.guardrail_response_blocked)
    end

    if not ctx.response_body then return end

    -- pii_protector forced the upstream to buffer a streaming request so it
    -- could restore tokens.  Re-emit as SSE so the client gets what it asked for.
    if ctx.pii_force_buffered then
        reemit_as_sse(ctx)
        return
    end

    ngx.print(ctx.response_body)
end

return M
