-- storage/schema_logs.sql — DDL for logs.db (SQLite)
-- Append-only request log table. In production, swap for ClickHouse.

PRAGMA synchronous = NORMAL;

CREATE TABLE IF NOT EXISTS request_log (
    id             TEXT PRIMARY KEY,        -- request UUID
    tenant_id      TEXT NOT NULL,
    gateway_id     TEXT NOT NULL,
    provider       TEXT NOT NULL,
    model          TEXT NOT NULL,
    status         INTEGER NOT NULL,        -- HTTP status returned to client
    cached         INTEGER NOT NULL DEFAULT 0,
    input_tokens          INTEGER NOT NULL DEFAULT 0,
    output_tokens         INTEGER NOT NULL DEFAULT 0,
    cache_creation_tokens INTEGER NOT NULL DEFAULT 0,
    cache_read_tokens     INTEGER NOT NULL DEFAULT 0,
    cost_usd       REAL NOT NULL DEFAULT 0,
    latency_ms     INTEGER NOT NULL DEFAULT 0,
    ts             INTEGER NOT NULL,         -- Unix milliseconds
    -- Optional payload (NULL when log_payloads=false or scrubbed by detectors)
    prompt         TEXT,
    response       TEXT,
    -- Custom metadata key=value pairs as JSON object
    meta           TEXT NOT NULL DEFAULT '{}',
    -- Block tracking (NULL blocked_by = request was not blocked)
    blocked        INTEGER NOT NULL DEFAULT 0,
    blocked_by     TEXT,    -- "guardrail" | "detector" | "rate_limit" | "quota" | "ip_allowlist"
    block_reason   TEXT,    -- category codes (e.g. "S2,S9") or pattern name
    -- Guardrail classification details (NULL when guardrails disabled or skipped)
    guardrail_latency_ms  INTEGER,
    guardrail_verdict     TEXT,             -- "safe" | "unsafe" | "error"
    -- Cache savings (NULL on non-cache-hit requests)
    saved_cost_usd        REAL,
    saved_latency_ms      INTEGER,
    -- Upstream provider metrics (NULL on cache hits)
    upstream_latency_ms   INTEGER,         -- TTFB from provider
    time_to_first_token_ms INTEGER,        -- streaming only
    upstream_attempts     INTEGER NOT NULL DEFAULT 0,
    fallback_provider     TEXT,
    fallback_model        TEXT,
    provider_request_id   TEXT,
    -- Request metadata
    request_size_bytes    INTEGER NOT NULL DEFAULT 0,
    -- Quota state at request time (NULL when no budget configured)
    quota_remaining       REAL,
    -- User attribution (NULL for service tokens or open gateways)
    user_id               TEXT,
    token_label           TEXT,
    -- Detector pipeline fields
    detectors_fired       TEXT,   -- JSON array of detector names that triggered
    scrub_applied         INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_log_tenant_ts   ON request_log(tenant_id, ts);
CREATE INDEX IF NOT EXISTS idx_log_gateway_ts  ON request_log(gateway_id, ts);
CREATE INDEX IF NOT EXISTS idx_log_ts          ON request_log(ts);

CREATE TABLE IF NOT EXISTS client_error_log (
    id          TEXT PRIMARY KEY,
    message     TEXT NOT NULL,
    stack       TEXT,
    url         TEXT,
    user_agent  TEXT,
    ts          INTEGER NOT NULL             -- Unix milliseconds
);

CREATE INDEX IF NOT EXISTS idx_client_error_ts ON client_error_log(ts);
