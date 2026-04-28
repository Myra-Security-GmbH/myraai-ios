-- providers/vllm.lua — vLLM local inference server (OpenAI-compatible wire format)
-- Base URL priority:
--   1. model-specific port override (MODEL_PORTS table below)
--   2. per-gateway DB config: provider_base_urls.vllm
--   3. system config (config/gateway.lua): provider_base_urls.vllm
--   4. DEFAULT_BASE (standard vLLM localhost port)
-- Auth is optional: local vLLM instances do not require a key by default.

local openai     = require("providers.openai")
local app_config = require("core.app_config")

local M = {}

local DEFAULT_BASE = "http://127.0.0.1:8001"

-- Model-specific port overrides: fast small models get their own port so the
-- default gateway config (port 8001 = qwen3-235b) is never consulted for them.
local MODEL_PORTS = {
    ["qwen3.6-35b-a3b"] = "http://172.28.0.1:8003",
}

-- Models that support native vision (image_url content blocks).
-- Text-only models not listed here will have images routed through MinerU.
local VISION_MODELS = {
    -- Add vision-capable vLLM models here as they are deployed, e.g.:
    -- ["qwen2.5-vl-7b-instruct"] = true,
}

function M.is_vision_capable(model)
    local bare = (model or ""):match("^vllm/(.+)$") or model or ""
    return VISION_MODELS[bare] == true
end

local _sys_base = (app_config.provider_base_urls
                   and app_config.provider_base_urls.vllm)
                  or DEFAULT_BASE

function M.base_url(ctx)
    -- Strip optional "vllm/" prefix to get the bare model name used for routing
    local model = ctx.request_body and ctx.request_body.model or ""
    local bare  = model:match("^vllm/(.+)$") or model
    local model_override = MODEL_PORTS[bare]
    if model_override then
        return model_override .. ctx.provider_path
    end
    local base = (ctx.gateway_config
                  and ctx.gateway_config.provider_base_urls
                  and ctx.gateway_config.provider_base_urls.vllm)
                 or _sys_base
    return base .. ctx.provider_path
end

function M.build_headers(ctx, api_key)
    local headers = {
        ["Content-Type"] = "application/json",
        ["X-Request-Id"] = ctx.request_id or "",
    }
    if api_key and api_key ~= "" then
        headers["Authorization"] = "Bearer " .. api_key
    end
    return headers
end

-- Strip optional "vllm/" namespace prefix so the bare model name is forwarded
-- to the vLLM server (e.g. "vllm/Qwen3-235B-A22B-AWQ" → "Qwen3-235B-A22B-AWQ").
function M.build_request(ctx)
    local bare = ctx.request_body
                 and ctx.request_body.model
                 and ctx.request_body.model:match("^vllm/(.+)$")
    if not bare then
        return openai.build_request(ctx)
    end

    local patched = {}
    for k, v in pairs(ctx) do patched[k] = v end
    patched.request_body = {}
    for k, v in pairs(ctx.request_body) do patched.request_body[k] = v end
    patched.request_body.model = bare

    return openai.build_request(patched)
end

-- Strip <think>...</think> blocks from non-streaming response content.
-- Handles two emission modes:
--   1. Inline tags: <think>reasoning</think>answer  (vLLM without reasoning parser)
--   2. Orphan </think>: reasoning</think>answer      (vLLM reasoning-parser mode where
--      thinking is in message.reasoning_content but </think> leaks into message.content)
local function strip_think(s)
    if not s or s == "" then return s end
    if type(s) ~= "string" then return s end
    local out    = {}
    local pos    = 1
    local in_think = false
    while pos <= #s do
        if in_think then
            local te = s:find("</think>", pos, true)
            if not te then break end  -- unmatched <think> — drop rest
            in_think = false
            pos = te + 8
            if s:sub(pos, pos) == "\n" then pos = pos + 1 end
        else
            local ts = s:find("<think>",  pos, true)
            local te = s:find("</think>", pos, true)
            -- Orphan </think> before any <think>: drop everything up to it
            if te and (not ts or te < ts) then
                pos = te + 8
                if s:sub(pos, pos) == "\n" then pos = pos + 1 end
            elseif ts then
                if ts > pos then out[#out + 1] = s:sub(pos, ts - 1) end
                in_think = true
                pos = ts + 7
            else
                out[#out + 1] = s:sub(pos)
                break
            end
        end
    end
    local result = table.concat(out)
    return (result:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Stateful per-chunk stripper for streaming.
-- st._think persists across chunks so a <think> block that spans a chunk
-- boundary is handled correctly.  Also handles orphan </think> (vLLM
-- reasoning-parser mode: thinking in delta.reasoning, </think> in delta.content).
local function strip_think_delta(delta, st)
    if not delta or delta == "" then return delta end
    if type(delta) ~= "string" then return delta end
    local out = {}
    local pos = 1
    while true do
        if not st._think then
            local ts = delta:find("<think>",  pos, true)
            local te = delta:find("</think>", pos, true)
            -- Orphan </think>: drop it (and everything before it in this chunk)
            if te and (not ts or te < ts) then
                st._think = false
                pos = te + 8
                if delta:sub(pos, pos) == "\n" then pos = pos + 1 end
            elseif ts then
                if ts > pos then out[#out + 1] = delta:sub(pos, ts - 1) end
                st._think = true
                pos = ts + 7
            else
                out[#out + 1] = delta:sub(pos)
                break
            end
        else
            local te = delta:find("</think>", pos, true)
            if not te then break end
            st._think = false
            pos = te + 8
            if delta:sub(pos, pos) == "\n" then pos = pos + 1 end
        end
    end
    return table.concat(out)
end

function M.parse_response(body_str)
    local result, err = openai.parse_response(body_str)
    if result then
        result.content = strip_think(result.content)
    end
    return result, err
end

function M.parse_sse_chunk(line, st)
    st = st or {}
    local result = openai.parse_sse_chunk(line, st)
    if result and result.delta and result.delta ~= "" then
        result.delta = strip_think_delta(result.delta, st)
    end
    return result
end

return M
