-- utils/http.lua — lua-resty-http wrapper for upstream provider calls
local http_lib = require("resty.http")

local M = {}

local DEFAULT_CONNECT_MS        =   5000  -- TCP handshake should be near-instant for local/CDN
local DEFAULT_SEND_MS           =  10000  -- sending the request body
local DEFAULT_READ_MS           =  60000  -- non-streaming: waiting for + reading full response
local DEFAULT_STREAM_READ_MS    = 300000  -- streaming: max gap between SSE chunks (5 min)
                                          -- Long responses from slow/local models or extended
                                          -- <think> blocks can take well over 60 s between
                                          -- tokens.  Without this the socket read times out
                                          -- and the stream is cut mid-response.

-- Perform an HTTP request to an upstream provider.
-- opts fields:
--   method, url, headers, body, stream (bool)
--   timeout_ms           — unified fallback for all three phases (backwards-compat)
--   connect_timeout_ms   — TCP connect phase (default 5 s)
--   send_timeout_ms      — sending request headers + body (default 10 s)
--   read_timeout_ms      — waiting for + reading response (default 60 s non-stream,
--                          300 s streaming)
-- Returns (status, headers, body_or_reader, err)
function M.request(opts)
    local httpc = http_lib.new()
    local fallback = opts.timeout_ms
    -- For streaming, read_timeout_ms must never fall back to the general timeout_ms
    -- (which is typically 60 s from gateway config).  Without this guard, a 60 s
    -- gateway timeout × 3 retry attempts = 180 s and the stream is cut mid-response.
    local read_ms = opts.read_timeout_ms
                    or (opts.stream and DEFAULT_STREAM_READ_MS)
                    or fallback
                    or DEFAULT_READ_MS
    httpc:set_timeouts(
        opts.connect_timeout_ms or fallback or DEFAULT_CONNECT_MS,
        opts.send_timeout_ms    or fallback or DEFAULT_SEND_MS,
        read_ms
    )

    local parsed, err = httpc:parse_uri(opts.url)
    if not parsed then
        return nil, nil, nil, "parse_uri: " .. tostring(err)
    end

    local ok, conn_err = httpc:connect({
        scheme      = parsed[1],
        host        = parsed[2],
        port        = parsed[3],
        ssl_verify  = true,
        ssl_server_name = parsed[2],  -- SNI hostname
    })
    if not ok then
        return nil, nil, nil, "connect: " .. tostring(conn_err)
    end

    local path = parsed[4]
    if parsed[5] and parsed[5] ~= "" then
        path = path .. "?" .. parsed[5]
    end

    local res, req_err = httpc:request({
        method  = opts.method or "POST",
        path    = path,
        headers = opts.headers or {},
        body    = opts.body,
    })

    if not res then
        httpc:close()
        return nil, nil, nil, "request: " .. tostring(req_err)
    end

    if opts.stream then
        -- Caller is responsible for reading res.body_reader and calling httpc:set_keepalive
        return res.status, res.headers, res.body_reader, nil, httpc
    end

    local body, read_err = res:read_body()
    if not body then
        httpc:close()
        return res.status, res.headers, nil, "read_body: " .. tostring(read_err)
    end
    httpc:set_keepalive()

    return res.status, res.headers, body, nil
end

return M
