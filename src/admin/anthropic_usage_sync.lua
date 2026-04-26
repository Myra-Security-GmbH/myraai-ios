-- admin/anthropic_usage_sync.lua — Anthropic per-tenant usage sync
--
-- Hourly timer fetches usage from the Anthropic Admin API for every tenant
-- that has an 'anthropic-admin' provider key configured, then upserts daily
-- snapshots into anthropic_usage_snapshot.
--
-- Runs from worker 0 only. Also callable via POST /admin/v1/anthropic-usage/sync.

local storage = require("storage")
local byok    = require("auth.byok")
local cfg     = require("core.app_config")
local cjson   = require("cjson.safe")

local M = {}

local ANTHROPIC_BASE  = "https://api.anthropic.com"
local SYNC_INTERVAL   = 3600   -- 1 hour
local STARTUP_DELAY   = 90     -- seconds after startup before first sync

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function rfc3339(unix_ts)
    return os.date("!%Y-%m-%dT%H:%M:%SZ", unix_ts)
end

-- UTC day boundary (midnight) offset by days_offset from today.
local function utc_day(days_offset)
    local t = os.time()
    return math.floor(t / 86400) * 86400 + days_offset * 86400
end

-- YYYY-MM-DD string from a Unix timestamp (UTC).
local function date_str(unix_ts)
    return os.date("!%Y-%m-%d", unix_ts)
end

-- Fetch one page from the Anthropic usage report.
-- Returns decoded body or nil, err.
local function fetch_usage_page(admin_key, starting_at, ending_at, page_cursor)
    local httpc = require("resty.http").new()
    httpc:set_timeout(20000)

    local qs = "bucket_width=1d"
        .. "&starting_at=" .. ngx.escape_uri(starting_at)
        .. "&ending_at="   .. ngx.escape_uri(ending_at)
        .. "&group_by[]=model&group_by[]=service_tier"
    if page_cursor then
        qs = qs .. "&page=" .. ngx.escape_uri(page_cursor)
    end

    local res, err = httpc:request_uri(ANTHROPIC_BASE .. "/v1/organizations/usage_report/messages?" .. qs, {
        method  = "GET",
        headers = {
            ["x-api-key"]          = admin_key,
            ["anthropic-version"]  = "2023-06-01",
            ["accept"]             = "application/json",
        },
        ssl_verify = true,
    })
    if not res then return nil, "HTTP error: " .. tostring(err) end
    if res.status == 401 or res.status == 403 then
        return nil, "admin key rejected (HTTP " .. res.status .. ")"
    end
    if res.status ~= 200 then
        return nil, "HTTP " .. res.status .. ": " .. (res.body or ""):sub(1, 200)
    end
    local body = cjson.decode(res.body)
    if not body then return nil, "invalid JSON response" end
    return body
end

-- Collect all per-model result rows for the given date window, handling pagination.
-- The API nests model rows under data[i].results — we flatten them here, attaching
-- the parent bucket's start_time so parse_bucket can derive the snapshot date.
-- Returns flat list of result rows, or nil, err.
local function fetch_all_usage(admin_key, starting_at, ending_at)
    local buckets = {}
    local cursor  = nil
    local pages   = 0

    repeat
        pages = pages + 1
        if pages > 20 then
            return nil, "too many pages (>20) — aborting"
        end

        local body, err = fetch_usage_page(admin_key, starting_at, ending_at, cursor)
        if not body then return nil, err end

        local data = body.data or {}
        for _, item in ipairs(data) do
            local results = item.results or {}
            for _, result in ipairs(results) do
                result._start_time = item.start_time  -- attach date from parent bucket
                buckets[#buckets + 1] = result
            end
        end

        cursor = body.has_more and body.next_page or nil
    until not cursor

    return buckets
end

-- Compute cost_usd for a usage bucket row using model_price table.
-- Batch tier gets 50% discount. Priority tier: unknown pricing, skip cost.
local function compute_cost(model, service_tier, u)
    if service_tier == "priority" or service_tier == "priority_on_demand" then
        return 0  -- different billing model, cannot compute
    end

    local price, _ = storage.get_model_pricing("anthropic", model)
    if not price then return 0 end

    local inp  = price.input_per_1k          or 0
    local out  = price.output_per_1k         or 0
    local cw5m = price.cache_write_per_1k    or 0
    local cw1h = price.cache_write_1h_per_1k or cw5m * 1.6
    local cr   = price.cache_read_per_1k     or 0

    local cost = (
        (u.uncached_input_tokens or 0) * inp  +
        (u.output_tokens         or 0) * out  +
        (u.cache_write_5m        or 0) * cw5m +
        (u.cache_write_1h        or 0) * cw1h +
        (u.cache_read_tokens     or 0) * cr
    ) / 1000

    if service_tier == "batch" then cost = cost * 0.5 end
    return cost
end

-- Parse one result row (from data[i].results[]) into our snapshot row shape.
-- The Anthropic API nests usage fields flat on the result object — no .usage wrapper.
local function parse_bucket(result, tenant_id, source)
    local model     = result.model        or ""
    local tier      = result.service_tier or "standard"
    local snap_date = date_str(result._start_time or os.time())

    local cc   = result.cache_creation or {}
    local cw5m = cc.ephemeral_5m_input_tokens or 0
    local cw1h = cc.ephemeral_1h_input_tokens or 0

    local tokens = {
        uncached_input_tokens = result.uncached_input_tokens or 0,
        output_tokens         = result.output_tokens         or 0,
        cache_write_5m        = cw5m,
        cache_write_1h        = cw1h,
        cache_read_tokens     = result.cache_read_input_tokens or 0,
    }

    local web_searches = 0
    if result.server_tool_use then
        web_searches = result.server_tool_use.web_search_requests or 0
    end

    local cost = compute_cost(model, tier, tokens)

    return {
        tenant_id             = tenant_id,
        snapshot_date         = snap_date,
        source                = source,
        model                 = model,
        service_tier          = tier,
        uncached_input_tokens = tokens.uncached_input_tokens,
        output_tokens         = tokens.output_tokens,
        cache_write_5m_tokens = cw5m,
        cache_write_1h_tokens = cw1h,
        cache_read_tokens     = tokens.cache_read_tokens,
        web_search_requests   = web_searches,
        cost_usd              = string.format("%.8f", cost),
    }
end

-- ---------------------------------------------------------------------------
-- Per-tenant sync
-- ---------------------------------------------------------------------------

local function sync_tenant(tenant_row, starting_at, ending_at)
    local tenant_id = tenant_row.tenant_id

    -- Decrypt the admin key stored under provider='anthropic-admin'.
    local admin_key, err = byok.get_tenant_key(tenant_id, "anthropic-admin", "default")
    if not admin_key then
        ngx.log(ngx.WARN, "anthropic_usage_sync: tenant ", tenant_id,
                " key unavailable: ", tostring(err))
        return
    end

    local buckets, ferr = fetch_all_usage(admin_key, starting_at, ending_at)
    if not buckets then
        ngx.log(ngx.ERR, "anthropic_usage_sync: tenant ", tenant_id,
                " fetch failed: ", tostring(ferr))
        return
    end

    local upserted = 0
    for _, bucket in ipairs(buckets) do
        local row = parse_bucket(bucket, tenant_id, "byok")
        local uerr = storage.upsert_anthropic_usage(row)
        if uerr then
            ngx.log(ngx.WARN, "anthropic_usage_sync: upsert failed for tenant ",
                    tenant_id, ": ", tostring(uerr))
        else
            upserted = upserted + 1
        end
    end

    ngx.log(ngx.NOTICE, "anthropic_usage_sync: tenant ", tenant_id,
            " synced ", upserted, " bucket(s)")
end

-- ---------------------------------------------------------------------------
-- Public: sync yesterday + today for all configured tenants
-- ---------------------------------------------------------------------------

function M.sync_recent()
    -- Fetch the last 30 days (complete) and today (partial).
    -- ending_at is exclusive, so use day+2 to include today's bucket
    -- (which ends at tomorrow midnight UTC).
    local starting_at = rfc3339(utc_day(-30))
    local ending_at   = rfc3339(utc_day(2))

    local tenants, err = storage.list_tenants_with_anthropic_admin_key()
    if err then
        ngx.log(ngx.ERR, "anthropic_usage_sync: list tenants failed: ", tostring(err))
        return
    end
    if #tenants == 0 then return end

    ngx.log(ngx.NOTICE, "anthropic_usage_sync: syncing ", #tenants, " tenant(s)")
    for _, row in ipairs(tenants) do
        local ok, serr = pcall(sync_tenant, row, starting_at, ending_at)
        if not ok then
            ngx.log(ngx.ERR, "anthropic_usage_sync: tenant ", row.tenant_id,
                    " error: ", tostring(serr))
        end
    end
end

-- ---------------------------------------------------------------------------
-- Self-scheduling timer (called from init_worker on worker 0)
-- ---------------------------------------------------------------------------

function M.start_timer()
    ngx.timer.at(STARTUP_DELAY, function(premature)
        if premature then return end
        local ok, err = pcall(M.sync_recent)
        if not ok then
            ngx.log(ngx.ERR, "anthropic_usage_sync: initial sync failed: ", tostring(err))
        end
    end)

    ngx.timer.every(SYNC_INTERVAL, function(premature)
        if premature then return end
        local ok, err = pcall(M.sync_recent)
        if not ok then
            ngx.log(ngx.ERR, "anthropic_usage_sync: hourly sync failed: ", tostring(err))
        end
    end)
end

return M
