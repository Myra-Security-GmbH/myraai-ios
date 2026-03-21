-- providers/bedrock.lua — AWS Bedrock InvokeModel adapter
--
-- Auth:   AWS SigV4 — BYOK key format: "ACCESS_KEY_ID:SECRET_ACCESS_KEY[:SESSION_TOKEN]"
-- Region: gateway_config.bedrock_region (default: "us-east-1")
--
-- Supported model families (detected from model ID prefix):
--   anthropic.*  — Anthropic Messages API format
--   meta.*       — Meta Llama prompt-string format
--   amazon.*     — Amazon Nova/Converse message format
--   mistral.*    — Mistral prompt-string format
--
-- Streaming: not supported. AWS Bedrock streaming uses a binary event-stream
-- protocol (not plain SSE). Streaming requests are silently downgraded to
-- non-streaming by omitting the stream flag from the body.

local json  = require("utils.json")
local sigv4 = require("utils.sigv4")

local M = {}

local SERVICE  = "bedrock"
local BASE_FMT = "https://bedrock-runtime.%s.amazonaws.com"

-- ── helpers ────────────────────────────────────────────────────────────────

local function get_region(ctx)
    return (ctx.gateway_config and ctx.gateway_config.bedrock_region) or "us-east-1"
end

-- Parse "ACCESS_KEY_ID:SECRET_ACCESS_KEY[:SESSION_TOKEN]"
local function parse_aws_key(api_key)
    local parts = {}
    for p in (api_key .. ":"):gmatch("([^:]*):") do
        parts[#parts + 1] = p
    end
    return parts[1] or "", parts[2] or "", parts[3]
end

-- Detect model family from Bedrock model ID prefix.
local function model_family(model_id)
    if not model_id then return "unknown" end
    if model_id:find("^anthropic%.")  then return "anthropic" end
    if model_id:find("^meta%.")       then return "meta"      end
    if model_id:find("^amazon%.")     then return "amazon"    end
    if model_id:find("^mistral%.")    then return "mistral"   end
    if model_id:find("^cohere%.")     then return "cohere"    end
    return "unknown"
end

-- ── body builders ──────────────────────────────────────────────────────────

-- Anthropic Messages API on Bedrock (model field omitted — passed in URL).
local function build_anthropic_body(src)
    local system_msg
    local messages = {}
    for _, msg in ipairs(src.messages or {}) do
        if msg.role == "system" then
            system_msg = msg.content
        else
            messages[#messages + 1] = { role = msg.role, content = msg.content }
        end
    end
    local body = {
        max_tokens = src.max_tokens or 4096,
        messages   = messages,
    }
    if system_msg        then body.system         = system_msg end
    if src.temperature   then body.temperature    = src.temperature end
    if src.top_p         then body.top_p          = src.top_p end
    if src.stop          then
        body.stop_sequences = type(src.stop) == "table" and src.stop or { src.stop }
    end
    -- stream omitted: Bedrock streaming requires binary event-stream protocol
    return json.encode(body)
end

-- Meta Llama: special-token prompt string.
local function build_meta_body(src)
    local parts = {}
    local has_system = false
    for _, msg in ipairs(src.messages or {}) do
        if msg.role == "system" then
            if not has_system then
                parts[#parts + 1] = "<|begin_of_text|>"
                has_system = true
            end
            parts[#parts + 1] = "<|start_header_id|>system<|end_header_id|>\n\n"
                              .. msg.content .. "<|eot_id|>"
        elseif msg.role == "user" then
            if not has_system then
                parts[#parts + 1] = "<|begin_of_text|>"
                has_system = true
            end
            parts[#parts + 1] = "<|start_header_id|>user<|end_header_id|>\n\n"
                              .. msg.content .. "<|eot_id|>"
        elseif msg.role == "assistant" then
            parts[#parts + 1] = "<|start_header_id|>assistant<|end_header_id|>\n\n"
                              .. msg.content .. "<|eot_id|>"
        end
    end
    parts[#parts + 1] = "<|start_header_id|>assistant<|end_header_id|>\n\n"
    local body = { prompt = table.concat(parts, "") }
    if src.max_tokens  then body.max_gen_len  = src.max_tokens  end
    if src.temperature then body.temperature  = src.temperature end
    if src.top_p       then body.top_p        = src.top_p       end
    return json.encode(body)
end

-- Amazon Nova / Converse: messages array with content blocks.
local function build_amazon_body(src)
    local messages = {}
    local system_list
    for _, msg in ipairs(src.messages or {}) do
        if msg.role == "system" then
            system_list = { { text = msg.content } }
        else
            messages[#messages + 1] = {
                role    = msg.role,
                content = { { text = msg.content } },
            }
        end
    end
    local body = { messages = messages }
    if system_list then body.system = system_list end
    local cfg = {}
    if src.max_tokens  then cfg.maxTokens   = src.max_tokens  end
    if src.temperature then cfg.temperature = src.temperature end
    if src.top_p       then cfg.topP        = src.top_p       end
    if next(cfg)       then body.inferenceConfig = cfg end
    return json.encode(body)
end

-- Mistral on Bedrock: prompt string.
local function build_mistral_body(src)
    local parts = {}
    for _, msg in ipairs(src.messages or {}) do
        if msg.role == "system" then
            parts[#parts + 1] = msg.content
        elseif msg.role == "user" then
            parts[#parts + 1] = "[INST] " .. msg.content .. " [/INST]"
        elseif msg.role == "assistant" then
            parts[#parts + 1] = msg.content
        end
    end
    local body = { prompt = table.concat(parts, "\n") }
    if src.max_tokens  then body.max_tokens  = src.max_tokens  end
    if src.temperature then body.temperature = src.temperature end
    if src.top_p       then body.top_p       = src.top_p       end
    return json.encode(body)
end

-- ── provider interface ─────────────────────────────────────────────────────

function M.base_url(ctx)
    local region   = get_region(ctx)
    local model_id = ctx.model or ""
    return (BASE_FMT:format(region)) .. "/model/" .. model_id .. "/invoke"
end

function M.build_request(ctx)
    local src    = ctx.request_body
    local family = model_family(ctx.model)
    local body
    if family == "anthropic" then body = build_anthropic_body(src)
    elseif family == "meta"  then body = build_meta_body(src)
    elseif family == "amazon"then body = build_amazon_body(src)
    elseif family == "mistral"then body = build_mistral_body(src)
    else  body = json.encode(src)  -- unknown family: best-effort passthrough
    end
    return json.sanitize_surrogates(body)
end

function M.build_headers(ctx, api_key)
    local access_key, secret_key, session_token = parse_aws_key(api_key)
    local region   = get_region(ctx)
    local model_id = ctx.model or ""
    local uri      = "/model/" .. model_id .. "/invoke"
    local host     = ("bedrock-runtime.%s.amazonaws.com"):format(region)
    local body_str = M.build_request(ctx)

    -- Datetime: YYYYMMDDTHHmmssZ
    local t = os.date("!*t", math.floor(ngx.now()))
    local datetime = string.format("%04d%02d%02dT%02d%02d%02dZ",
                        t.year, t.month, t.day, t.hour, t.min, t.sec)

    -- Headers to sign (sorted, lowercase)
    local sign_hdrs = { "content-type", "host", "x-amz-date" }
    local raw_hdrs = {
        ["content-type"] = "application/json",
        ["host"]         = host,
        ["x-amz-date"]   = datetime,
    }
    if session_token and session_token ~= "" then
        raw_hdrs["x-amz-security-token"] = session_token
        sign_hdrs[#sign_hdrs + 1] = "x-amz-security-token"
        table.sort(sign_hdrs)
    end

    local auth = sigv4.sign(
        "POST", uri, "", raw_hdrs, sign_hdrs, body_str,
        access_key, secret_key, datetime, region, SERVICE)

    return {
        ["Content-Type"]    = "application/json",
        ["X-Amz-Date"]      = datetime,
        ["Authorization"]   = auth,
        ["X-Amz-Security-Token"] = (session_token ~= "") and session_token or nil,
        ["X-Request-Id"]    = ctx.request_id or "",
    }
end

-- ── response parsers ───────────────────────────────────────────────────────

function M.parse_response(body_str)
    local body = json.decode(body_str)
    if not body then return nil, "json decode failed" end

    -- Bedrock error envelope
    if body.message and type(body.message) == "string" then
        return nil, body.message
    end

    -- Anthropic Messages format
    if body.content and type(body.content) == "table" then
        local content = ""
        for _, block in ipairs(body.content) do
            if block.type == "text" then content = content .. (block.text or "") end
        end
        local usage = body.usage or {}
        return {
            content       = content,
            input_tokens  = usage.input_tokens  or 0,
            output_tokens = usage.output_tokens or 0,
            raw           = body,
        }
    end

    -- Meta Llama format
    if body.generation ~= nil then
        return {
            content       = body.generation or "",
            input_tokens  = body.prompt_token_count      or 0,
            output_tokens = body.generation_token_count  or 0,
            raw           = body,
        }
    end

    -- Amazon Nova / Converse format
    if body.output and body.output.message then
        local content = ""
        for _, block in ipairs(body.output.message.content or {}) do
            content = content .. (block.text or "")
        end
        local usage = body.usage or {}
        return {
            content       = content,
            input_tokens  = usage.inputTokens  or 0,
            output_tokens = usage.outputTokens or 0,
            raw           = body,
        }
    end

    -- Mistral on Bedrock
    if body.outputs then
        local out = body.outputs[1] or {}
        return {
            content       = out.text or "",
            input_tokens  = 0,
            output_tokens = 0,
            raw           = body,
        }
    end

    return nil, "unrecognized bedrock response format"
end

-- Streaming requires binary AWS event-stream parsing — not yet implemented.
function M.parse_sse_chunk(_line)
    return nil
end

return M
