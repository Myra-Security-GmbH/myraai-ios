-- storage/schema_config.sql — DDL for config.db (SQLite)
-- Applied once on first run via storage/sqlite.lua:init_config_db()

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS tenant (
    id            TEXT PRIMARY KEY,                   -- UUID
    slug          TEXT UNIQUE NOT NULL,
    plan          TEXT NOT NULL DEFAULT 'free',
    budget_usd    REAL,
    budget_period TEXT NOT NULL DEFAULT 'monthly',    -- 'monthly' | 'daily' | 'total'
    siem_config   TEXT,                              -- JSON {type, url, token, ...} or NULL
    deleted_at    INTEGER,                            -- Unix seconds, NULL = active
    created_at    INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER))
);

CREATE TABLE IF NOT EXISTS gateway (
    id          TEXT PRIMARY KEY,                   -- UUID
    tenant_id   TEXT NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    slug        TEXT NOT NULL,
    config      TEXT NOT NULL DEFAULT '{}',         -- JSON
    created_at  INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
    UNIQUE(tenant_id, slug)
);

-- Per-gateway provider configs: stores encrypted BYOK keys
CREATE TABLE IF NOT EXISTS provider_config (
    id            TEXT PRIMARY KEY,
    gateway_id    TEXT NOT NULL REFERENCES gateway(id) ON DELETE CASCADE,
    provider      TEXT NOT NULL,
    alias         TEXT NOT NULL DEFAULT 'default',
    encrypted_key TEXT NOT NULL,                    -- base64(AES-256-GCM ciphertext)
    nonce         TEXT NOT NULL,                    -- base64(96-bit nonce)
    created_at    INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
    UNIQUE(gateway_id, provider, alias)
);

-- Users belonging to a tenant (human identities, as opposed to service tokens)
CREATE TABLE IF NOT EXISTS user (
    id          TEXT PRIMARY KEY,                   -- UUID
    tenant_id   TEXT NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
    email       TEXT NOT NULL,
    name        TEXT,
    role        TEXT NOT NULL DEFAULT 'member',     -- 'admin' | 'member' | 'viewer'
    deleted_at  INTEGER,                            -- Unix seconds, NULL = active
    created_at  INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
    UNIQUE(tenant_id, email)
);

-- Fine-grained per-user gateway access (only enforced for role='member')
CREATE TABLE IF NOT EXISTS user_gateway_access (
    user_id    TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    gateway_id TEXT NOT NULL REFERENCES gateway(id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, gateway_id)
);

-- Gateway auth tokens (bearer tokens for x-aig-token header)
CREATE TABLE IF NOT EXISTS auth_token (
    id          TEXT PRIMARY KEY,
    gateway_id  TEXT NOT NULL REFERENCES gateway(id) ON DELETE CASCADE,
    token_hash  TEXT NOT NULL UNIQUE,               -- SHA-256 hex of raw token
    scopes      TEXT NOT NULL DEFAULT '[]',         -- JSON array
    expires_at  INTEGER,                            -- Unix seconds or NULL = never
    created_at  INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
    -- User association (NULL = service/machine token)
    user_id     TEXT REFERENCES user(id) ON DELETE CASCADE,
    label         TEXT,                               -- human-readable name, e.g. "dev laptop"
    rate_limit    TEXT,                               -- JSON {requests, window_sec} override or NULL
    budget_usd    REAL,                              -- per-token spend cap or NULL
    budget_period TEXT NOT NULL DEFAULT 'monthly'    -- 'monthly' | 'daily' | 'total'
);

-- Routing rules evaluated in priority order
CREATE TABLE IF NOT EXISTS routing_rule (
    id          TEXT PRIMARY KEY,
    gateway_id  TEXT NOT NULL REFERENCES gateway(id) ON DELETE CASCADE,
    priority    INTEGER NOT NULL DEFAULT 0,
    conditions  TEXT NOT NULL DEFAULT '[]',         -- JSON [{field, op, value}]
    actions     TEXT NOT NULL DEFAULT '{}',         -- JSON {provider, model, fallbacks:[]}
    enabled     INTEGER NOT NULL DEFAULT 1
);

-- Per-provider model pricing (used for cost attribution).
-- All prices USD per 1K tokens.
CREATE TABLE IF NOT EXISTS model_price (
    provider            TEXT NOT NULL,
    model               TEXT NOT NULL,
    input_per_1k        REAL NOT NULL,
    output_per_1k       REAL NOT NULL,
    cache_write_per_1k  REAL,           -- prompt-cache write (e.g. Anthropic: 1.25x input)
    cache_read_per_1k   REAL,           -- prompt-cache read  (e.g. Anthropic: 0.1x input)
    updated_at          INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
    PRIMARY KEY(provider, model)
);

-- Seed / update model prices. INSERT OR REPLACE keeps prices current on schema re-runs.
-- Use explicit column names to be safe against column-order differences in migrated DBs.
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('openai',    'gpt-4o',                      0.0025,   0.010,   NULL,      NULL,      CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('openai',    'gpt-4o-mini',                 0.00015,  0.0006,  NULL,      NULL,      CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('openai',    'gpt-4-turbo',                 0.010,    0.030,   NULL,      NULL,      CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('openai',    'gpt-3.5-turbo',               0.0005,   0.0015,  NULL,      NULL,      CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-opus-4-6',             0.015,    0.075,   0.01875,   0.0015,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-sonnet-4-6',           0.003,    0.015,   0.00375,   0.0003,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-haiku-4-5-20251001',   0.0008,   0.004,   0.001,     0.00008,   CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-haiku-4-5',            0.0008,   0.004,   0.001,     0.00008,   CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-3-5-sonnet-20241022',  0.003,    0.015,   0.00375,   0.0003,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-3-5-haiku-20241022',   0.0008,   0.004,   0.001,     0.00008,   CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-3-opus-20240229',      0.015,    0.075,   0.01875,   0.0015,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('gemini',    'gemini-1.5-pro',              0.00125,  0.005,   NULL,      NULL,      CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('gemini',    'gemini-1.5-flash',            0.000075, 0.0003,  NULL,      NULL,      CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('mistral',   'mistral-large-latest',        0.002,    0.006,   NULL,      NULL,      CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('groq',      'llama-3.3-70b-versatile',     0.00059,  0.00079, NULL,      NULL,      CAST(strftime('%s','now') AS INTEGER));

-- Period-aware spend ledger — replaces ephemeral shared-dict budget counters.
-- entity_type: 'gateway' | 'tenant' | 'token'
-- period:      'YYYY-MM' (monthly) | 'YYYY-MM-DD' (daily) | 'total' (lifetime)
-- amount_micro: USD * 1e6 stored as INTEGER to avoid float precision drift.
CREATE TABLE IF NOT EXISTS spend_ledger (
    entity_type  TEXT    NOT NULL,
    entity_id    TEXT    NOT NULL,
    period       TEXT    NOT NULL,
    amount_micro INTEGER NOT NULL DEFAULT 0,
    updated_at   INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
    PRIMARY KEY (entity_type, entity_id, period)
);
CREATE INDEX IF NOT EXISTS idx_spend_entity ON spend_ledger(entity_type, entity_id, period DESC);

-- Playground query traces: one row per playground request
CREATE TABLE IF NOT EXISTS playground_trace (
    id           TEXT PRIMARY KEY,  -- UUID (= ctx.request_id)
    gateway_id   TEXT NOT NULL,
    model        TEXT,
    created_at   INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
    completed_at INTEGER,
    status       TEXT NOT NULL DEFAULT 'running',  -- running|done|error
    error        TEXT
);

-- Ordered event log for each trace step
CREATE TABLE IF NOT EXISTS playground_trace_step (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    trace_id  TEXT NOT NULL REFERENCES playground_trace(id) ON DELETE CASCADE,
    seq       INTEGER NOT NULL,
    step      TEXT NOT NULL,
    data      TEXT NOT NULL DEFAULT '{}',
    ts        INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER))
);

CREATE INDEX IF NOT EXISTS idx_pgt_gateway    ON playground_trace(gateway_id, created_at);
CREATE INDEX IF NOT EXISTS idx_pgts_trace_seq ON playground_trace_step(trace_id, seq);

-- Admin API audit log: records every mutating admin request (POST/PATCH/DELETE).
-- actor_id is NULL until admin API authentication is implemented (Sprint 1a).
CREATE TABLE IF NOT EXISTS audit_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    ts         INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER) * 1000),
    actor_ip   TEXT,
    method     TEXT NOT NULL,
    path       TEXT NOT NULL,
    status     INTEGER
);
CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts DESC);
