-- tests/unit/test_stats_tenant_filter.lua
-- Tests for the tenant_id filter added to storage.get_usage_stats().
-- Run with: resty tests/runner.lua tests/unit/test_stats_tenant_filter.lua

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

local CFG_PATH = "/tmp/test_gw_cfg_statsten.db"
local LOG_PATH = "/tmp/test_gw_log_statsten.db"
os.remove(CFG_PATH)
os.remove(LOG_PATH)

local storage = require("storage.sqlite")
local cfg = { sqlite = { config_db = CFG_PATH, logs_db = LOG_PATH } }
storage.migrate(cfg)
storage.init(cfg)

local insert_db = sqlite3.open(LOG_PATH)
local cfg_db    = sqlite3.open(CFG_PATH)
local seq       = 0

-- Seed two tenants into the config DB so slug resolution works.
local TENANT_A = "aaaaaaaa-0000-0000-0000-000000000001"
local TENANT_B = "bbbbbbbb-0000-0000-0000-000000000002"

cfg_db:exec(string.format([[
    INSERT OR IGNORE INTO tenant (id, slug, plan, created_at)
    VALUES ('%s', 'tenant-a', 'standard', '2024-01-01T00:00:00Z')
]], TENANT_A))
cfg_db:exec(string.format([[
    INSERT OR IGNORE INTO tenant (id, slug, plan, created_at)
    VALUES ('%s', 'tenant-b', 'standard', '2024-01-01T00:00:00Z')
]], TENANT_B))

-- Insert a request_log row.  offset_sec is relative to ngx.now().
-- When offset_sec is 0 or slightly negative the row lands in last_min/hour/today.
local function insert_req(tenant_id, opts)
    seq = seq + 1
    opts = opts or {}
    local offset_sec = opts.offset_sec or -10   -- 10s ago → in last_min/hour/today
    local ts_ms = (math.floor(ngx.now()) + offset_sec) * 1000
    local blocked = opts.blocked or 0
    local sql = string.format([[
        INSERT INTO request_log
            (id, tenant_id, gateway_id, provider, model, status,
             cached, input_tokens, output_tokens,
             cache_creation_tokens, cache_read_tokens,
             cost_usd, latency_ms, ts,
             meta, blocked, upstream_attempts, request_size_bytes, scrub_applied)
        VALUES ('req-%04d','%s','g1','openai','gpt-4o',200,
                0,%d,20,0,0,
                0.001,100,
                %d,
                '{}', %d, 1, 512, 0)
    ]], seq, tenant_id,
        opts.input_tokens or 10,
        ts_ms, blocked)
    insert_db:exec(sql)
end

-- ─── Unfiltered (no tenant_id) ───────────────────────────────────────────────

describe("get_usage_stats: no tenant filter returns all tenants", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("aggregates requests from all tenants when tenant_id is nil", function()
        insert_req(TENANT_A)
        insert_req(TENANT_B)
        insert_req(TENANT_A)

        local stats = storage.get_usage_stats()
        assert.equal(3, stats.last_min.requests)
        assert.equal(3, stats.hour.requests)
        assert.equal(3, stats.today.requests)
    end)

    it("by_tenant lists both tenants when unfiltered", function()
        insert_req(TENANT_A)
        insert_req(TENANT_B)

        local stats = storage.get_usage_stats()
        assert.equal(2, #stats.by_tenant)
    end)

    it("recent includes rows from all tenants when unfiltered", function()
        insert_req(TENANT_A)
        insert_req(TENANT_B)

        local stats = storage.get_usage_stats()
        assert.equal(2, #stats.recent)
        local tenants_seen = {}
        for _, r in ipairs(stats.recent) do tenants_seen[r.tenant_id] = true end
        assert.is_true(tenants_seen[TENANT_A])
        assert.is_true(tenants_seen[TENANT_B])
    end)
end)

-- ─── Single-tenant filter: period stats ─────────────────────────────────────

describe("get_usage_stats: tenant_id filters period stats", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("last_min only counts the filtered tenant's requests", function()
        insert_req(TENANT_A)
        insert_req(TENANT_A)
        insert_req(TENANT_B)

        local stats = storage.get_usage_stats(TENANT_A)
        assert.equal(2, stats.last_min.requests)
    end)

    it("hour only counts the filtered tenant's requests", function()
        insert_req(TENANT_A)
        insert_req(TENANT_B)
        insert_req(TENANT_B)

        local stats = storage.get_usage_stats(TENANT_B)
        assert.equal(2, stats.hour.requests)
    end)

    it("today only counts the filtered tenant's requests", function()
        insert_req(TENANT_A)
        insert_req(TENANT_B)

        local stats_a = storage.get_usage_stats(TENANT_A)
        local stats_b = storage.get_usage_stats(TENANT_B)
        assert.equal(1, stats_a.today.requests)
        assert.equal(1, stats_b.today.requests)
    end)

    it("returns zero counts when tenant has no requests", function()
        insert_req(TENANT_A)

        local stats = storage.get_usage_stats(TENANT_B)
        assert.equal(0, stats.last_min.requests)
        assert.equal(0, stats.hour.requests)
        assert.equal(0, stats.today.requests)
    end)

    it("aggregates cost only for the filtered tenant", function()
        -- Tenant A: 3 requests × 0.001 = 0.003
        -- Tenant B: 1 request  × 0.001 = 0.001
        insert_req(TENANT_A)
        insert_req(TENANT_A)
        insert_req(TENANT_A)
        insert_req(TENANT_B)

        local stats = storage.get_usage_stats(TENANT_A)
        assert.is_true(stats.today.cost_usd > 0)
        -- Cost for A should be 3× that for B
        local stats_b = storage.get_usage_stats(TENANT_B)
        assert.is_true(stats.today.cost_usd > stats_b.today.cost_usd)
    end)

    it("input/output token counts are scoped to the filtered tenant", function()
        insert_req(TENANT_A, { input_tokens = 50 })
        insert_req(TENANT_B, { input_tokens = 99 })

        local stats = storage.get_usage_stats(TENANT_A)
        assert.equal(50, stats.today.input_tokens)

        local stats_b = storage.get_usage_stats(TENANT_B)
        assert.equal(99, stats_b.today.input_tokens)
    end)
end)

-- ─── Single-tenant filter: by_tenant table ──────────────────────────────────

describe("get_usage_stats: tenant_id filters by_tenant breakdown", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("by_tenant contains only the filtered tenant", function()
        insert_req(TENANT_A)
        insert_req(TENANT_B)

        local stats = storage.get_usage_stats(TENANT_A)
        assert.equal(1, #stats.by_tenant)
        assert.equal(TENANT_A, stats.by_tenant[1].tenant_id)
    end)

    it("by_tenant shows correct request count for the filtered tenant", function()
        insert_req(TENANT_A)
        insert_req(TENANT_A)
        insert_req(TENANT_B)

        local stats = storage.get_usage_stats(TENANT_A)
        assert.equal(1, #stats.by_tenant)
        assert.equal(2, stats.by_tenant[1].requests)
    end)

    it("by_tenant slug is resolved from config DB", function()
        insert_req(TENANT_A)

        local stats = storage.get_usage_stats(TENANT_A)
        assert.equal(1, #stats.by_tenant)
        assert.equal("tenant-a", stats.by_tenant[1].tenant)
    end)
end)

-- ─── Single-tenant filter: recent requests ──────────────────────────────────

describe("get_usage_stats: tenant_id filters recent requests", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("recent only contains rows for the filtered tenant", function()
        insert_req(TENANT_A)
        insert_req(TENANT_A)
        insert_req(TENANT_B)

        local stats = storage.get_usage_stats(TENANT_A)
        assert.equal(2, #stats.recent)
        for _, r in ipairs(stats.recent) do
            assert.equal(TENANT_A, r.tenant_id)
        end
    end)

    it("recent is empty when filtered tenant has no requests", function()
        insert_req(TENANT_B)

        local stats = storage.get_usage_stats(TENANT_A)
        assert.equal(0, #stats.recent)
    end)

    it("recent shows correct slug for filtered tenant", function()
        insert_req(TENANT_A)

        local stats = storage.get_usage_stats(TENANT_A)
        assert.equal(1, #stats.recent)
        assert.equal("tenant-a", stats.recent[1].tenant)
    end)
end)

-- ─── Single-tenant filter: recent_blocked ───────────────────────────────────

describe("get_usage_stats: tenant_id filters recent_blocked guardrail events", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("recent_blocked only contains blocked rows for the filtered tenant", function()
        insert_req(TENANT_A, { blocked = 1 })
        insert_req(TENANT_A, { blocked = 1 })
        insert_req(TENANT_B, { blocked = 1 })

        local stats = storage.get_usage_stats(TENANT_A)
        assert.equal(2, #stats.recent_blocked)
        for _, r in ipairs(stats.recent_blocked) do
            assert.equal(TENANT_A, r.tenant_id)
        end
    end)

    it("recent_blocked is empty when filtered tenant has no guardrail events", function()
        insert_req(TENANT_B, { blocked = 1 })
        insert_req(TENANT_A)   -- not blocked

        local stats = storage.get_usage_stats(TENANT_A)
        assert.equal(0, #stats.recent_blocked)
    end)
end)

-- ─── Empty tenant_id ────────────────────────────────────────────────────────

describe("get_usage_stats: empty string tenant_id treated as no filter", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("empty string returns all tenants (same as nil)", function()
        insert_req(TENANT_A)
        insert_req(TENANT_B)

        local stats = storage.get_usage_stats("")
        assert.equal(2, stats.last_min.requests)
    end)
end)

-- ─── Invalid tenant_id input ─────────────────────────────────────────────────

describe("get_usage_stats: invalid tenant_id is rejected safely", function()
    before_each(function() insert_db:exec("DELETE FROM request_log"); seq = 0 end)

    it("tenant_id with SQL injection characters returns unfiltered (validation rejects it)", function()
        insert_req(TENANT_A)
        insert_req(TENANT_B)

        -- Single-quote injection — should be rejected by UUID validation
        local stats = storage.get_usage_stats("' OR '1'='1")
        -- Rejected input → no tenant_clause → returns all rows
        assert.equal(2, stats.last_min.requests)
    end)

    it("tenant_id with semicolon is rejected by UUID validation", function()
        insert_req(TENANT_A)

        local stats = storage.get_usage_stats("abc; DROP TABLE request_log; --")
        -- Rejected → unfiltered
        assert.equal(1, stats.last_min.requests)
        -- Table must still exist
        local check = storage.get_usage_stats()
        assert.equal(1, check.last_min.requests)
    end)
end)
