-- utils/http.lua — lua-resty-http wrapper for upstream provider calls
local http_lib = require("resty.http")

local M = {}

local DEFAULT_TIMEOUT = 60000  -- 60s (LLM calls can be slow)

-- Perform an HTTP request to an upstream provider.
-- opts fields:
--   method, url, headers, body, timeout_ms, stream (bool)
-- Returns (status, headers, body_or_reader, err)
function M.request(opts)
    local httpc = http_lib.new()
    httpc:set_timeout(opts.timeout_ms or DEFAULT_TIMEOUT)

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
        return nil, nil, nil, "request: " .. tostring(req_err)
    end

    if opts.stream then
        -- Caller is responsible for reading res.body_reader and calling httpc:set_keepalive
        return res.status, res.headers, res.body_reader, nil, httpc
    end

    local body, read_err = res:read_body()
    httpc:set_keepalive()
    if not body then
        return res.status, res.headers, nil, "read_body: " .. tostring(read_err)
    end

    return res.status, res.headers, body, nil
end

return M
