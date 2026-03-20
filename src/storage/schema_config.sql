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

-- Per-provider model pricing (used for cost attribution)
CREATE TABLE IF NOT EXISTS model_pricing (
    provider       TEXT NOT NULL,
    model          TEXT NOT NULL,
    input_per_1k   REAL NOT NULL,
    output_per_1k  REAL NOT NULL,
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
    PRIMARY KEY(provider, model)
);

-- Seed some common model prices (USD per 1K tokens)
INSERT OR IGNORE INTO model_pricing VALUES ('openai',    'gpt-4o',                0.0025,  0.010,  strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR IGNORE INTO model_pricing VALUES ('openai',    'gpt-4o-mini',           0.00015, 0.0006, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR IGNORE INTO model_pricing VALUES ('openai',    'gpt-4-turbo',           0.010,   0.030,  strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR IGNORE INTO model_pricing VALUES ('openai',    'gpt-3.5-turbo',         0.0005,  0.0015, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR IGNORE INTO model_pricing VALUES ('anthropic', 'claude-opus-4-6',       0.015,   0.075,  strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR IGNORE INTO model_pricing VALUES ('anthropic', 'claude-sonnet-4-6',     0.003,   0.015,  strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR IGNORE INTO model_pricing VALUES ('anthropic', 'claude-haiku-4-5-20251001', 0.00025, 0.00125, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR IGNORE INTO model_pricing VALUES ('gemini',    'gemini-1.5-pro',        0.00125, 0.005,  strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR IGNORE INTO model_pricing VALUES ('gemini',    'gemini-1.5-flash',      0.000075,0.0003, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR IGNORE INTO model_pricing VALUES ('mistral',   'mistral-large-latest',  0.002,   0.006,  strftime('%Y-%m-%dT%H:%M:%fZ','now'));
INSERT OR IGNORE INTO model_pricing VALUES ('groq',      'llama-3.3-70b-versatile', 0.00059, 0.00079, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
