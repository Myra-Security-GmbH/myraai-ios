-- providers/vertex.lua — Google Vertex AI (Gemini models) adapter
--
-- Auth:   API key via x-goog-api-key header
-- Config: gateway_config.vertex_project  (required — GCP project ID)
--         gateway_config.vertex_region   (default: "us-central1")
--
-- Request/response/SSE format is identical to providers/gemini.lua.
-- The only difference is the base URL, which embeds project and region.
--
-- BYOK key: the Vertex AI API key (or service-account-derived key).
-- Service-account OAuth token exchange is not yet implemented; use API keys.

local gemini = require("providers.gemini")

local M = {}

local URL_FMT = "https://%s-aiplatform.googleapis.com/v1/projects/%s"
             .. "/locations/%s/publishers/google/models/%s:%s"

local function get_region(ctx)
    return (ctx.gateway_config and ctx.gateway_config.vertex_region) or "us-central1"
end

local function get_project(ctx)
    return (ctx.gateway_config and ctx.gateway_config.vertex_project) or ""
end

function M.base_url(ctx)
    local region  = get_region(ctx)
    local project = get_project(ctx)
    local model   = ctx.model or "gemini-1.5-flash"
    local action  = (ctx.request_body and ctx.request_body.stream)
                    and "streamGenerateContent?alt=sse"
                    or  "generateContent"
    return URL_FMT:format(region, project, region, model, action)
end

function M.build_headers(ctx, api_key)
    return {
        ["Content-Type"]   = "application/json",
        ["x-goog-api-key"] = api_key,
        ["X-Request-Id"]   = ctx.request_id or "",
    }
end

M.build_request   = gemini.build_request
M.parse_response  = gemini.parse_response
M.parse_sse_chunk = gemini.parse_sse_chunk

return M
