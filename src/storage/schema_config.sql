-- storage/schema_config.sql — DDL for config.db (SQLite)
-- Applied once on first run via storage/sqlite.lua:init_config_db()

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS tenant (
    id                   TEXT PRIMARY KEY,                   -- UUID
    slug                 TEXT UNIQUE NOT NULL,
    plan                 TEXT NOT NULL DEFAULT 'free',
    budget_usd           REAL,
    budget_period        TEXT NOT NULL DEFAULT 'monthly',
    siem_config          TEXT,
    chat_presets_config  TEXT,
    deleted_at           INTEGER,
    created_at           INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER))
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

-- Users: one tenant per user, role scoped to that tenant.
-- Platform admins (role='admin') may have tenant_id NULL.
-- role: 'admin' (platform superadmin) | 'tenant_admin' (tenant admin) | 'member' (full access) | 'viewer' (read-only, no inference)
CREATE TABLE IF NOT EXISTS user (
    id            TEXT PRIMARY KEY,
    tenant_id     TEXT REFERENCES tenant(id) ON DELETE CASCADE,
    email         TEXT NOT NULL UNIQUE,
    name          TEXT,
    role          TEXT NOT NULL DEFAULT 'member',
    deleted_at    INTEGER,
    created_at    INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
    last_login_at INTEGER
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
-- Anthropic — Claude 4.6 (latest)
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-opus-4-6',             0.005,    0.025,   0.00625,   0.0005,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-opus-4-6-20260205',    0.005,    0.025,   0.00625,   0.0005,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-sonnet-4-6',           0.003,    0.015,   0.00375,   0.0003,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-haiku-4-5',            0.001,    0.005,   0.00125,   0.0001,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-haiku-4-5-20251001',   0.001,    0.005,   0.00125,   0.0001,    CAST(strftime('%s','now') AS INTEGER));
-- Anthropic — Claude 4.5
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-opus-4-5',             0.005,    0.025,   0.00625,   0.0005,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-opus-4-5-20251101',    0.005,    0.025,   0.00625,   0.0005,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-sonnet-4-5',           0.003,    0.015,   0.00375,   0.0003,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-sonnet-4-5-20250929',  0.003,    0.015,   0.00375,   0.0003,    CAST(strftime('%s','now') AS INTEGER));
-- Anthropic — Claude 4.1 / 4.0 (legacy)
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-opus-4-1',             0.015,    0.075,   0.01875,   0.0015,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-opus-4-1-20250805',    0.015,    0.075,   0.01875,   0.0015,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-opus-4-0',             0.015,    0.075,   0.01875,   0.0015,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-opus-4-20250514',      0.015,    0.075,   0.01875,   0.0015,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-sonnet-4-0',           0.003,    0.015,   0.00375,   0.0003,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-sonnet-4-20250514',    0.003,    0.015,   0.00375,   0.0003,    CAST(strftime('%s','now') AS INTEGER));
-- Anthropic — Claude 3.x (legacy/deprecated)
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-3-7-sonnet-20250219',  0.003,    0.015,   0.00375,   0.0003,    CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-3-haiku-20240307',     0.00025,  0.00125, 0.0003,    0.00003,   CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('gemini',    'gemini-1.5-pro',              0.00125,  0.005,   NULL,      NULL,      CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('gemini',    'gemini-1.5-flash',            0.000075, 0.0003,  NULL,      NULL,      CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('mistral',   'mistral-large-latest',        0.002,    0.006,   NULL,      NULL,      CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('groq',      'llama-3.3-70b-versatile',     0.00059,  0.00079, NULL,      NULL,      CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('vllm',      'qwen3-235b',                  0.0,      0.0,     NULL,      NULL,      CAST(strftime('%s','now') AS INTEGER));
INSERT OR REPLACE INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('vllm',      'qwen3-30b-a3b',               0.0,      0.0,     NULL,      NULL,      CAST(strftime('%s','now') AS INTEGER));

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
CREATE TABLE IF NOT EXISTS audit_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    ts         INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER) * 1000),
    actor_id   TEXT,
    actor_ip   TEXT,
    method     TEXT NOT NULL,
    path       TEXT NOT NULL,
    status     INTEGER
);
CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_log(ts DESC);

-- Email one-time-codes for admin login.
CREATE TABLE IF NOT EXISTS email_otp (
    id         TEXT PRIMARY KEY,
    email      TEXT NOT NULL,
    code_hash  TEXT NOT NULL,   -- SHA-256 hex of 6-digit code
    expires_at INTEGER NOT NULL,
    used_at    INTEGER,
    ip_addr    TEXT,
    created_at INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER))
);
CREATE INDEX IF NOT EXISTS idx_otp_email ON email_otp(email, expires_at);

-- OAuth provider identity links (Google SSO).
CREATE TABLE IF NOT EXISTS oauth_link (
    user_id    TEXT NOT NULL REFERENCES user(id) ON DELETE CASCADE,
    provider   TEXT NOT NULL,   -- 'google'
    subject    TEXT NOT NULL,   -- provider's user id (Google sub)
    email      TEXT,
    PRIMARY KEY (provider, subject)
);
