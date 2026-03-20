-- storage/schema_logs.sql — DDL for logs.db (SQLite)
-- Append-only request log table. In production, swap for ClickHouse.

PRAGMA synchronous = NORMAL;

CREATE TABLE IF NOT EXISTS request_logs (
    id             TEXT PRIMARY KEY,        -- request UUID
    tenant_id      TEXT NOT NULL,
    gateway_id     TEXT NOT NULL,
    provider       TEXT NOT NULL,
    model          TEXT NOT NULL,
    status         INTEGER NOT NULL,        -- HTTP status returned to client
    cached         INTEGER NOT NULL DEFAULT 0,
    input_tokens   INTEGER NOT NULL DEFAULT 0,
    output_tokens  INTEGER NOT NULL DEFAULT 0,
    cost_usd       REAL NOT NULL DEFAULT 0,
    latency_ms     INTEGER NOT NULL DEFAULT 0,
    ts             TEXT NOT NULL,           -- ISO8601 with ms
    -- Optional payload (NULL when log_payloads=false or DLP scrubbed)
    prompt         TEXT,
    response       TEXT,
    -- Custom metadata key=value pairs as JSON object
    meta           TEXT NOT NULL DEFAULT '{}'
);

CREATE INDEX IF NOT EXISTS idx_logs_tenant_ts   ON request_logs(tenant_id, ts);
CREATE INDEX IF NOT EXISTS idx_logs_gateway_ts  ON request_logs(gateway_id, ts);
CREATE INDEX IF NOT EXISTS idx_logs_ts          ON request_logs(ts);
