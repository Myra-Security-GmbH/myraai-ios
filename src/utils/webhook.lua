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

local M = {}

-- Compute a keyed SHA-256 digest used as a simple webhook signature.
-- Not a proper RFC 2104 HMAC, but provides message authentication when
-- the secret is kept private.  Compatible with standard HMAC-SHA256
-- when resty.hmac is available.
local function sign(secret, body)
    local ok, hmac_lib = pcall(require, "resty.hmac")
    if ok and hmac_lib.ALGOS then
        local h = hmac_lib:new(secret, hmac_lib.ALGOS.SHA256)
        if h then
            h:update(body)
            return rstr.to_hex(h:final())
        end
    end
    -- Fallback: keyed hash H(secret || body) — weaker but self-consistent
    local h = sha256:new()
    h:update(secret)
    h:update(body)
    return rstr.to_hex(h:final())
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
