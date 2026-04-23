-- utils/webhook.lua — fire-and-forget webhook delivery
--
-- Config shape (in gateway_config.webhooks):
--   {
--     url    = "https://hooks.example.com/aig",
--     secret = "optional-hmac-key",   -- signs body as X-AIG-Signature: sha256=<hex>
--     events = {"blocked", "budget_exceeded", "circuit_open"},  -- nil = all events
--   }
--
-- Payload (JSON POST to url):
--   { event, gateway_id, tenant_id, ts, data:{...} }
--
-- Delivery is asynchronous (ngx.timer.at) — never blocks the request path.

local json    = require("utils.json")
local sha256  = require("resty.sha256")
local rstr    = require("resty.string")
local bit     = require("bit")

local M = {}

-- HMAC-SHA256 (RFC 2104) using resty.sha256.
local BLOCK_SIZE = 64
local function hmac_sha256(key, message)
    if #key > BLOCK_SIZE then
        local kh = sha256:new(); kh:update(key); key = kh:final()
    end
    local ipad, opad = {}, {}
    for i = 1, BLOCK_SIZE do
        local kb = i <= #key and key:byte(i) or 0
        ipad[i] = string.char(bit.bxor(kb, 0x36))
        opad[i] = string.char(bit.bxor(kb, 0x5c))
    end
    local inner = sha256:new()
    inner:update(table.concat(ipad))
    inner:update(message)
    local inner_hash = inner:final()
    local outer = sha256:new()
    outer:update(table.concat(opad))
    outer:update(inner_hash)
    return rstr.to_hex(outer:final())
end

local function sign(secret, body)
    return hmac_sha256(secret, body)
end

-- Deliver one webhook.  Called inside ngx.timer.at — no return value used.
local function deliver(_, url, payload, sig)
    local ok, http = pcall(require, "resty.http")
    if not ok then
        ngx.log(ngx.WARN, "webhook: resty.http unavailable, skipping delivery to ", url)
        return
    end
    local httpc = http.new()
    httpc:set_timeout(5000)
    local headers = {
        ["Content-Type"] = "application/json",
        ["User-Agent"]   = "AI-Gateway-Webhook/1.0",
    }
    if sig then
        headers["X-AIG-Signature"] = "sha256=" .. sig
    end
    local res, err = httpc:request_uri(url, {
        method  = "POST",
        body    = payload,
        headers = headers,
    })
    if err then
        ngx.log(ngx.WARN, "webhook: delivery error to ", url, ": ", err)
    elseif res and res.status >= 400 then
        ngx.log(ngx.WARN, "webhook: server returned HTTP ", res.status, " for ", url)
    end
end

-- Public: fire an event webhook asynchronously (no-op if not configured).
--
--   webhook_cfg  — table {url, secret?, events?} from gateway_config.webhooks
--   event        — string: "blocked" | "budget_exceeded" | "circuit_open"
--   data         — table of event-specific fields (serialised into payload.data)
--   ctx_info     — table {gateway_id?, tenant_id?}
function M.fire(webhook_cfg, event, data, ctx_info)
    if not webhook_cfg or type(webhook_cfg) ~= "table" then return end
    local url = webhook_cfg.url
    if not url or url == "" then return end

    -- Filter by subscribed event list (absent = subscribe to all events)
    local events = webhook_cfg.events
    if type(events) == "table" then
        local match = false
        for _, e in ipairs(events) do
            if e == event then match = true; break end
        end
        if not match then return end
    end

    local info = ctx_info or {}
    local payload = json.encode({
        event      = event,
        gateway_id = info.gateway_id,
        tenant_id  = info.tenant_id,
        ts         = ngx.time(),
        data       = data or {},
    })
    if not payload then return end

    local sig = webhook_cfg.secret and sign(webhook_cfg.secret, payload)

    local ok, err = ngx.timer.at(0, deliver, url, payload, sig)
    if not ok then
        ngx.log(ngx.WARN, "webhook: timer.at failed: ", err)
    end
end

return M
