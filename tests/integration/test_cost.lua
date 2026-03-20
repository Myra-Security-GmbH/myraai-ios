-- tests/integration/test_cost.lua — verify cost_usd is recorded for new requests
--
-- Prerequisites:
--   1. mock provider running:  tests/mock_provider/start.sh
--   2. mock gateway seeded:    AIG_CONFIG=config/gateway.lua resty -I src/ tests/fixtures/seed_mock.lua
--   3. gateway running:        sudo openresty -c config/nginx.conf
--
-- Run:
--   resty tests/runner.lua tests/integration/test_cost.lua

local h    = require("tests.integration.helpers")
local json = require("cjson.safe")

local DATA_DIR = os.getenv("AIG_DATA_DIR") or "data"
local LOGS_DB  = DATA_DIR .. "/logs.db"

-- Query logs.db and return the most recent row for the given model created at or
-- after `ts_iso` (UTC, format "YYYY-MM-DDTHH:MM:SS").
local function latest_log(model, ts_iso)
    local sql = string.format(
        "SELECT input_tokens,output_tokens,cost_usd FROM request_logs"
        .. " WHERE model=%q AND ts >= %q ORDER BY ts DESC LIMIT 1",
        model, ts_iso)
    local fh  = io.popen(string.format("sqlite3 %q %q", LOGS_DB, sql))
    local row = fh and fh:read("*l") or ""
    if fh then fh:close() end
    if row == "" then return nil end
    local in_tok, out_tok, cost = row:match("^(%d+)|(%d+)|([%d%.eE+%-]+)$")
    if not cost then return nil end
    return {
        input_tokens  = tonumber(in_tok),
        output_tokens = tonumber(out_tok),
        cost_usd      = tonumber(cost),
    }
end

-- Tenant/gateway that routes to the mock provider (seeded by seed_mock.lua).
local TENANT  = "test-tenant"
local GATEWAY = "mock"

-- ─────────────────────────────────────────────────────────────────────────────

describe("cost logging — claude-sonnet-4-6", function()

    -- ── Non-streaming ────────────────────────────────────────────────────────

    it("records non-zero cost_usd for a buffered response", function()
        local ts = os.date("!%Y-%m-%dT%H:%M:%S")

        local r = h.gateway_post(
            h.gw_path(TENANT, GATEWAY, "anthropic", "/v1/messages"),
            {
                model      = "claude-sonnet-4-6",
                messages   = {{ role = "user", content = "Hi" }},
                max_tokens = 32,
            }
        )

        assert.equal(200, r.status,
            "gateway returned non-200: " .. r.status .. " body=" .. r.body)

        -- Allow the nginx log phase to flush before querying the DB
        os.execute("sleep 0.5")

        local row = latest_log("claude-sonnet-4-6", ts)
        assert.not_nil(row, "no log row found in DB for claude-sonnet-4-6 after " .. ts)
        assert.is_true(row.input_tokens  > 0, "input_tokens should be > 0, got "  .. tostring(row.input_tokens))
        assert.is_true(row.output_tokens > 0, "output_tokens should be > 0, got " .. tostring(row.output_tokens))
        assert.is_true(row.cost_usd      > 0,
            string.format("cost_usd should be > 0 (input=%d output=%d cost=%s)",
                row.input_tokens, row.output_tokens, tostring(row.cost_usd)))
    end)

    -- ── Streaming ────────────────────────────────────────────────────────────

    it("records non-zero cost_usd for a streaming response", function()
        local ts = os.date("!%Y-%m-%dT%H:%M:%S")

        local r = h.gateway_post(
            h.gw_path(TENANT, GATEWAY, "anthropic", "/v1/messages"),
            {
                model      = "claude-sonnet-4-6",
                stream     = true,
                messages   = {{ role = "user", content = "Hi" }},
                max_tokens = 32,
            }
        )

        assert.equal(200, r.status,
            "gateway returned non-200: " .. r.status .. " body=" .. r.body)
        assert.not_nil(r.body:find("data:"), "response should contain SSE data lines")

        os.execute("sleep 0.5")

        local row = latest_log("claude-sonnet-4-6", ts)
        assert.not_nil(row, "no log row found in DB for claude-sonnet-4-6 after " .. ts)
        assert.is_true(row.input_tokens  > 0, "input_tokens should be > 0, got "  .. tostring(row.input_tokens))
        assert.is_true(row.output_tokens > 0, "output_tokens should be > 0, got " .. tostring(row.output_tokens))
        assert.is_true(row.cost_usd      > 0,
            string.format("cost_usd should be > 0 (input=%d output=%d cost=%s)",
                row.input_tokens, row.output_tokens, tostring(row.cost_usd)))
    end)

end)
