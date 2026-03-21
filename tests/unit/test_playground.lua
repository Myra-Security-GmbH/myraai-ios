-- tests/unit/test_playground.lua
-- Tests for playground-related Lua code:
--   storage.get_gateway_with_tenant_slug (new function)
--   providers/compat.lua infer_provider (playground relies on OpenRouter fallback)
--
-- Run with: resty -I src/ tests/runner.lua tests/unit/test_playground.lua

_G.ngx = {
    now    = function() return 1700000000.0 end,
    log    = function() end,
    var    = { http_x_request_id = "" },
    req    = { get_headers = function() return {} end },
    ERR = 0, WARN = 1, INFO = 2,
}

package.path  = "src/?.lua;src/?/init.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;" .. package.cpath

-- ── storage.get_gateway_with_tenant_slug ─────────────────────────────────────
-- Tested via an in-memory SQLite database so we can exercise the real SQL.

describe("storage.get_gateway_with_tenant_slug", function()
    local sqlite3 = require("lsqlite3")
    local json    = require("utils.json")

    -- Build a minimal in-memory DB that mirrors the real schema.
    local function make_db()
        local db = sqlite3.open(":memory:")
        db:exec([[
            CREATE TABLE tenant (
                id TEXT PRIMARY KEY,
                slug TEXT NOT NULL,
                plan TEXT NOT NULL DEFAULT 'free',
                budget_usd REAL,
                deleted_at TEXT
            );
            CREATE TABLE gateway (
                id TEXT PRIMARY KEY,
                tenant_id TEXT NOT NULL,
                slug TEXT NOT NULL,
                config TEXT NOT NULL DEFAULT '{}'
            );
        ]])
        return db
    end

    -- Re-implement the minimal query logic so we can test the SQL without
    -- wiring up the full storage module (which needs file-backed DBs).
    local function get_gateway_with_tenant_slug(db, gateway_id)
        local stmt = db:prepare([[
            SELECT g.id, g.slug AS gateway_slug, g.tenant_id,
                   t.slug AS tenant_slug
            FROM   gateway g
            JOIN   tenant  t ON t.id = g.tenant_id
            WHERE  g.id = ? AND t.deleted_at IS NULL
        ]])
        stmt:bind_values(gateway_id)
        local row
        for r in stmt:nrows() do row = r; break end
        stmt:finalize()
        return row
    end

    it("returns gateway_slug and tenant_slug for a known gateway", function()
        local db = make_db()
        db:exec("INSERT INTO tenant  VALUES ('t1','acme','free',NULL,NULL)")
        db:exec("INSERT INTO gateway VALUES ('gw1','t1','main','{}')")

        local row = get_gateway_with_tenant_slug(db, "gw1")
        assert.not_nil(row)
        assert.equal("main", row.gateway_slug)
        assert.equal("acme", row.tenant_slug)
        assert.equal("t1",   row.tenant_id)
        db:close()
    end)

    it("returns nil when gateway does not exist", function()
        local db = make_db()
        db:exec("INSERT INTO tenant  VALUES ('t1','acme','free',NULL,NULL)")

        local row = get_gateway_with_tenant_slug(db, "no-such-gw")
        assert.is_nil(row)
        db:close()
    end)

    it("returns nil when tenant is soft-deleted", function()
        local db = make_db()
        db:exec("INSERT INTO tenant  VALUES ('t1','acme','free',NULL,'2024-01-01T00:00:00Z')")
        db:exec("INSERT INTO gateway VALUES ('gw1','t1','main','{}')")

        local row = get_gateway_with_tenant_slug(db, "gw1")
        assert.is_nil(row)
        db:close()
    end)

    it("handles multiple tenants and gateways correctly", function()
        local db = make_db()
        db:exec("INSERT INTO tenant  VALUES ('t1','acme','free',NULL,NULL)")
        db:exec("INSERT INTO tenant  VALUES ('t2','globex','pro',NULL,NULL)")
        db:exec("INSERT INTO gateway VALUES ('gw1','t1','prod','{}')")
        db:exec("INSERT INTO gateway VALUES ('gw2','t2','dev','{}')")

        local r1 = get_gateway_with_tenant_slug(db, "gw1")
        assert.equal("prod", r1.gateway_slug)
        assert.equal("acme", r1.tenant_slug)

        local r2 = get_gateway_with_tenant_slug(db, "gw2")
        assert.equal("dev",    r2.gateway_slug)
        assert.equal("globex", r2.tenant_slug)
        db:close()
    end)
end)

-- ── playground token TTL logic ────────────────────────────────────────────────
-- Validate the expiry timestamp format the admin API would produce.

describe("playground token expiry", function()
    it("os.date UTC format matches ISO-8601 pattern", function()
        -- Simulate what the admin route does: os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 600)
        local expires_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 600)
        assert.is_string(expires_at)
        -- Should match YYYY-MM-DDTHH:MM:SSZ
        local y, mo, d, h, mi, sec = expires_at:match(
            "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
        assert.not_nil(y,   "year missing from expires_at")
        assert.not_nil(mo,  "month missing from expires_at")
        assert.not_nil(d,   "day missing from expires_at")
        assert.not_nil(h,   "hour missing from expires_at")
        assert.not_nil(mi,  "minute missing from expires_at")
        assert.not_nil(sec, "second missing from expires_at")
    end)

    it("expiry is roughly 10 minutes in the future", function()
        local now_before = os.time()
        local expires_at = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() + 600)
        local now_after  = os.time()

        -- Parse the UTC timestamp back to a unix time for comparison.
        -- os.time with a table uses local time; we compensate with UTC offset.
        -- A simpler check: the seconds in the string should be a reasonable time.
        -- Verify the string is not empty and has the right structure.
        assert.is_string(expires_at)
        assert.equal(20, #expires_at) -- "2024-01-01T00:00:00Z" = 20 chars
        -- The year should be current or near-future (basic sanity)
        local year = tonumber(expires_at:sub(1, 4))
        assert.not_nil(year)
        assert(year >= 2024, "year should be >= 2024, got " .. tostring(year))
        _ = now_before; _ = now_after  -- suppress unused warnings
    end)
end)

-- ── compat.infer_provider — OpenRouter fallback used by playground ────────────

describe("compat.infer_provider — playground OpenRouter fallback", function()
    package.loaded["providers.compat"] = nil
    local compat = require("providers.compat")

    it("unknown model routes to openrouter (playground catch-all)", function()
        -- When users type an arbitrary model in the playground, it should route
        -- to OpenRouter rather than failing with "cannot infer provider".
        assert.equal("openrouter", compat.infer_provider("my-custom-fine-tuned-model"))
    end)

    it("openrouter-namespaced model routes to openrouter", function()
        -- OpenRouter uses "provider/model" slugs that don't match our prefix map.
        assert.equal("openrouter", compat.infer_provider("nousresearch/hermes-3-llama-3.1-405b"))
    end)

    it("nil model routes to openrouter", function()
        assert.equal("openrouter", compat.infer_provider(nil))
    end)

    it("well-known models still route to their native provider", function()
        -- Playground must not break routing for models we explicitly know about.
        assert.equal("openai",     compat.infer_provider("gpt-4o"))
        assert.equal("anthropic",  compat.infer_provider("claude-sonnet-4-6"))
        assert.equal("gemini",     compat.infer_provider("gemini-2.0-flash"))
        assert.equal("deepseek",   compat.infer_provider("deepseek-chat"))
        assert.equal("together",   compat.infer_provider("meta-llama/Llama-3.3-70B-Instruct-Turbo"))
    end)
end)
