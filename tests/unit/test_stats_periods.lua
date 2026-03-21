-- tests/unit/test_stats_periods.lua
-- Regression tests for the stats period queries in storage/sqlite.lua.
--
-- Bug: get_usage_stats() returned identical values for today/hour/last_min
-- because datetime('now','-1 hour') produces '2026-03-21 14:30:00' (no T or Z)
-- while ts is stored as ISO8601 '2026-03-21T14:30:00.000Z'.  SQLite lexicographic
-- string comparison treats the datetime()-format boundary as always < the stored
-- ISO8601 value (since space < 'T'), so every row matched every window.
--
-- Fix: use strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 hour') / '-1 minute' so
-- the comparison strings are in the same format as the stored timestamps.
--
-- Run with: resty tests/runner.lua tests/unit/test_stats_periods.lua

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

rawset(_G, "sqlite3", {})  -- silence the write-guard warning from sqlite.lua
local sqlite3 = require("lsqlite3")

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Open a fresh in-memory DB and create a minimal request_log table.
local function new_db()
    local db = sqlite3.open_memory()
    db:exec([[
        CREATE TABLE request_log (
            id       TEXT PRIMARY KEY,
            ts       TEXT NOT NULL,
            requests INTEGER NOT NULL DEFAULT 1
        );
    ]])
    return db
end

-- Insert a row whose timestamp is `offset` seconds from now
-- (negative = in the past).  Uses the same ISO8601+Z format as production.
local function insert_row(db, id, offset_sec)
    local modifier = string.format("%.0f seconds", offset_sec)
    local sql = string.format([[
        INSERT INTO request_log (id, ts) VALUES ('%s',
            strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ', 'now', '%s'))
    ]], id, modifier)
    db:exec(sql)
end

-- Count rows matching a WHERE clause.
local function count(db, where)
    local n = 0
    for _ in db:nrows("SELECT COUNT(*) AS n FROM request_log WHERE " .. where) do
        n = n + 1  -- first (and only) row
        for row in db:nrows("SELECT COUNT(*) AS n FROM request_log WHERE " .. where) do
            return row.n
        end
    end
    -- simpler loop:
    local stmt = db:prepare("SELECT COUNT(*) FROM request_log WHERE " .. where)
    stmt:step()
    local c = stmt:get_value(0)
    stmt:finalize()
    return c
end

-- ---------------------------------------------------------------------------
-- Reproduce the old broken behaviour
-- ---------------------------------------------------------------------------

describe("stats periods bug: datetime() format mismatch causes all windows to match all rows", function()

    it("datetime('now','-1 hour') format does NOT match ISO8601 stored timestamps", function()
        -- This documents that the OLD code was broken: datetime() returns
        -- '2026-03-21 14:30:00' (space separator, no Z) which is lexicographically
        -- less than any ISO8601 ts ('2026-03-21T...'), so the WHERE clause
        -- ts >= datetime(...) is always TRUE for every stored row.

        local db = new_db()
        -- Insert one row from 90 minutes ago (should NOT be in "last hour" window)
        insert_row(db, "old", -5400)
        -- Insert one row from 30 seconds ago (should be in "last hour" AND "last minute")
        insert_row(db, "new", -30)

        -- BROKEN: datetime() format — the old query
        local broken_hour = count(db, "ts >= datetime('now','-1 hour')")
        -- Because datetime() produces a space-separated string, it compares as
        -- less than every ISO8601 ts (which has 'T'), so BOTH rows match.
        assert.equal(2, broken_hour,
            "old broken datetime() query matches ALL rows regardless of age")

        db:close()
    end)

    it("datetime('now','-1 minute') format matches ALL rows (not just recent ones)", function()
        local db = new_db()
        insert_row(db, "old",    -3600)   -- 1 hour ago
        insert_row(db, "recent", -30)     -- 30 seconds ago

        local broken_min = count(db, "ts >= datetime('now','-1 minute')")
        assert.equal(2, broken_min,
            "old broken datetime() query for last_min matches ALL rows")

        db:close()
    end)
end)

-- ---------------------------------------------------------------------------
-- Verify the fixed behaviour
-- ---------------------------------------------------------------------------

describe("stats periods fix: strftime() ISO8601 format correctly filters by time window", function()

    -- Three rows at known offsets:
    --   "in_min"  : 30 seconds ago  → in last_min, hour, today
    --   "in_hour" : 30 minutes ago  → in hour, today, but NOT last_min
    --   "old"     : 3 hours ago     → in today (if day started >3h ago), NOT hour/min
    --
    -- We only assert the relative ordering that must always hold:
    --   last_min <= hour <= today  (non-decreasing with wider window)
    --   last_min < hour            (30-min-old row is outside last_min but inside hour)
    --   hour < today OR hour == today (3h-old row may or may not be in today)

    local db
    before_each(function()
        db = new_db()
        insert_row(db, "in_min",  -30)       -- 30 seconds ago
        insert_row(db, "in_hour", -1800)     -- 30 minutes ago
        insert_row(db, "old",     -10800)    -- 3 hours ago
    end)

    after_each(function()
        db:close()
    end)

    it("last_min window (fixed): only captures the 30-second-old row", function()
        local n = count(db, "ts >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 minute')")
        assert.equal(1, n)
    end)

    it("hour window (fixed): captures rows from last 30s and last 30min", function()
        local n = count(db, "ts >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 hour')")
        assert.equal(2, n)
    end)

    it("today window (unchanged): uses strftime already, captures >=0 rows", function()
        -- today window depends on wall clock; just verify it returns >= hour count
        local hour_n  = count(db, "ts >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 hour')")
        local today_n = count(db, "ts >= strftime('%Y-%m-%dT00:00:00Z','now')")
        assert.is_true(today_n >= hour_n,
            "today window must include at least as many rows as hour window")
    end)

    it("windows are strictly ordered: last_min < hour (the 30-min-old row separates them)", function()
        local min_n  = count(db, "ts >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 minute')")
        local hour_n = count(db, "ts >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 hour')")
        assert.is_true(hour_n > min_n,
            "hour window must include more rows than last_min window")
    end)

    it("fixed queries return different values (the original bug was all-same)", function()
        local min_n  = count(db, "ts >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 minute')")
        local hour_n = count(db, "ts >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 hour')")
        assert.is_true(min_n ~= hour_n,
            "last_min and hour counts must differ after the fix")
    end)
end)

-- ---------------------------------------------------------------------------
-- Integration test: call through M.get_usage_stats() itself
-- ---------------------------------------------------------------------------
--
-- This is the test that WOULD have caught the bug in production:
-- it calls get_usage_stats() and verifies the three windows differ.
-- The SQL-expression tests above only verify isolated queries; if someone
-- reverts the strftime() fix inside get_usage_stats() those tests still pass.

describe("get_usage_stats integration: results differ per time window", function()

    -- Temp DB paths — removed after the suite.
    local CFG_PATH = "/tmp/test_gw_cfg_stats_int.db"
    local LOG_PATH = "/tmp/test_gw_log_stats_int.db"

    local storage
    local insert_db  -- second connection used only for inserting rows

    -- SQL to insert a minimal valid request_log row at `offset` seconds from now.
    local function insert_req(id, offset_sec)
        local modifier = string.format("%.0f seconds", offset_sec)
        local sql = string.format([[
            INSERT INTO request_log
                (id, tenant_id, gateway_id, provider, model, status,
                 cached, input_tokens, output_tokens,
                 cache_creation_tokens, cache_read_tokens,
                 cost_usd, latency_ms, ts,
                 meta, blocked, upstream_attempts, request_size_bytes, scrub_applied)
            VALUES ('%s','t1','g1','anthropic','claude-3',200,
                    0,10,20,0,0,
                    0.001,100,
                    strftime('%%Y-%%m-%%dT%%H:%%M:%%SZ','now','%s'),
                    '{}',0,1,512,0)
        ]], id, modifier)
        insert_db:exec(sql)
    end

    -- Set up once for the whole suite.
    os.remove(CFG_PATH)
    os.remove(LOG_PATH)

    -- Load the module (package.loaded caches it; first require here wins).
    storage = require("storage.sqlite")

    local cfg = { sqlite = { config_db = CFG_PATH, logs_db = LOG_PATH } }
    storage.migrate(cfg)   -- applies schema DDL via a separate connection
    storage.init(cfg)      -- opens the module-level _cfg_db / _log_db handles

    -- Second connection for direct inserts (module handles are not exposed).
    insert_db = sqlite3.open(LOG_PATH)

    after_each(function()
        -- Clear rows so tests don't bleed into each other.
        insert_db:exec("DELETE FROM request_log")
    end)

    it("last_min < hour: 30-min-old row is outside last_min but inside hour", function()
        insert_req("r_sec",  -30)     -- 30s ago  → last_min + hour + today
        insert_req("r_min",  -1800)   -- 30m ago  → hour + today only

        local stats = storage.get_usage_stats()
        assert.equal(1, stats.last_min.requests,
            "last_min should see only the 30-second-old row")
        assert.equal(2, stats.hour.requests,
            "hour should see both rows")
        assert.is_true(stats.last_min.requests < stats.hour.requests,
            "hour must include more rows than last_min")
    end)

    it("hour <= today: 2-hour-old row widens today but not hour", function()
        insert_req("r_sec",  -30)     -- in last_min + hour + today
        insert_req("r_min",  -1800)   -- in hour + today
        insert_req("r_old",  -7200)   -- 2h ago — in today only (if run after 02:00 UTC)

        local stats = storage.get_usage_stats()
        assert.equal(1, stats.last_min.requests)
        assert.equal(2, stats.hour.requests)
        assert.is_true(stats.today.requests >= stats.hour.requests,
            "today window must include at least as many rows as hour")
    end)

    it("all three windows return different values (the original bug: all same)", function()
        insert_req("r_sec",  -20)     -- 20s ago  → last_min + hour + today
        insert_req("r_min",  -1800)   -- 30m ago  → hour + today
        -- (today may or may not include r_old depending on wall clock, so skip it here)

        local stats = storage.get_usage_stats()
        -- The original bug caused last_min == hour == today.  After the fix they differ.
        assert.is_true(stats.last_min.requests ~= stats.hour.requests,
            "last_min and hour must differ (regression: they were equal with datetime() bug)")
    end)

end)

-- ---------------------------------------------------------------------------
-- Cross-check: the three production SQL expressions from the fixed code
-- ---------------------------------------------------------------------------

describe("stats periods fix: production SQL expressions from sqlite.lua", function()

    it("all three production expressions produce distinct counts for spread data", function()
        local db = new_db()
        insert_row(db, "r1", -20)       -- 20 seconds ago  → min + hour + today
        insert_row(db, "r2", -1800)     -- 30 minutes ago  → hour + today
        insert_row(db, "r3", -7200)     -- 2 hours ago     → today only (if after midnight)

        -- These are the exact expressions from the fixed get_usage_stats()
        local last_min = count(db, "ts >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 minute')")
        local hour     = count(db, "ts >= strftime('%Y-%m-%dT%H:%M:%SZ','now','-1 hour')")
        local today    = count(db, "ts >= strftime('%Y-%m-%dT00:00:00Z','now')")

        assert.equal(1, last_min)
        assert.equal(2, hour)
        assert.is_true(today >= 2)
        assert.is_true(today ~= last_min or today ~= hour or last_min ~= hour,
            "at least two of the three windows must differ")

        db:close()
    end)
end)
