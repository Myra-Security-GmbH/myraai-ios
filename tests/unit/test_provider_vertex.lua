-- tests/unit/test_provider_vertex.lua
-- Run with: busted tests/unit/test_provider_vertex.lua

_G.ngx = {
    now    = function() return 1700000000.0 end,
    log    = function() end,
    var    = { http_x_request_id = "" },
    req    = { get_headers = function() return {} end },
    ERR = 0, WARN = 1, INFO = 2,
}

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local function clear(names)
    for _, n in ipairs(names) do
        package.loaded[n]  = nil
        package.preload[n] = nil
    end
end

clear({"providers.vertex","providers.gemini","utils.json"})
local vertex = require("providers.vertex")
local cjson  = require("cjson.safe")

-- ── helpers ────────────────────────────────────────────────────────────────

local function ctx(model, opts)
    local c = {
        model          = model or "gemini-1.5-pro",
        request_id     = "req-vertex",
        gateway_config = opts and opts.gateway_config or {
            vertex_project = "my-gcp-project",
            vertex_region  = "us-central1",
        },
        request_body   = opts and opts.request_body or {
            messages = { { role = "user", content = "Hello" } }
        },
    }
    return c
end

-- ── base_url ───────────────────────────────────────────────────────────────

describe("providers.vertex — base_url", function()
    it("encodes project, region, and model in URL", function()
        local url = vertex.base_url(ctx("gemini-1.5-pro"))
        assert(url:find("my%-gcp%-project"),  "URL must contain project ID")
        assert(url:find("us%-central1"),       "URL must contain region")
        assert(url:find("gemini%-1%.5%-pro"),  "URL must contain model")
    end)

    it("points to aiplatform.googleapis.com", function()
        local url = vertex.base_url(ctx("gemini-1.5-pro"))
        assert(url:find("aiplatform%.googleapis%.com"))
    end)

    it("uses generateContent action for non-streaming", function()
        local url = vertex.base_url(ctx("gemini-1.5-flash"))
        assert(url:find(":generateContent$"))
    end)

    it("uses streamGenerateContent?alt=sse for streaming", function()
        local c = ctx("gemini-1.5-flash", {
            gateway_config = { vertex_project = "proj", vertex_region = "us-central1" },
            request_body   = { messages = {}, stream = true },
        })
        local url = vertex.base_url(c)
        assert(url:find("streamGenerateContent%?alt=sse$"))
    end)

    it("defaults to us-central1 when vertex_region absent", function()
        local c = ctx("gemini-1.5-pro", {
            gateway_config = { vertex_project = "proj" },
            request_body   = { messages = {} },
        })
        local url = vertex.base_url(c)
        assert(url:find("us%-central1"))
    end)

    it("uses custom region when vertex_region set", function()
        local c = ctx("gemini-1.5-pro", {
            gateway_config = { vertex_project = "proj", vertex_region = "europe-west4" },
            request_body   = { messages = {} },
        })
        local url = vertex.base_url(c)
        assert(url:find("europe%-west4"))
    end)
end)

-- ── build_headers ──────────────────────────────────────────────────────────

describe("providers.vertex — build_headers", function()
    it("sets x-goog-api-key with provided key", function()
        local h = vertex.build_headers(ctx("gemini-1.5-pro"), "vtx-key-123")
        assert.equal("vtx-key-123",      h["x-goog-api-key"])
        assert.equal("application/json", h["Content-Type"])
    end)

    it("does not set Authorization header", function()
        local h = vertex.build_headers(ctx("gemini-1.5-pro"), "vtx-key")
        assert.is_nil(h["Authorization"])
    end)
end)

-- ── build_request (delegates to gemini) ───────────────────────────────────

describe("providers.vertex — build_request", function()
    it("produces Gemini GenerateContent format", function()
        local c = ctx("gemini-1.5-pro", {
            gateway_config = { vertex_project = "proj", vertex_region = "us-central1" },
            request_body   = {
                messages = { { role = "user", content = "What is 2+2?" } }
            },
        })
        local body_str = vertex.build_request(c)
        local body     = cjson.decode(body_str)
        assert.not_nil(body.contents)
        assert.equal(1,      #body.contents)
        assert.equal("user", body.contents[1].role)
        assert.equal("What is 2+2?", body.contents[1].parts[1].text)
    end)

    it("maps system message to system_instruction", function()
        local c = ctx("gemini-1.5-pro", {
            gateway_config = { vertex_project = "proj", vertex_region = "us-central1" },
            request_body   = {
                messages = {
                    { role = "system", content = "Be concise." },
                    { role = "user",   content = "Hi" },
                },
            },
        })
        local body = cjson.decode(vertex.build_request(c))
        assert.not_nil(body.system_instruction)
        assert.equal("Be concise.", body.system_instruction.parts[1].text)
        assert.equal(1, #body.contents)
    end)

    it("maps max_tokens to maxOutputTokens in generationConfig", function()
        local c = ctx("gemini-1.5-pro", {
            gateway_config = { vertex_project = "proj", vertex_region = "us-central1" },
            request_body   = { messages = {}, max_tokens = 512 },
        })
        local body = cjson.decode(vertex.build_request(c))
        assert.equal(512, body.generationConfig.maxOutputTokens)
    end)
end)

-- ── parse_response (delegates to gemini) ──────────────────────────────────

describe("providers.vertex — parse_response", function()
    it("extracts text content and token counts from Gemini format", function()
        local body = [[{
            "candidates": [{
                "content": {
                    "parts": [{"text": "Hello from Vertex"}],
                    "role": "model"
                },
                "finishReason": "STOP"
            }],
            "usageMetadata": {
                "promptTokenCount": 8,
                "candidatesTokenCount": 5
            }
        }]]
        local r, err = vertex.parse_response(body)
        assert.is_nil(err)
        assert.equal("Hello from Vertex", r.content)
        assert.equal(8, r.input_tokens)
        assert.equal(5, r.output_tokens)
    end)

    it("returns error on json decode failure", function()
        local r, err = vertex.parse_response("{invalid")
        assert.is_nil(r)
        assert.equal("json decode failed", err)
    end)
end)

-- ── parse_sse_chunk (delegates to gemini) ─────────────────────────────────

describe("providers.vertex — parse_sse_chunk", function()
    it("extracts text from streaming Gemini SSE chunk", function()
        local line = [[data: {"candidates":[{"content":{"parts":[{"text":"chunk"}],"role":"model"}}]}]]
        local r = vertex.parse_sse_chunk(line)
        assert.not_nil(r)
        assert.equal("chunk", r.delta)
    end)

    it("returns nil for non-data lines", function()
        assert.is_nil(vertex.parse_sse_chunk(""))
        assert.is_nil(vertex.parse_sse_chunk(": keep-alive"))
    end)
end)
