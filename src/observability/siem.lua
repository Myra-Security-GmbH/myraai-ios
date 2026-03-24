-- observability/siem.lua — async SIEM event streaming
--
-- Supported backends:
--   splunk_hec    HTTP Event Collector (Splunk)
--   elasticsearch POST to /<index>/_doc with optional basic auth
--   vector        POST JSON to Vector HTTP source
--   syslog        UDP/TCP socket, CEF or RFC5424 format
--
-- Config shape (in gateway_config.siem or tenant.siem_config):
--   {
--     type   = "splunk_hec" | "elasticsearch" | "vector" | "syslog",
--     events = {"blocked","guardrail","scrubbed","all"},  -- nil/{}→["blocked"]
--
--     -- splunk_hec
--     url   = "https://splunk:8088/services/collector/event",
--     token = "Splunk-HEC-token",
--     index = "ai-gateway",   -- optional
--
--     -- elasticsearch / vector  (shared HTTP shape)
--     url      = "https://es:9200",
--     index    = "aig-logs",  -- ES only; ignored for vector
--     username = "...",       -- ES basic auth; omit for vector
--     password = "...",
--
--     -- syslog
--     host     = "siem.corp.com",
--     port     = 514,
--     protocol = "udp" | "tcp",       -- default: udp
--     format   = "cef" | "rfc5424",   -- default: cef
--   }
--
-- Delivery is fire-and-forget (ngx.timer.at) — never blocks the request path.

local json = require("utils.json")
local M    = {}

-- ---------------------------------------------------------------------------
-- Event filter
-- ---------------------------------------------------------------------------

-- Returns true when the log record should be forwarded to the SIEM.
-- Default (no events configured) → only blocked requests.
local function should_emit(events, fields)
    if type(events) ~= "table" or #events == 0 then
        return fields.blocked == true
    end
    for _, e in ipairs(events) do
        if e == "all"      then return true end
        if e == "blocked"  and fields.blocked == true then return true end
        if e == "guardrail" then
            local df = fields.detectors_fired
            if type(df) == "table" and #df > 0 then return true end
        end
        if e == "scrubbed" and fields.scrub_applied == true then return true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- HTTP delivery helper (Splunk, ES, Vector)
-- ---------------------------------------------------------------------------

local function deliver_http(_, url, payload, headers)
    local ok, http = pcall(require, "resty.http")
    if not ok then
        ngx.log(ngx.WARN, "siem: resty.http unavailable, skipping delivery to ", url)
        return
    end
    local httpc = http.new()
    httpc:set_timeout(5000)
    local res, err = httpc:request_uri(url, {
        method  = "POST",
        body    = payload,
        headers = headers,
    })
    if err then
        ngx.log(ngx.WARN, "siem: delivery error to ", url, ": ", err)
    elseif res and res.status >= 400 then
        ngx.log(ngx.WARN, "siem: server returned HTTP ", res.status, " for ", url)
    end
end

-- ---------------------------------------------------------------------------
-- Splunk HEC
-- ---------------------------------------------------------------------------

local function emit_splunk(cfg, fields)
    local payload = json.encode({
        time       = ngx.now(),
        sourcetype = "_json",
        index      = cfg.index,
        event      = fields,
    })
    if not payload then return end
    local headers = {
        ["Content-Type"]  = "application/json",
        ["Authorization"] = "Splunk " .. (cfg.token or ""),
        ["User-Agent"]    = "AI-Gateway-SIEM/1.0",
    }
    local ok, err = ngx.timer.at(0, deliver_http, cfg.url, payload, headers)
    if not ok then ngx.log(ngx.WARN, "siem: timer.at failed: ", err) end
end

-- ---------------------------------------------------------------------------
-- Elasticsearch
-- ---------------------------------------------------------------------------

local function emit_elasticsearch(cfg, fields)
    local payload = json.encode(fields)
    if not payload then return end
    local index = cfg.index or "aig-logs"
    local url   = (cfg.url or "") .. "/" .. index .. "/_doc"
    local headers = {
        ["Content-Type"] = "application/json",
        ["User-Agent"]   = "AI-Gateway-SIEM/1.0",
    }
    if cfg.username and cfg.password then
        local creds = (cfg.username or "") .. ":" .. (cfg.password or "")
        if ngx.encode_base64 then
            headers["Authorization"] = "Basic " .. ngx.encode_base64(creds)
        end
    end
    local ok, err = ngx.timer.at(0, deliver_http, url, payload, headers)
    if not ok then ngx.log(ngx.WARN, "siem: timer.at failed: ", err) end
end

-- ---------------------------------------------------------------------------
-- Vector HTTP source
-- ---------------------------------------------------------------------------

local function emit_vector(cfg, fields)
    local payload = json.encode(fields)
    if not payload then return end
    local headers = {
        ["Content-Type"] = "application/json",
        ["User-Agent"]   = "AI-Gateway-SIEM/1.0",
    }
    local ok, err = ngx.timer.at(0, deliver_http, cfg.url, payload, headers)
    if not ok then ngx.log(ngx.WARN, "siem: timer.at failed: ", err) end
end

-- ---------------------------------------------------------------------------
-- Syslog / CEF
-- ---------------------------------------------------------------------------

local function cef_escape(s)
    if type(s) ~= "string" then s = tostring(s or "") end
    return s:gsub("\\", "\\\\"):gsub("|", "\\|"):gsub("=", "\\=")
end

local function build_cef(fields)
    local blocked_by = fields.blocked_by or ""
    local severity   = fields.blocked and 7 or 3
    local event_class, event_name
    if fields.blocked_by == "guardrail" or fields.blocked_by == "detector" then
        event_class = "GUARDRAIL_BLOCK"
        event_name  = "Request blocked by guardrail"
    elseif fields.blocked_by == "rate_limit" then
        event_class = "RATE_LIMIT"
        event_name  = "Request rate limited"
    elseif fields.blocked_by == "ip_allowlist" then
        event_class = "IP_BLOCKED"
        event_name  = "Request blocked by IP allowlist"
    elseif fields.blocked_by == "quota" then
        event_class = "QUOTA_EXCEEDED"
        event_name  = "Request blocked by quota"
    elseif fields.scrub_applied then
        event_class = "PII_SCRUB"
        event_name  = "PII scrubbed from request"
        severity    = 5
    else
        event_class = "INFERENCE"
        event_name  = "AI inference request"
        severity    = 1
    end

    local detectors = ""
    if type(fields.detectors_fired) == "table" then
        detectors = table.concat(fields.detectors_fired, ",")
    end

    local ext = string.format(
        "src=%s duser=%s cs1Label=blocked_by cs1=%s cs2Label=block_reason cs2=%s " ..
        "cs3Label=detectors cs3=%s cs4Label=guardrail_verdict cs4=%s " ..
        "cn1Label=status cn1=%s cn2Label=cost_usd cn2=%s " ..
        "cs5Label=provider cs5=%s cs6Label=model cs6=%s " ..
        "cs7Label=tenant_id cs7=%s cs8Label=gateway_id cs8=%s",
        cef_escape(fields.tenant_id  or ""),
        cef_escape(fields.user_id    or ""),
        cef_escape(blocked_by),
        cef_escape(fields.block_reason or ""),
        cef_escape(detectors),
        cef_escape(fields.guardrail_verdict or ""),
        tostring(fields.status  or ""),
        tostring(fields.cost_usd or ""),
        cef_escape(fields.provider  or ""),
        cef_escape(fields.model     or ""),
        cef_escape(fields.tenant_id  or ""),
        cef_escape(fields.gateway_id or "")
    )

    return string.format("CEF:0|AI-Gateway|ai-gateway|1.0|%s|%s|%d|%s",
        event_class, event_name, severity, ext)
end

local function build_rfc5424(fields)
    -- Minimal RFC5424: <priority>version timestamp hostname app-name procid msgid msg
    local priority = 134  -- facility=16 (local0), severity=6 (informational)
    if fields.blocked then priority = 131 end  -- severity=3 (error)
    local ts = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local payload = json.encode(fields) or "{}"
    return string.format("<%d>1 %s ai-gateway - - - %s", priority, ts, payload)
end

local function deliver_udp(_, host, port, msg)
    local sock = ngx.socket.udp()
    local ok, err = sock:setpeername(host, port)
    if not ok then
        ngx.log(ngx.WARN, "siem: udp connect error to ", host, ":", port, " — ", err)
        return
    end
    local send_ok, send_err = sock:send(msg)
    if not send_ok then
        ngx.log(ngx.WARN, "siem: udp send error: ", send_err)
    end
    sock:close()
end

local function deliver_tcp(_, host, port, msg)
    local sock = ngx.socket.tcp()
    local ok, err = sock:connect(host, port)
    if not ok then
        ngx.log(ngx.WARN, "siem: tcp connect error to ", host, ":", port, " — ", err)
        return
    end
    -- Syslog TCP framing: octet-counting (RFC5425) or newline-delimited
    local send_ok, send_err = sock:send(msg .. "\n")
    if not send_ok then
        ngx.log(ngx.WARN, "siem: tcp send error: ", send_err)
    end
    sock:close()
end

local function emit_syslog(cfg, fields)
    local host     = cfg.host or "localhost"
    local port     = cfg.port or 514
    local protocol = cfg.protocol or "udp"
    local fmt      = cfg.format   or "cef"

    local msg = (fmt == "rfc5424") and build_rfc5424(fields) or build_cef(fields)

    local ok, err
    if protocol == "tcp" then
        ok, err = ngx.timer.at(0, deliver_tcp, host, port, msg)
    else
        ok, err = ngx.timer.at(0, deliver_udp, host, port, msg)
    end
    if not ok then ngx.log(ngx.WARN, "siem: timer.at failed: ", err) end
end

-- ---------------------------------------------------------------------------
-- Public entry point
-- ---------------------------------------------------------------------------

function M.emit(siem_cfg, fields)
    if type(siem_cfg) ~= "table" then return end
    if not should_emit(siem_cfg.events, fields) then return end

    local t = siem_cfg.type
    if     t == "splunk_hec"    then emit_splunk(siem_cfg, fields)
    elseif t == "elasticsearch" then emit_elasticsearch(siem_cfg, fields)
    elseif t == "vector"        then emit_vector(siem_cfg, fields)
    elseif t == "syslog"        then emit_syslog(siem_cfg, fields)
    else
        ngx.log(ngx.WARN, "siem: unknown backend type: ", tostring(t))
    end
end

return M
