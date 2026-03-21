-- providers/gemini.lua — Google Gemini (generativelanguage.googleapis.com)

local json      = require("utils.json")
local cjson_raw = require("cjson")
local NULL      = cjson_raw.null  -- JSON null decodes to this, not Lua nil

local M = {}

local BASE_URL = "https://generativelanguage.googleapis.com/v1beta"

function M.base_url(ctx)
    local model  = ctx.model or "gemini-1.5-flash"
    local action = ctx.request_body and ctx.request_body.stream
                   and "streamGenerateContent?alt=sse"
                   or  "generateContent"
    return BASE_URL .. "/models/" .. model .. ":" .. action
end

function M.build_headers(ctx, api_key)
    return {
        ["Content-Type"] = "application/json",
        ["x-goog-api-key"] = api_key,
        ["X-Request-Id"]   = ctx.request_id or "",
    }
end

-- Convert OpenAI-style request to Gemini GenerateContent format.
function M.build_request(ctx)
    local src = ctx.request_body

    local contents = {}
    local system_instruction
    for _, msg in ipairs(src.messages or {}) do
        if msg.role == "system" then
            system_instruction = { parts = {{ text = msg.content }} }
        else
            local role = msg.role == "assistant" and "model" or "user"
            contents[#contents + 1] = {
                role  = role,
                parts = {{ text = msg.content }},
            }
        end
    end

    local body = {
        contents          = contents,
        generationConfig  = {
            maxOutputTokens = src.max_tokens   or nil,
            temperature     = src.temperature  or nil,
            topP            = src.top_p        or nil,
        },
    }
    if system_instruction then
        body.system_instruction = system_instruction
    end

    -- Enable Google Search grounding when client passes a web_search tool
    if src.tools and type(src.tools) == "table" then
        for _, tool in ipairs(src.tools) do
            if tool.name == "web_search" then
                body.tools = {{ ["googleSearch"] = {} }}
                break
            end
        end
    end

    return json.encode(body)
end

function M.parse_response(body_str)
    local body = json.decode(body_str)
    if not body then return nil, "json decode failed" end
    if body.error then
        return nil, body.error.message or "provider error"
    end

    local content = ""
    local candidate = body.candidates and body.candidates[1]
    if candidate and candidate.content then
        for _, part in ipairs(candidate.content.parts or {}) do
            content = content .. (part.text or "")
        end
    end

    local meta = body.usageMetadata or {}
    return {
        content       = content,
        input_tokens  = meta.promptTokenCount     or 0,
        output_tokens = meta.candidatesTokenCount or 0,
        raw           = body,
    }
end

function M.parse_sse_chunk(line)
    local data = line:match("^data:%s*(.+)$")
    if not data then return nil end
    local chunk = json.decode(data)
    if not chunk then return nil end

    local content = ""
    local candidate = chunk.candidates and chunk.candidates[1]
    if candidate and candidate.content then
        for _, part in ipairs(candidate.content.parts or {}) do
            content = content .. (part.text or "")
        end
    end

    local meta = chunk.usageMetadata or {}
    local done = candidate and candidate.finishReason ~= nil
                           and candidate.finishReason ~= NULL
                           and candidate.finishReason ~= ""

    return {
        delta         = content,
        done          = done or false,
        input_tokens  = meta.promptTokenCount     or nil,
        output_tokens = meta.candidatesTokenCount or nil,
    }
end

return M
