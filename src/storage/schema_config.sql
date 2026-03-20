-- storage/schema_config.sql — DDL for config.db (SQLite)
-- Applied once on first run via storage/sqlite.lua:init_config_db()

PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS tenants (
    id          TEXT PRIMARY KEY,                   -- UUID
    slug        TEXT UNIQUE NOT NULL,
    plan        TEXT NOT NULL DEFAULT 'free',
    budget_usd  REAL,
    deleted_at  TEXT,
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

CREATE TABLE IF NOT EXISTS gateways (
    id          TEXT PRIMARY KEY,                   -- UUID
    tenant_id   TEXT NOT NULL REFERENCES tenants(id) ON DELETE CASCADE,
    slug        TEXT NOT NULL,
    config      TEXT NOT NULL DEFAULT '{}',         -- JSON
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    UNIQUE(tenant_id, slug)
);

-- Per-gateway provider configs: stores encrypted BYOK keys
CREATE TABLE IF NOT EXISTS provider_configs (
    id            TEXT PRIMARY KEY,
    gateway_id    TEXT NOT NULL REFERENCES gateways(id) ON DELETE CASCADE,
    provider      TEXT NOT NULL,
    alias         TEXT NOT NULL DEFAULT 'default',
    encrypted_key TEXT NOT NULL,                    -- base64(AES-256-GCM ciphertext)
    nonce         TEXT NOT NULL,                    -- base64(96-bit nonce)
    created_at    TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    UNIQUE(gateway_id, provider, alias)
);

-- Gateway auth tokens (bearer tokens for x-aig-token header)
CREATE TABLE IF NOT EXISTS auth_tokens (
    id          TEXT PRIMARY KEY,
    gateway_id  TEXT NOT NULL REFERENCES gateways(id) ON DELETE CASCADE,
    token_hash  TEXT NOT NULL UNIQUE,               -- SHA-256 hex of raw token
    scopes      TEXT NOT NULL DEFAULT '[]',         -- JSON array
    expires_at  TEXT,                               -- ISO8601 or NULL = never
    created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);

-- Routing rules evaluated in priority order
CREATE TABLE IF NOT EXISTS routing_rules (
    id          TEXT PRIMARY KEY,
    gateway_id  TEXT NOT NULL REFERENCES gateways(id) ON DELETE CASCADE,
    priority    INTEGER NOT NULL DEFAULT 0,
    conditions  TEXT NOT NULL DEFAULT '[]',         -- JSON [{field, op, value}]
    actions     TEXT NOT NULL DEFAULT '{}',         -- JSON {provider, model, fallbacks:[]}
    enabled     INTEGER NOT NULL DEFAULT 1
);

-- Per-provider model pricing (used for cost attribution).
-- All prices USD per 1K tokens.
CREATE TABLE IF NOT EXISTS model_pricing (
    provider            TEXT NOT NULL,
    model               TEXT NOT NULL,
    input_per_1k        REAL NOT NULL,
    output_per_1k       REAL NOT NULL,
    cache_write_per_1k  REAL,           -- prompt-cache write (e.g. Anthropic: 1.25x input)
    cache_read_per_1k   REAL,           -- prompt-cache read  (e.g. Anthropic: 0.1x input)
    updated_at          TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    PRIMARY KEY(provider, model)
);

-- Seed / update model prices. INSERT OR REPLACE keeps prices current on schema re-runs.
-- Use explicit column names to be safe against column-order differences in migrated DBs.
INSERT OR REPLACE INTO model_pricing (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('openai',    'gpt-4o',                      0.0025,   0.010,   NULL,      NULL,      strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR REPLACE INTO model_pricing (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('openai',    'gpt-4o-mini',                 0.00015,  0.0006,  NULL,      NULL,      strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR REPLACE INTO model_pricing (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('openai',    'gpt-4-turbo',                 0.010,    0.030,   NULL,      NULL,      strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR REPLACE INTO model_pricing (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('openai',    'gpt-3.5-turbo',               0.0005,   0.0015,  NULL,      NULL,      strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR REPLACE INTO model_pricing (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-opus-4-6',             0.015,    0.075,   0.01875,   0.0015,    strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR REPLACE INTO model_pricing (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-sonnet-4-6',           0.003,    0.015,   0.00375,   0.0003,    strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR REPLACE INTO model_pricing (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-haiku-4-5-20251001',   0.0008,   0.004,   0.001,     0.00008,   strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR REPLACE INTO model_pricing (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-haiku-4-5',            0.0008,   0.004,   0.001,     0.00008,   strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR REPLACE INTO model_pricing (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-3-5-sonnet-20241022',  0.003,    0.015,   0.00375,   0.0003,    strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR REPLACE INTO model_pricing (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-3-5-haiku-20241022',   0.0008,   0.004,   0.001,     0.00008,   strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR REPLACE INTO model_pricing (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('anthropic', 'claude-3-opus-20240229',      0.015,    0.075,   0.01875,   0.0015,    strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR REPLACE INTO model_pricing (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('gemini',    'gemini-1.5-pro',              0.00125,  0.005,   NULL,      NULL,      strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR REPLACE INTO model_pricing (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('gemini',    'gemini-1.5-flash',            0.000075, 0.0003,  NULL,      NULL,      strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR REPLACE INTO model_pricing (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('mistral',   'mistral-large-latest',        0.002,    0.006,   NULL,      NULL,      strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR REPLACE INTO model_pricing (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at) VALUES ('groq',      'llama-3.3-70b-versatile',     0.00059,  0.00079, NULL,      NULL,      strftime('%Y-%m-%dT%H:%M:%fZ','now'));
