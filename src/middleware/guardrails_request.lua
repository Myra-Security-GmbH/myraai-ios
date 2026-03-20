-- middleware/guardrails_request.lua — block unsafe prompts via Llama Guard 3
-- Config (in gateway_config.guardrails):
--   {
--     enabled          = true,
--     llama_guard_url  = "http://127.0.0.1:8083",  -- default
--     timeout_ms       = 2000,                       -- default
--     fail_open        = true,                       -- allow if LG unavailable (default)
--   }

local errors    = require("core.errors")
local json      = require("utils.json")
local http_util = require("utils.http")
local req_util  = require("utils.request")

local M = {}

local DEFAULT_URL     = "http://127.0.0.1:8083"
local DEFAULT_TIMEOUT = 2000

-- Llama Guard 3 safety category codes → human-readable labels
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

-- Format the raw category string (e.g. "S1,S9") into a readable list.
local function format_categories(cats)
    local labels = {}
    for code in cats:gmatch("[^,]+") do
        local trimmed = code:match("^%s*(.-)%s*$")
        labels[#labels + 1] = trimmed .. " – " .. (CATEGORY_LABELS[trimmed] or "Policy Violation")
    end
    return table.concat(labels, ", ")
end

-- Build the message text shown to the user.
local function blocked_text(cats)
    return "I'm not able to help with this request. It was flagged by the content " ..
           "policy for the following reason(s): " .. format_categories(cats) .. ". " ..
           "If you believe this is a mistake, please rephrase your request."
end

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

-- Call Llama Guard 3 with the request messages.
-- Returns { verdict="safe"|"unsafe", categories="S2,S9"|nil } or nil, err.
local function classify(messages, gr)
    local url     = (gr.llama_guard_url or DEFAULT_URL) .. "/v1/chat/completions"
    local timeout = gr.timeout_ms or DEFAULT_TIMEOUT

    local payload = json.encode({
        model       = "llama-guard-3-8b",
        messages    = messages,
        max_tokens  = 20,
        temperature = 0,
    })

    local status, _, body, err = http_util.request({
        method     = "POST",
        url        = url,
        headers    = { ["Content-Type"] = "application/json" },
        body       = payload,
        timeout_ms = timeout,
    })

    if err or not body then
        return nil, "request: " .. tostring(err)
    end
    if status ~= 200 then
        return nil, "http " .. tostring(status)
    end

    local resp = json.decode(body)
    if not resp or not resp.choices or not resp.choices[1] then
        return nil, "parse_response"
    end

    local content = resp.choices[1].message and resp.choices[1].message.content or ""
    -- content is "safe" or "unsafe\nS2,S9" (may have leading whitespace)
    content = content:match("^%s*(.-)%s*$")  -- trim
    local verdict    = content:match("^(%a+)")
    local categories = content:match("\n(.+)$")
    return { verdict = verdict, categories = categories }
end

-- Extract text from a message content value (string or Anthropic content-block array).
local function content_to_text(content)
    if type(content) == "string" then return content end
    if type(content) == "table" then
        local parts = {}
        for _, block in ipairs(content) do
            if block.type == "text" and block.text then
                parts[#parts + 1] = block.text
            end
        end
        return table.concat(parts, "\n")
    end
    return ""
end

-- Extract the last user message for Llama Guard classification.
-- Llama Guard requires strictly alternating roles, so sending the full
-- conversation history breaks on any real multi-turn exchange. We only
-- need to screen what the user is currently saying.
local function extract_messages(body)
    if not body then return nil end
    if body.messages and #body.messages > 0 then
        -- Walk backwards to find the last user message
        for i = #body.messages, 1, -1 do
            local msg = body.messages[i]
            if msg.role == "user" then
                local text = content_to_text(msg.content)
                if text ~= "" then
                    return {{ role = "user", content = text }}
                end
            end
        end
        return nil
    end
    if body.prompt then
        return {{ role = "user", content = tostring(body.prompt) }}
    end
    return nil
end

function M.run(ctx)
    local gr = ctx.gateway_config.guardrails
    if not gr or not gr.enabled then return end

    -- Parse body if not already done (guardrails runs before transform)
    if not ctx.request_body then
        if not ctx.raw_request_body then
            ctx.raw_request_body = req_util.read_body() or ""
        end
        ctx.request_body = json.decode(ctx.raw_request_body) or {}
    end

    local messages = extract_messages(ctx.request_body)
    if not messages then return end  -- nothing to classify

    local result, classify_err = classify(messages, gr)

    if not result then
        ngx.log(ngx.WARN, "guardrails: llama guard unavailable: ", classify_err,
                " tenant=", ctx.tenant_id)
        if gr.fail_open ~= false then
            return  -- fail open: allow request through
        end
        -- fail closed
        ctx.log_fields = ctx.log_fields or {}
        ctx.log_fields.blocked_by   = "guardrail_error"
        ctx.log_fields.block_reason = classify_err
        send_synthetic(ctx, "I'm not able to process this request because the content " ..
                            "policy check is currently unavailable.")
        return
    end

    if result.verdict ~= "unsafe" then return end

    local cats = result.categories or "unknown"
    ngx.log(ngx.WARN, "guardrails: blocked tenant=", ctx.tenant_id,
            " categories=", cats)
    ctx.log_fields = ctx.log_fields or {}
    ctx.log_fields.blocked_by   = "guardrail"
    ctx.log_fields.block_reason = cats
    send_synthetic(ctx, blocked_text(cats))
end

return M
