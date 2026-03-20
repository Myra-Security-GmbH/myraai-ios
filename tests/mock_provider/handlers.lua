-- tests/mock_provider/handlers.lua — request handlers for the mock provider
--
-- Behaviour is controlled per-request via headers or model name:
--
--   X-Mock-Status: 500          force that HTTP status code
--   X-Mock-Delay: 200           sleep N milliseconds before responding
--   X-Mock-Scenario: streaming  return SSE instead of buffered JSON
--   X-Mock-Calls-Reset: 1       reset call counters (GET /mock/reset also works)
--
--   model = "x-mock-error"      → 500
--   model = "x-mock-ratelimit"  → 429
--   model = "x-mock-timeout"    → no response (causes upstream timeout)
--   model = "x-mock-stream"     → streaming SSE response
--   anything else               → normal 200 JSON

local cjson = require("cjson.safe")

local RESPONSES_DIR = debug.getinfo(1,"S").source:sub(2):match("^(.*/)") .. "responses/"

local M = {}

-- ---------------------------------------------------------------------------
-- Shared-dict call tracking helpers
-- ---------------------------------------------------------------------------
local function dict()
    return ngx.shared.mock_calls
end

local function record_call(path, body_str, req_headers)
    local d = dict()
    d:incr("total", 1, 0)
    d:incr("path:" .. path, 1, 0)
    d:set("last_body",    body_str or "")
    d:set("last_path",    path)
    d:set("last_headers", cjson.encode(req_headers) or "{}")
end

-- ---------------------------------------------------------------------------
-- Response helpers
-- ---------------------------------------------------------------------------
local function read_file(name)
    local f = io.open(RESPONSES_DIR .. name, "r")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

local function send_json(status, body_str)
    ngx.status = status
    ngx.header["Content-Type"] = "application/json"
    ngx.print(body_str)
end

local function send_streaming(body)
    -- body is either the request body table (to echo model) or nil
    ngx.status = 200
    ngx.header["Content-Type"]      = "text/event-stream"
    ngx.header["Cache-Control"]     = "no-cache"
    ngx.header["X-Accel-Buffering"] = "no"

    local chunks = read_file("openai_streaming.txt")
    if not chunks then
        ngx.print("data: [DONE]\n\n")
        return
    end

    -- Send each line with a tiny delay to simulate real streaming
    for line in (chunks .. "\n"):gmatch("([^\n]*)\n") do
        ngx.print(line .. "\n")
        ngx.flush(true)
        ngx.sleep(0.01)  -- 10ms between chunks
    end
end

-- ---------------------------------------------------------------------------
-- Route: provider API endpoints
-- ---------------------------------------------------------------------------
local function handle_chat(req_headers, body)
    -- Behaviour triggers from headers
    local forced_status = tonumber(req_headers["x-mock-status"])
    local delay_ms      = tonumber(req_headers["x-mock-delay"])
    local scenario      = req_headers["x-mock-scenario"]

    if delay_ms and delay_ms > 0 then
        ngx.sleep(delay_ms / 1000)
    end

    -- Behaviour triggers from model name
    local model = body and body.model or ""

    if forced_status then
        local err_body = read_file("error_500.json") or '{"error":{"message":"forced error"}}'
        send_json(forced_status, err_body)
        return
    end

    if model == "x-mock-error" then
        send_json(500, read_file("error_500.json"))
        return
    end

    if model == "x-mock-ratelimit" then
        send_json(429, read_file("error_429.json"))
        return
    end

    if model == "x-mock-timeout" then
        ngx.sleep(120)  -- longer than any reasonable timeout
        return
    end

    local is_stream = (body and body.stream == true)
                   or model == "x-mock-stream"
                   or scenario == "streaming"

    if is_stream then
        send_streaming(body)
        return
    end

    -- Normal response — pick the right canned file based on endpoint
    local path = ngx.var.uri
    local resp

    if path:find("/messages", 1, true) then
        -- Anthropic format
        resp = read_file("anthropic_messages.json")
    else
        -- OpenAI format (default)
        resp = read_file("openai_chat.json")
    end

    send_json(200, resp)
end

-- ---------------------------------------------------------------------------
-- Route: mock admin endpoints
-- ---------------------------------------------------------------------------
local function handle_admin()
    local path = ngx.var.uri

    if path == "/mock/reset" then
        dict():flush_all()
        ngx.say('{"ok":true}')
        return
    end

    if path == "/mock/calls" then
        local d = dict()
        local result = {
            total       = d:get("total") or 0,
            last_path   = d:get("last_path"),
            last_body   = d:get("last_body"),
        }
        ngx.header["Content-Type"] = "application/json"
        ngx.say(cjson.encode(result))
        return
    end

    if path == "/mock/last-request" then
        local d = dict()
        ngx.header["Content-Type"] = "application/json"
        ngx.say(cjson.encode({
            path    = d:get("last_path"),
            body    = d:get("last_body"),
            headers = d:get("last_headers"),
        }))
        return
    end

    ngx.status = 404
    ngx.say('{"error":"unknown mock endpoint"}')
end

-- ---------------------------------------------------------------------------
-- Main dispatcher — called from content_by_lua_block
-- ---------------------------------------------------------------------------
function M.handle()
    local path = ngx.var.uri

    -- Admin endpoints (no body parsing needed)
    if path:sub(1, 6) == "/mock/" then
        ngx.header["Content-Type"] = "application/json"
        handle_admin()
        return
    end

    -- Read and parse request body
    ngx.req.read_body()
    local raw = ngx.req.get_body_data() or ""
    local body = cjson.decode(raw)

    -- Record every call
    local req_headers = ngx.req.get_headers()
    record_call(path, raw, req_headers)

    -- Dispatch provider endpoints
    if path:find("/chat/completions", 1, true)
    or path:find("/completions", 1, true)
    or path:find("/messages", 1, true)
    or path:find("/generateContent", 1, true)
    or path:find("/embeddings", 1, true) then
        handle_chat(req_headers, body)
        return
    end

    -- Unknown path
    ngx.status = 404
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"mock: unknown endpoint ' .. path .. '"}')
end

return M
