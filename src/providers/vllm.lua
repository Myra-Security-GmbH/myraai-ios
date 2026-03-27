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
    ["qwen3-30b-a3b"] = "http://172.28.0.1:8003",
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

M.parse_response  = openai.parse_response
M.parse_sse_chunk = openai.parse_sse_chunk

return M
