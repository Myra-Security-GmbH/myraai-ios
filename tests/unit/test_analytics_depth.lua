-- tests/unit/test_analytics_depth.lua
-- Tests for storage.get_analytics_depth: latency percentiles + top models.
-- Run with: resty tests/runner.lua tests/unit/test_analytics_depth.lua

_G.ngx = {
    now    = function() return 1700000000.0 end,
    log    = function() end,
    exit   = function(s) error(s) end,
    status = 200,
    header = {},
    req    = { read_body = function() end, get_body_data = function() return nil end },
    var    = {},
    ctx    = {},
    ERR = 0, WARN = 1, INFO = 2,
}

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

rawset(_G, "sqlite3", {})
local sqlite3 = require("lsqlite3")

local CFG_PATH = "/tmp/test_gw_cfg_analytics.db"
local LOG_PATH = "/tmp/test_gw_log_analytics.db"
os.remove(CFG_PATH)
os.remove(LOG_PATH)

local storage = require("storage.sqlite")
local cfg = { sqlite = { config_db = CFG_PATH, logs_db = LOG_PATH } }
storage.migrate(cfg)
storage.init(cfg)

local insert_db = sqlite3.open(LOG_PATH)
local cfg_db2   = sqlite3.open(CFG_PATH)
local seq = 0

-- Fixtures for multi-tenant/gateway tests
local TENANT_A  = "aaaaaaaa-0000-0000-0000-000000000001"
local TENANT_B  = "bbbbbbbb-0000-0000-0000-000000000002"
local GATEWAY_1 = "gggggggg-0000-0000-0000-000000000001"
local GATEWAY_2 = "gggggggg-0000-0000-0000-000000000002"

cfg_db2:exec(string.format(
    "INSERT OR IGNORE INTO tenant (id, slug, plan, created_at) VALUES ('%s','tenant-a','standard',1700000000)", TENANT_A))
cfg_db2:exec(string.format(
    "INSERT OR IGNORE INTO tenant (id, slug, plan, created_at) VALUES ('%s','tenant-b','free',1700000000)", TENANT_B))
cfg_db2:exec(string.format(
    "INSERT OR IGNORE INTO gateway (id, slug, tenant_id, config, created_at) VALUES ('%s','prod-gw','%s','{}',1700000000)",
    GATEWAY_1, TENANT_A))
cfg_db2:exec(string.format(
    "INSERT OR IGNORE INTO gateway (id, slug, tenant_id, config, created_at) VALUES ('%s','dev-gw','%s','{}',1700000000)",
    GATEWAY_2, TENANT_B))

-- ts is 1 hour before ngx.now() — always within the default 24h window
local RECENT_TS_MS = (math.floor(ngx.now()) - 3600) * 1000
local SINCE_MS = (math.floor(ngx.now()) - 3600) * 1000

local function insert_req(opts)
    seq = seq + 1
    local id = string.format("req-%05d", seq)
    local sql = string.format([[
        INSERT INTO request_log
            (id, tenant_id, gateway_id, provider, model, status,
             cached, input_tokens, output_tokens,
             cache_creation_tokens, cache_read_tokens,
             cost_usd, latency_ms, ts,
             meta, blocked, upstream_attempts, request_size_bytes, scrub_applied)
        VALUES ('%s','t1','g1','%s','%s',200,
                0,10,20,0,0,
                %f,%d,
                %d,
                '{}', %d, 1, 512, 0)
    ]], id,
        opts.provider  or "openai",
        opts.model     or "gpt-4o",
        opts.cost_usd  or 0.001,
        opts.latency   or 100,
        opts.ts_ms     or RECENT_TS_MS,
        opts.blocked   or 0)
    insert_db:exec(sql)
end

-- Extended insert for multi-tenant/gateway tests.
-- opts: blocked, cached, scrub_applied, cost_usd, saved_cost_usd,
--       latency_ms, model, provider, input_tokens, offset_sec
local function insert_req2(tenant_id, gateway_id, opts)
    seq = seq + 1
    opts = opts or {}
    local offset_sec = opts.offset_sec or -10
    local ts_ms = (math.floor(ngx.now()) + offset_sec) * 1000
    -- user_id: NULL when omitted, otherwise quoted string
    local user_id_sql = opts.user_id and ("'" .. opts.user_id .. "'") or "NULL"
    local sql = string.format([[
        INSERT INTO request_log
            (id, tenant_id, gateway_id, provider, model, status,
             cached, input_tokens, output_tokens,
             cache_creation_tokens, cache_read_tokens,
             cost_usd, saved_cost_usd, latency_ms, ts,
             meta, blocked, scrub_applied, upstream_attempts, request_size_bytes,
             user_id)
        VALUES ('req2-%04d','%s','%s','%s','%s',%d,
                %d,%d,20,0,0,
                %.6f,%.6f,%d,
                %d,
                '{}', %d, %d, 1, 512,
                %s)
    ]], seq, tenant_id, gateway_id,
        opts.provider or "openai",
        opts.model or "gpt-4o",
        opts.status or 200,
        opts.cached or 0,
        opts.input_tokens or 10,
        opts.cost_usd or 0.001,
        opts.saved_cost_usd or 0.0,
        opts.latency_ms or 100,
        ts_ms,
        opts.blocked or 0,
        opts.scrub_applied or 0,
        user_id_sql)
    insert_db:exec(sql)
end

-- ─── percentiles ─────────────────────────────────────────────────────────────

describe("get_analytics_depth: latency percentiles", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("returns result table with percentiles key even when empty", function()
        local r = storage.get_analytics_depth()
        assert.not_nil(r)
        assert.not_nil(r.percentiles)
        assert.not_nil(r.top_models)
    end)

    it("p50 is the median for 10 uniformly-spaced latencies", function()
        -- latencies: 10 20 30 40 50 60 70 80 90 100  (sorted)
        -- p50: rn <= 10*0.50 = 5  → rows 1-5 → MAX = 50
        for i = 1, 10 do
            insert_req({ latency = i * 10 })
        end
        local r = storage.get_analytics_depth()
        assert.equal(50, r.percentiles.p50)
    end)

    it("p95 is correct for 20-row dataset", function()
        -- latencies: 5 10 15 … 100  (20 rows)
        -- p95: rn <= 20*0.95 = 19 → MAX(latency of rows 1-19) = 95
        for i = 1, 20 do
            insert_req({ latency = i * 5 })
        end
        local r = storage.get_analytics_depth()
        assert.equal(95, r.percentiles.p95)
    end)

    it("p99 is correct for 100-row dataset", function()
        -- latencies: 1 2 3 … 100
        -- p99: rn <= 100*0.99 = 99 → MAX = 99
        for i = 1, 100 do
            insert_req({ latency = i })
        end
        local r = storage.get_analytics_depth()
        assert.equal(99, r.percentiles.p99)
    end)

    it("blocked rows are excluded from percentile calculation", function()
        -- 5 non-blocked rows, all latency = 100
        for _ = 1, 5 do
            insert_req({ latency = 100, blocked = 0 })
        end
        -- 5 blocked rows with very high latency — must be excluded
        for _ = 1, 5 do
            insert_req({ latency = 9999, blocked = 1 })
        end
        local r = storage.get_analytics_depth()
        assert.equal(100, r.percentiles.p50)
        assert.equal(100, r.percentiles.p99)
    end)

    it("single row gives the same value for p50/p95/p99", function()
        insert_req({ latency = 42 })
        local r = storage.get_analytics_depth()
        assert.equal(42, r.percentiles.p50)
        assert.equal(42, r.percentiles.p95)
        assert.equal(42, r.percentiles.p99)
    end)
end)

-- ─── top_models ───────────────────────────────────────────────────────────────

describe("get_analytics_depth: top_models", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("returns models ordered by request count descending", function()
        for _ = 1, 5 do insert_req({ model = "gpt-4o",   provider = "openai"    }) end
        for _ = 1, 2 do insert_req({ model = "claude-3", provider = "anthropic" }) end

        local r = storage.get_analytics_depth()
        assert.is_true(#r.top_models >= 2)
        assert.equal("gpt-4o",   r.top_models[1].model)
        assert.equal(5,          r.top_models[1].requests)
        assert.equal("claude-3", r.top_models[2].model)
        assert.equal(2,          r.top_models[2].requests)
    end)

    it("aggregates cost_usd per model", function()
        for _ = 1, 3 do
            insert_req({ model = "gpt-4o", provider = "openai", cost_usd = 0.002 })
        end
        local r = storage.get_analytics_depth()
        assert.equal(1, #r.top_models)
        -- 3 × 0.002 = 0.006; ROUND(x,4) keeps 4 decimal places
        assert.is_true(r.top_models[1].cost_usd > 0.005)
    end)

    it("returns empty top_models when no data", function()
        local r = storage.get_analytics_depth()
        assert.equal(0, #r.top_models)
    end)

    it("groups by (provider, model) — same model name on different providers is separate", function()
        insert_req({ model = "llama3", provider = "ollama"  })
        insert_req({ model = "llama3", provider = "groq"    })
        local r = storage.get_analytics_depth()
        assert.equal(2, #r.top_models)
    end)

    it("respects since_ms — excludes rows older than the window", function()
        -- A row from 2 days ago — outside the default 24h window
        local old_ts = (math.floor(ngx.now()) - 2 * 86400) * 1000
        insert_req({ model = "old-model", provider = "openai", ts_ms = old_ts })

        -- Default (last 24h) should not see it
        local r_default = storage.get_analytics_depth()
        assert.equal(0, #r_default.top_models)

        -- Wide window (last 3 days) should see it
        local since_wide = (math.floor(ngx.now()) - 3 * 86400) * 1000
        local r_wide = storage.get_analytics_depth(since_wide)
        assert.equal(1, #r_wide.top_models)
        assert.equal("old-model", r_wide.top_models[1].model)
    end)

    it("top_models rows include avg_latency_ms field", function()
        insert_req({ model = "gpt-4o", provider = "openai", latency = 200 })
        insert_req({ model = "gpt-4o", provider = "openai", latency = 400 })
        local r = storage.get_analytics_depth()
        assert.equal(1, #r.top_models)
        assert.equal(300, r.top_models[1].avg_latency_ms)
    end)
end)

-- ─── since_ms parameter ──────────────────────────────────────────────────────

describe("get_analytics_depth: since_ms window parameter", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("explicit since_ms includes rows exactly at the boundary", function()
        local boundary = (math.floor(ngx.now()) - 7200) * 1000  -- 2h ago
        -- row at exactly boundary + 1ms
        insert_req({ ts_ms = boundary + 1, latency = 55 })
        -- row at boundary - 1ms (outside)
        insert_req({ ts_ms = boundary - 1, latency = 999 })

        local r = storage.get_analytics_depth(boundary)
        assert.equal(1, #r.top_models)
        assert.equal(55, r.percentiles.p50)
    end)
end)

-- ===========================================================================
-- get_analytics_depth: by_tenant extended fields
-- ===========================================================================

describe("get_analytics_depth: by_tenant blocked count", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("blocked is zero when no blocked or scrubbed requests", function()
        insert_req2(TENANT_A, GATEWAY_1)
        local d = storage.get_analytics_depth(SINCE_MS)
        local row = d.by_tenant[1]
        assert.equal(0, row.blocked)
    end)

    it("counts blocked=1 rows", function()
        insert_req2(TENANT_A, GATEWAY_1, { blocked = 1 })
        insert_req2(TENANT_A, GATEWAY_1, { blocked = 1 })
        insert_req2(TENANT_A, GATEWAY_1)
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(2, d.by_tenant[1].blocked)
    end)

    it("counts scrub_applied rows toward blocked", function()
        insert_req2(TENANT_A, GATEWAY_1, { scrub_applied = 1 })
        insert_req2(TENANT_A, GATEWAY_1)
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(1, d.by_tenant[1].blocked)
    end)

    it("blocked is per-tenant", function()
        insert_req2(TENANT_A, GATEWAY_1, { blocked = 1 })
        insert_req2(TENANT_A, GATEWAY_1, { blocked = 1 })
        insert_req2(TENANT_B, GATEWAY_2, { blocked = 1 })
        local d = storage.get_analytics_depth(SINCE_MS)
        local by_id = {}
        for _, r in ipairs(d.by_tenant) do by_id[r.tenant_id] = r end
        assert.equal(2, by_id[TENANT_A].blocked)
        assert.equal(1, by_id[TENANT_B].blocked)
    end)
end)

describe("get_analytics_depth: by_tenant cached count", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("cached is zero when no cached requests", function()
        insert_req2(TENANT_A, GATEWAY_1)
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(0, d.by_tenant[1].cached)
    end)

    it("counts cached=1 rows", function()
        insert_req2(TENANT_A, GATEWAY_1, { cached = 1 })
        insert_req2(TENANT_A, GATEWAY_1, { cached = 1 })
        insert_req2(TENANT_A, GATEWAY_1)
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(2, d.by_tenant[1].cached)
    end)
end)

describe("get_analytics_depth: by_tenant saved_cost_usd", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("saved_cost_usd is zero when no savings", function()
        insert_req2(TENANT_A, GATEWAY_1)
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(0, d.by_tenant[1].saved_cost_usd)
    end)

    it("sums saved_cost_usd across requests", function()
        insert_req2(TENANT_A, GATEWAY_1, { saved_cost_usd = 0.01 })
        insert_req2(TENANT_A, GATEWAY_1, { saved_cost_usd = 0.02 })
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.near(0.03, d.by_tenant[1].saved_cost_usd, 0.0001)
    end)

    it("saved_cost_usd is independent per tenant", function()
        insert_req2(TENANT_A, GATEWAY_1, { saved_cost_usd = 0.05 })
        insert_req2(TENANT_B, GATEWAY_2, { saved_cost_usd = 0.02 })
        local d = storage.get_analytics_depth(SINCE_MS)
        local by_id = {}
        for _, r in ipairs(d.by_tenant) do by_id[r.tenant_id] = r end
        assert.near(0.05, by_id[TENANT_A].saved_cost_usd, 0.0001)
        assert.near(0.02, by_id[TENANT_B].saved_cost_usd, 0.0001)
    end)
end)

describe("get_analytics_depth: by_tenant avg_latency_ms", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("averages latency of non-blocked requests", function()
        insert_req2(TENANT_A, GATEWAY_1, { latency_ms = 200 })
        insert_req2(TENANT_A, GATEWAY_1, { latency_ms = 400 })
        -- blocked rows must be excluded
        insert_req2(TENANT_A, GATEWAY_1, { latency_ms = 9999, blocked = 1 })
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.near(300, d.by_tenant[1].avg_latency_ms, 1)
    end)

    it("avg_latency_ms present in result row", function()
        insert_req2(TENANT_A, GATEWAY_1)
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.not_nil(d.by_tenant[1].avg_latency_ms)
    end)
end)

describe("get_analytics_depth: by_tenant ordering and slug resolution", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("orders tenants by cost_usd DESC", function()
        insert_req2(TENANT_B, GATEWAY_2, { cost_usd = 0.001 })
        insert_req2(TENANT_A, GATEWAY_1, { cost_usd = 0.100 })
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(TENANT_A, d.by_tenant[1].tenant_id)
    end)

    it("resolves tenant slug via JOIN on cfg.tenant", function()
        insert_req2(TENANT_A, GATEWAY_1)
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal("tenant-a", d.by_tenant[1].tenant)
    end)

    it("all extended fields present in each by_tenant row", function()
        insert_req2(TENANT_A, GATEWAY_1)
        local d = storage.get_analytics_depth(SINCE_MS)
        local r = d.by_tenant[1]
        assert.not_nil(r.requests)
        assert.not_nil(r.blocked)
        assert.not_nil(r.cached)
        assert.not_nil(r.cost_usd)
        assert.not_nil(r.saved_cost_usd)
    end)
end)

-- ===========================================================================
-- get_analytics_depth: by_gateway breakdown
-- ===========================================================================

describe("get_analytics_depth: by_gateway present in result", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("by_gateway key exists even when no data", function()
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.not_nil(d.by_gateway)
        assert.equal(0, #d.by_gateway)
    end)

    it("returns one row per distinct gateway", function()
        insert_req2(TENANT_A, GATEWAY_1)
        insert_req2(TENANT_A, GATEWAY_1)
        insert_req2(TENANT_B, GATEWAY_2)
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(2, #d.by_gateway)
    end)
end)

describe("get_analytics_depth: by_gateway slug and tenant resolution", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("resolves gateway slug from cfg.gateway", function()
        insert_req2(TENANT_A, GATEWAY_1)
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal("prod-gw", d.by_gateway[1].gateway)
    end)

    it("shows the tenant slug for each gateway row", function()
        insert_req2(TENANT_A, GATEWAY_1)
        insert_req2(TENANT_B, GATEWAY_2)
        local d = storage.get_analytics_depth(SINCE_MS)
        local by_gw = {}
        for _, r in ipairs(d.by_gateway) do by_gw[r.gateway_id] = r end
        assert.equal("tenant-a", by_gw[GATEWAY_1].tenant)
        assert.equal("tenant-b", by_gw[GATEWAY_2].tenant)
    end)
end)

describe("get_analytics_depth: by_gateway stats columns", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("aggregates request count per gateway", function()
        insert_req2(TENANT_A, GATEWAY_1)
        insert_req2(TENANT_A, GATEWAY_1)
        insert_req2(TENANT_A, GATEWAY_1)
        insert_req2(TENANT_B, GATEWAY_2)
        local d = storage.get_analytics_depth(SINCE_MS)
        local by_gw = {}
        for _, r in ipairs(d.by_gateway) do by_gw[r.gateway_id] = r end
        assert.equal(3, by_gw[GATEWAY_1].requests)
        assert.equal(1, by_gw[GATEWAY_2].requests)
    end)

    it("includes blocked count per gateway", function()
        insert_req2(TENANT_A, GATEWAY_1, { blocked = 1 })
        insert_req2(TENANT_A, GATEWAY_1, { blocked = 1 })
        insert_req2(TENANT_A, GATEWAY_1)
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(2, d.by_gateway[1].blocked)
    end)

    it("includes cached count per gateway", function()
        insert_req2(TENANT_A, GATEWAY_1, { cached = 1 })
        insert_req2(TENANT_A, GATEWAY_1)
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(1, d.by_gateway[1].cached)
    end)

    it("includes saved_cost_usd per gateway", function()
        insert_req2(TENANT_A, GATEWAY_1, { saved_cost_usd = 0.03 })
        insert_req2(TENANT_A, GATEWAY_1, { saved_cost_usd = 0.02 })
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.near(0.05, d.by_gateway[1].saved_cost_usd, 0.0001)
    end)

    it("orders by cost_usd DESC", function()
        insert_req2(TENANT_B, GATEWAY_2, { cost_usd = 0.001 })
        insert_req2(TENANT_A, GATEWAY_1, { cost_usd = 0.100 })
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(GATEWAY_1, d.by_gateway[1].gateway_id)
    end)
end)

-- ===========================================================================
-- get_stats_timeseries: tenant_id filter
-- ===========================================================================

describe("get_stats_timeseries: tenant_id filter", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("nil tenant_id returns all tenants", function()
        insert_req2(TENANT_A, GATEWAY_1, { cost_usd = 0.01 })
        insert_req2(TENANT_B, GATEWAY_2, { cost_usd = 0.02 })
        local ts = storage.get_stats_timeseries(3600, 24, nil, nil)
        local total = 0
        for _, p in ipairs(ts) do total = total + p.requests end
        assert.equal(2, total)
    end)

    it("filters to only the specified tenant's requests", function()
        insert_req2(TENANT_A, GATEWAY_1)
        insert_req2(TENANT_A, GATEWAY_1)
        insert_req2(TENANT_B, GATEWAY_2)
        local ts = storage.get_stats_timeseries(3600, 24, nil, TENANT_A)
        local total = 0
        for _, p in ipairs(ts) do total = total + p.requests end
        assert.equal(2, total)
    end)

    it("excludes other tenant's cost from filtered timeseries", function()
        insert_req2(TENANT_A, GATEWAY_1, { cost_usd = 0.01 })
        insert_req2(TENANT_B, GATEWAY_2, { cost_usd = 0.99 })
        local ts = storage.get_stats_timeseries(3600, 24, nil, TENANT_A)
        local total_cost = 0
        for _, p in ipairs(ts) do total_cost = total_cost + p.cost_usd end
        assert.near(0.01, total_cost, 0.0001)
    end)

    it("returns exactly n buckets even when tenant has no data", function()
        insert_req2(TENANT_B, GATEWAY_2)
        local ts = storage.get_stats_timeseries(3600, 24, nil, TENANT_A)
        assert.equal(24, #ts)
    end)

    it("zero-fills all buckets except the active one", function()
        insert_req2(TENANT_A, GATEWAY_1)
        local ts = storage.get_stats_timeseries(3600, 24, nil, TENANT_A)
        assert.equal(24, #ts)
        local nonzero = 0
        for _, p in ipairs(ts) do
            if p.requests > 0 then nonzero = nonzero + 1 end
        end
        assert.equal(1, nonzero)
    end)

    it("filtered blocked count reflects only that tenant", function()
        insert_req2(TENANT_A, GATEWAY_1, { blocked = 1 })
        insert_req2(TENANT_B, GATEWAY_2, { blocked = 1 })
        local ts = storage.get_stats_timeseries(3600, 24, nil, TENANT_A)
        local total_blocked = 0
        for _, p in ipairs(ts) do total_blocked = total_blocked + p.blocked end
        assert.equal(1, total_blocked)
    end)
end)

-- ===========================================================================
-- get_tenant_top_models
-- ===========================================================================

describe("get_tenant_top_models: basic filtering", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("returns empty when tenant has no requests", function()
        insert_req2(TENANT_B, GATEWAY_2)
        local models = storage.get_tenant_top_models(TENANT_A, SINCE_MS)
        assert.equal(0, #models)
    end)

    it("returns models used by the specified tenant", function()
        insert_req2(TENANT_A, GATEWAY_1, { model = "gpt-4o", provider = "openai" })
        insert_req2(TENANT_A, GATEWAY_1, { model = "gpt-4o", provider = "openai" })
        local models = storage.get_tenant_top_models(TENANT_A, SINCE_MS)
        assert.equal(1, #models)
        assert.equal("gpt-4o", models[1].model)
        assert.equal(2, models[1].requests)
    end)

    it("excludes other tenants' models", function()
        insert_req2(TENANT_A, GATEWAY_1, { model = "gpt-4o",      provider = "openai"    })
        insert_req2(TENANT_B, GATEWAY_2, { model = "claude-haiku", provider = "anthropic" })
        local models = storage.get_tenant_top_models(TENANT_A, SINCE_MS)
        assert.equal(1, #models)
        assert.equal("gpt-4o", models[1].model)
    end)

    it("orders by request count DESC", function()
        insert_req2(TENANT_A, GATEWAY_1, { model = "gpt-4o",        provider = "openai"    })
        insert_req2(TENANT_A, GATEWAY_1, { model = "gpt-4o",        provider = "openai"    })
        insert_req2(TENANT_A, GATEWAY_1, { model = "gpt-4o",        provider = "openai"    })
        insert_req2(TENANT_A, GATEWAY_1, { model = "claude-sonnet", provider = "anthropic" })
        local models = storage.get_tenant_top_models(TENANT_A, SINCE_MS)
        assert.equal(2, #models)
        assert.equal("gpt-4o", models[1].model)
        assert.equal(3, models[1].requests)
    end)
end)

describe("get_tenant_top_models: aggregations", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("aggregates cost_usd per model", function()
        insert_req2(TENANT_A, GATEWAY_1, { model = "gpt-4o", provider = "openai", cost_usd = 0.01 })
        insert_req2(TENANT_A, GATEWAY_1, { model = "gpt-4o", provider = "openai", cost_usd = 0.02 })
        local models = storage.get_tenant_top_models(TENANT_A, SINCE_MS)
        assert.near(0.03, models[1].cost_usd, 0.0001)
    end)

    it("computes avg_latency_ms per model", function()
        insert_req2(TENANT_A, GATEWAY_1, { model = "gpt-4o", provider = "openai", latency_ms = 200 })
        insert_req2(TENANT_A, GATEWAY_1, { model = "gpt-4o", provider = "openai", latency_ms = 400 })
        local models = storage.get_tenant_top_models(TENANT_A, SINCE_MS)
        assert.near(300, models[1].avg_latency_ms, 1)
    end)

    it("groups by provider+model — same name on different providers is two rows", function()
        insert_req2(TENANT_A, GATEWAY_1, { model = "llama3", provider = "ollama" })
        insert_req2(TENANT_A, GATEWAY_1, { model = "llama3", provider = "groq"   })
        local models = storage.get_tenant_top_models(TENANT_A, SINCE_MS)
        assert.equal(2, #models)
    end)

    it("respects since_ms cutoff", function()
        -- Old request outside window
        insert_req2(TENANT_A, GATEWAY_1, { model = "old-model", provider = "openai", offset_sec = -7200 })
        -- Recent request inside window
        insert_req2(TENANT_A, GATEWAY_1, { model = "new-model", provider = "openai" })
        local since_1h = (math.floor(ngx.now()) - 3600) * 1000
        local models = storage.get_tenant_top_models(TENANT_A, since_1h)
        assert.equal(1, #models)
        assert.equal("new-model", models[1].model)
    end)

    it("caps results at 10 models", function()
        for i = 1, 12 do
            insert_req2(TENANT_A, GATEWAY_1, { model = "model-" .. i, provider = "openai" })
        end
        local models = storage.get_tenant_top_models(TENANT_A, SINCE_MS)
        assert.is_true(#models <= 10)
    end)
end)

-- ─── errors field in by_tenant ────────────────────────────────────────────

describe("get_analytics_depth: errors field in by_tenant", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("errors field is present and zero when all requests succeed", function()
        insert_req2(TENANT_A, GATEWAY_1, { status = 200 })
        insert_req2(TENANT_A, GATEWAY_1, { status = 201 })
        local d = storage.get_analytics_depth(SINCE_MS)
        local r = d.by_tenant[1]
        assert.not_nil(r)
        assert.equal(0, r.errors)
    end)

    it("counts 4xx and 5xx responses as errors", function()
        insert_req2(TENANT_A, GATEWAY_1, { status = 200 })
        insert_req2(TENANT_A, GATEWAY_1, { status = 429 })
        insert_req2(TENANT_A, GATEWAY_1, { status = 500 })
        insert_req2(TENANT_A, GATEWAY_1, { status = 503 })
        local d = storage.get_analytics_depth(SINCE_MS)
        local r = d.by_tenant[1]
        assert.equal(3, r.errors)
    end)

    it("does not count 200-399 as errors", function()
        insert_req2(TENANT_A, GATEWAY_1, { status = 200 })
        insert_req2(TENANT_A, GATEWAY_1, { status = 201 })
        insert_req2(TENANT_A, GATEWAY_1, { status = 304 })
        local d = storage.get_analytics_depth(SINCE_MS)
        local r = d.by_tenant[1]
        assert.equal(0, r.errors)
    end)

    it("errors are scoped per tenant", function()
        insert_req2(TENANT_A, GATEWAY_1, { status = 500 })
        insert_req2(TENANT_A, GATEWAY_1, { status = 500 })
        insert_req2(TENANT_B, GATEWAY_2, { status = 200 })
        local d = storage.get_analytics_depth(SINCE_MS)
        -- find tenant A and B rows
        local a_row, b_row
        for _, r in ipairs(d.by_tenant) do
            if r.tenant_id == TENANT_A then a_row = r end
            if r.tenant_id == TENANT_B then b_row = r end
        end
        assert.not_nil(a_row)
        assert.not_nil(b_row)
        assert.equal(2, a_row.errors)
        assert.equal(0, b_row.errors)
    end)
end)

-- ─── errors field in by_gateway ───────────────────────────────────────────

describe("get_analytics_depth: errors field in by_gateway", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("errors field is present in each by_gateway row", function()
        insert_req2(TENANT_A, GATEWAY_1, { status = 200 })
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.not_nil(d.by_gateway[1])
        assert.equal(0, d.by_gateway[1].errors)
    end)

    it("counts 5xx per gateway", function()
        insert_req2(TENANT_A, GATEWAY_1, { status = 200 })
        insert_req2(TENANT_A, GATEWAY_1, { status = 502 })
        insert_req2(TENANT_B, GATEWAY_2, { status = 200 })
        local d = storage.get_analytics_depth(SINCE_MS)
        local gw1, gw2
        for _, r in ipairs(d.by_gateway) do
            if r.gateway_id == GATEWAY_1 then gw1 = r end
            if r.gateway_id == GATEWAY_2 then gw2 = r end
        end
        assert.not_nil(gw1)
        assert.not_nil(gw2)
        assert.equal(1, gw1.errors)
        assert.equal(0, gw2.errors)
    end)
end)

-- ─── by_user breakdown ────────────────────────────────────────────────────

describe("get_analytics_depth: by_user breakdown", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("returns empty list when no user_id values are set", function()
        insert_req2(TENANT_A, GATEWAY_1, {})
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.not_nil(d.by_user)
        assert.equal(0, #d.by_user)
    end)

    it("returns a row for each distinct (user_id, tenant_id) pair", function()
        -- alice in two different tenants → two separate rows (GROUP BY user_id, tenant_id)
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "user-alice" })
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "user-bob" })
        insert_req2(TENANT_B, GATEWAY_2, { user_id = "user-alice" })
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(3, #d.by_user)
    end)

    it("excludes rows where user_id is NULL", function()
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "user-x" })
        insert_req2(TENANT_A, GATEWAY_1, {})            -- no user_id
        insert_req2(TENANT_B, GATEWAY_2, {})            -- no user_id
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(1, #d.by_user)
        assert.equal("user-x", d.by_user[1].user_id)
    end)

    it("same user in two tenants produces two separate rows (per-tenant breakdown)", function()
        -- by_user is GROUP BY user_id, tenant_id — each tenant row is separate
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "user-x", cost_usd = 1.0 })
        insert_req2(TENANT_B, GATEWAY_2, { user_id = "user-x", cost_usd = 2.0 })
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(2, #d.by_user)
        local total = d.by_user[1].cost_usd + d.by_user[2].cost_usd
        assert.near(3.0, total, 0.001)
    end)

    it("counts requests correctly", function()
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "user-a" })
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "user-a" })
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "user-a" })
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(3, d.by_user[1].requests)
    end)

    it("counts errors (status >= 400) per user", function()
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "user-a", status = 200 })
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "user-a", status = 500 })
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "user-a", status = 429 })
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(2, d.by_user[1].errors)
    end)

    it("counts cached requests per user", function()
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "user-a", cached = 1 })
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "user-a", cached = 0 })
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal(1, d.by_user[1].cached)
    end)

    it("orders by cost_usd descending", function()
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "cheap-user", cost_usd = 0.5 })
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "rich-user",  cost_usd = 5.0 })
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.equal("rich-user",  d.by_user[1].user_id)
        assert.equal("cheap-user", d.by_user[2].user_id)
    end)

    it("caps results at 50 users", function()
        for i = 1, 55 do
            insert_req2(TENANT_A, GATEWAY_1, { user_id = string.format("user-%03d", i) })
        end
        local d = storage.get_analytics_depth(SINCE_MS)
        assert.is_true(#d.by_user <= 50)
    end)

    it("by_user respects the since_ms cutoff", function()
        -- Old request outside window
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "old-user", offset_sec = -7200 })
        -- Recent request inside window
        insert_req2(TENANT_A, GATEWAY_1, { user_id = "new-user" })
        local since_1h = (math.floor(ngx.now()) - 3600) * 1000
        local d = storage.get_analytics_depth(since_1h)
        assert.equal(1, #d.by_user)
        assert.equal("new-user", d.by_user[1].user_id)
    end)
end)
