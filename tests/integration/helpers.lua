-- tests/integration/helpers.lua — shared utilities for integration tests
-- Requires: curl on PATH, gateway on 127.0.0.1:8081, mock on 127.0.0.1:19000

local cjson = require("cjson.safe")

local GW   = "http://127.0.0.1:8081"
local MOCK = "http://127.0.0.1:19000"

local M = {}

-- ---------------------------------------------------------------------------
-- HTTP helpers (thin curl wrappers — no resty.http dependency in test runner)
-- ---------------------------------------------------------------------------

-- Shell-quote a single argument (single-quote wrapping with inner-quote escaping).
local function shquote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Perform an HTTP request via curl. Returns { status, headers, body }.
-- Body is written to a temp file to avoid shell quoting issues with JSON.
function M.request(opts)
    opts = opts or {}
    local method  = opts.method  or "GET"
    local url     = opts.url
    local headers = opts.headers or {}
    local body    = opts.body
    local timeout = opts.timeout or 5

    -- Write body to a temp file so it doesn't need shell quoting
    local body_file
    if body then
        body_file = os.tmpname()
        local f = io.open(body_file, "w")
        f:write(body)
        f:close()
    end

    local parts = { "curl", "-s", "-i",
                    "--max-time", tostring(timeout),
                    "-X", shquote(method) }

    for k, v in pairs(headers) do
        parts[#parts + 1] = "-H"
        parts[#parts + 1] = shquote(k .. ": " .. v)
    end

    if body_file then
        parts[#parts + 1] = "--data-binary"
        parts[#parts + 1] = shquote("@" .. body_file)
    end

    parts[#parts + 1] = shquote(url)

    local pipe = io.popen(table.concat(parts, " "))
    local raw  = pipe:read("*a")
    pipe:close()

    if body_file then os.remove(body_file) end

    -- Split headers from body on first blank line (\r\n\r\n or \n\n)
    local hdr_block, resp_body = raw:match("^(.-)\r?\n\r?\n(.*)$")
    if not hdr_block then
        return { status = 0, headers = {}, body = raw }
    end

    -- Parse status line (handle HTTP/2 too)
    local status = tonumber(hdr_block:match("HTTP/%S+ (%d+)")) or 0

    -- Parse response headers
    local resp_headers = {}
    for line in hdr_block:gmatch("[^\r\n]+") do
        local k, v = line:match("^([^:]+):%s*(.+)$")
        if k then resp_headers[k:lower()] = v end
    end

    return { status = status, headers = resp_headers, body = resp_body or "" }
end

-- POST JSON to the gateway
function M.gateway_post(path, body_table, extra_headers)
    local headers = { ["Content-Type"] = "application/json" }
    for k, v in pairs(extra_headers or {}) do headers[k] = v end
    return M.request({
        method  = "POST",
        url     = GW .. path,
        headers = headers,
        body    = cjson.encode(body_table),
    })
end

-- GET from the mock admin API
function M.mock_get(path)
    return M.request({ url = MOCK .. path })
end

-- Reset mock call counters
function M.mock_reset()
    M.request({ url = MOCK .. "/mock/reset" })
end

-- Return call count from mock
function M.mock_calls()
    local r = M.request({ url = MOCK .. "/mock/calls" })
    local d = cjson.decode(r.body)
    return d and d.total or 0
end

-- Return last request body seen by mock (as a Lua table)
function M.mock_last_request()
    local r = M.request({ url = MOCK .. "/mock/last-request" })
    local d = cjson.decode(r.body)
    if not d or not d.body then return nil end
    return cjson.decode(d.body)
end

-- ---------------------------------------------------------------------------
-- Standard request bodies
-- ---------------------------------------------------------------------------
M.CHAT_BODY = {
    model    = "gpt-4o-mini",
    messages = {{ role = "user", content = "Hello from integration test" }},
}

M.STREAM_BODY = {
    model    = "gpt-4o-mini",
    stream   = true,
    messages = {{ role = "user", content = "Hello streaming" }},
}

-- Gateway URL helpers
M.GW_BASE  = GW
M.MOCK_BASE = MOCK

function M.gw_path(tenant, gateway, provider, path)
    return string.format("/v1/%s/%s/%s%s", tenant, gateway, provider, path or "")
end

return M
