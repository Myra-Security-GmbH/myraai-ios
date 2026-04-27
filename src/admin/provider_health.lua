-- admin/provider_health.lua
-- Background job: poll known provider status pages every 5 minutes and store
-- results in the provider_health table.  Started from init_worker on worker 0.

local http    = require("resty.http")
local json    = require("utils.json")
local storage = require("storage")

local INTERVAL = 300  -- 5 minutes

-- Atlassian Statuspage JSON API (returns { status: { indicator, description } }).
-- Providers not listed here are shown as status=unknown with no last-checked time.
-- Direct (non-redirecting) Atlassian Statuspage JSON endpoints.
-- All verified to return { status: { indicator, description } } without redirects.
-- Providers not listed here have no public machine-readable status page.
local STATUS_PAGES = {
    anthropic  = "https://status.claude.com/api/v2/status.json",
    openai     = "https://status.openai.com/api/v2/status.json",
    cohere     = "https://status.cohere.com/api/v2/status.json",
    groq       = "https://groqstatus.com/api/v2/status.json",
    cloudflare = "https://www.cloudflarestatus.com/api/v2/status.json",
}

local function indicator_to_status(indicator)
    if indicator == "none"  then return "ok"       end
    if indicator == "minor" then return "degraded" end
    return "down"  -- major, critical, or unknown indicator
end

local function poll_one(provider, url)
    local httpc = http.new()
    httpc:set_timeout(8000)
    local t0  = ngx.now()
    local res, conn_err = httpc:request_uri(url, {
        method  = "GET",
        headers = { ["User-Agent"] = "ai-gateway-health/1.0" },
        ssl_verify = true,
    })
    local latency = math.floor((ngx.now() - t0) * 1000)
    httpc:close()

    if not res or res.status ~= 200 then
        local msg = conn_err or ("HTTP " .. (res and tostring(res.status) or "?"))
        storage.upsert_provider_health(provider, "down", msg, nil)
        return
    end

    local ok, data = pcall(json.decode, res.body)
    if not ok or type(data) ~= "table" then
        storage.upsert_provider_health(provider, "down", "bad JSON", nil)
        return
    end

    local indicator = data.status and data.status.indicator
    local message   = data.status and data.status.description
    storage.upsert_provider_health(
        provider,
        indicator_to_status(indicator or "major"),
        message,
        latency
    )
end

local function run_poll(premature)
    if premature then return end
    for provider, url in pairs(STATUS_PAGES) do
        local ok, err = pcall(poll_one, provider, url)
        if not ok then
            ngx.log(ngx.WARN, "provider_health: poll error for ", provider, ": ", tostring(err))
        end
    end
    -- Remove rows for providers no longer in STATUS_PAGES (handles URL set changes)
    local ok2, err2 = pcall(storage.cleanup_provider_health, STATUS_PAGES)
    if not ok2 then
        ngx.log(ngx.WARN, "provider_health: cleanup error: ", tostring(err2))
    end
end

local M = {}

-- Expose the map so api.lua can reference it for has_status_page without duplicating.
M.STATUS_PAGES = STATUS_PAGES

function M.start_timer()
    ngx.timer.at(10, run_poll)            -- first run 10 s after startup
    ngx.timer.every(INTERVAL, run_poll)   -- then every 5 minutes
end

return M
