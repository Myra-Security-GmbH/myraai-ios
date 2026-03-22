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
local seq = 0

-- ts is 1 hour before ngx.now() — always within the default 24h window
local RECENT_TS_MS = (math.floor(ngx.now()) - 3600) * 1000

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
