-- storage/schema_mysql.sql — DDL for MySQL 8.0+ (production backend)
-- Applied once via storage/mysql.lua:M.migrate()
-- All tables in a single database (no ATTACH needed).
-- Safe to run repeatedly: CREATE TABLE IF NOT EXISTS everywhere.

-- ---------------------------------------------------------------------------
-- Config tables (mirrors schema_config.sql)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS tenant (
    id            VARCHAR(36)  NOT NULL,
    slug          VARCHAR(255) NOT NULL,
    plan          VARCHAR(64)  NOT NULL DEFAULT 'free',
    budget_usd    DOUBLE,
    budget_period VARCHAR(16)  NOT NULL DEFAULT 'monthly',
    siem_config         TEXT,
    chat_presets_config TEXT,
    deleted_at    BIGINT,
    created_at    BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (id),
    UNIQUE KEY uq_tenant_slug (slug)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS gateway (
    id          VARCHAR(36)  NOT NULL,
    tenant_id   VARCHAR(36)  NOT NULL,
    slug        VARCHAR(255) NOT NULL,
    config      TEXT         NOT NULL DEFAULT ('{}'),
    created_at  BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (id),
    UNIQUE KEY uq_gateway_tenant_slug (tenant_id, slug),
    CONSTRAINT fk_gateway_tenant FOREIGN KEY (tenant_id)
        REFERENCES tenant (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS provider_config (
    id            VARCHAR(36)  NOT NULL,
    gateway_id    VARCHAR(36)  NOT NULL,
    provider      VARCHAR(64)  NOT NULL,
    alias         VARCHAR(64)  NOT NULL DEFAULT 'default',
    encrypted_key TEXT         NOT NULL,
    nonce         VARCHAR(64)  NOT NULL,
    created_at    BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (id),
    UNIQUE KEY uq_provider_config (gateway_id, provider, alias),
    CONSTRAINT fk_provider_config_gateway FOREIGN KEY (gateway_id)
        REFERENCES gateway (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `user` (
    id            VARCHAR(36)  NOT NULL,
    tenant_id     VARCHAR(36),
    email         VARCHAR(255) NOT NULL,
    name          VARCHAR(255),
    role          VARCHAR(32)  NOT NULL DEFAULT 'member',
    deleted_at    BIGINT,
    created_at    BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    last_login_at BIGINT,
    PRIMARY KEY (id),
    UNIQUE KEY uq_user_email (email),
    CONSTRAINT fk_user_tenant FOREIGN KEY (tenant_id)
        REFERENCES tenant (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS user_gateway_access (
    user_id    VARCHAR(36) NOT NULL,
    gateway_id VARCHAR(36) NOT NULL,
    PRIMARY KEY (user_id, gateway_id),
    CONSTRAINT fk_uga_user    FOREIGN KEY (user_id)    REFERENCES `user`   (id) ON DELETE CASCADE,
    CONSTRAINT fk_uga_gateway FOREIGN KEY (gateway_id) REFERENCES gateway  (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS auth_token (
    id            VARCHAR(36)  NOT NULL,
    gateway_id    VARCHAR(36)  NOT NULL,
    token_hash    VARCHAR(64)  NOT NULL,
    scopes        TEXT         NOT NULL DEFAULT ('[]'),
    expires_at    BIGINT,
    created_at    BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    user_id       VARCHAR(36),
    label         VARCHAR(255),
    rate_limit    TEXT,
    budget_usd    DOUBLE,
    budget_period VARCHAR(16)  NOT NULL DEFAULT 'monthly',
    PRIMARY KEY (id),
    UNIQUE KEY uq_auth_token_hash (token_hash),
    CONSTRAINT fk_auth_token_gateway FOREIGN KEY (gateway_id)
        REFERENCES gateway (id) ON DELETE CASCADE,
    CONSTRAINT fk_auth_token_user    FOREIGN KEY (user_id)
        REFERENCES `user` (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS routing_rule (
    id          VARCHAR(36) NOT NULL,
    gateway_id  VARCHAR(36) NOT NULL,
    priority    INT         NOT NULL DEFAULT 0,
    conditions  TEXT        NOT NULL DEFAULT ('[]'),
    actions     TEXT        NOT NULL DEFAULT ('{}'),
    enabled     TINYINT     NOT NULL DEFAULT 1,
    PRIMARY KEY (id),
    CONSTRAINT fk_routing_rule_gateway FOREIGN KEY (gateway_id)
        REFERENCES gateway (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS model_price (
    provider            VARCHAR(64) NOT NULL,
    model               VARCHAR(128) NOT NULL,
    input_per_1k        DOUBLE      NOT NULL,
    output_per_1k       DOUBLE      NOT NULL,
    cache_write_per_1k  DOUBLE,
    cache_read_per_1k   DOUBLE,
    updated_at          BIGINT      NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (provider, model)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS spend_ledger (
    entity_type  VARCHAR(16)  NOT NULL,
    entity_id    VARCHAR(36)  NOT NULL,
    period       VARCHAR(16)  NOT NULL,
    amount_micro BIGINT       NOT NULL DEFAULT 0,
    updated_at   BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (entity_type, entity_id, period),
    KEY idx_spend_entity (entity_type, entity_id, period)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS playground_trace (
    id           VARCHAR(36)  NOT NULL,
    gateway_id   VARCHAR(36)  NOT NULL,
    model        VARCHAR(128),
    created_at   BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    completed_at BIGINT,
    status       VARCHAR(16)  NOT NULL DEFAULT 'running',
    error        TEXT,
    source       VARCHAR(16)  NOT NULL DEFAULT 'playground',
    PRIMARY KEY (id),
    KEY idx_pgt_gateway (gateway_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS playground_trace_step (
    id        BIGINT      NOT NULL AUTO_INCREMENT,
    trace_id  VARCHAR(36) NOT NULL,
    seq       INT         NOT NULL,
    step      VARCHAR(64) NOT NULL,
    data      TEXT        NOT NULL DEFAULT ('{}'),
    ts        BIGINT      NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (id),
    KEY idx_pgts_trace_seq (trace_id, seq),
    CONSTRAINT fk_pts_trace FOREIGN KEY (trace_id)
        REFERENCES playground_trace (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS audit_log (
    id        BIGINT      NOT NULL AUTO_INCREMENT,
    ts        BIGINT      NOT NULL DEFAULT (UNIX_TIMESTAMP() * 1000),
    actor_id  VARCHAR(36),
    actor_ip  VARCHAR(64),
    method    VARCHAR(16) NOT NULL,
    path      TEXT        NOT NULL,
    status    INT,
    PRIMARY KEY (id),
    KEY idx_audit_ts (ts)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- Auth tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS email_otp (
    id         VARCHAR(36)  NOT NULL,
    email      VARCHAR(255) NOT NULL,
    code_hash  VARCHAR(64)  NOT NULL,
    expires_at BIGINT       NOT NULL,
    used_at    BIGINT,
    ip_addr    VARCHAR(64),
    created_at BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (id),
    KEY idx_otp_email (email, expires_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS oauth_link (
    user_id    VARCHAR(36)  NOT NULL,
    provider   VARCHAR(32)  NOT NULL,
    subject    VARCHAR(255) NOT NULL,
    email      VARCHAR(255),
    PRIMARY KEY (provider, subject),
    CONSTRAINT fk_oauth_user FOREIGN KEY (user_id)
        REFERENCES `user` (id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- Log tables (mirrors schema_logs.sql)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS request_log (
    id                     VARCHAR(36)  NOT NULL,
    tenant_id              VARCHAR(36)  NOT NULL,
    gateway_id             VARCHAR(36)  NOT NULL,
    provider               VARCHAR(64)  NOT NULL,
    model                  VARCHAR(128) NOT NULL,
    status                 INT          NOT NULL,
    cached                 TINYINT      NOT NULL DEFAULT 0,
    input_tokens           BIGINT       NOT NULL DEFAULT 0,
    output_tokens          BIGINT       NOT NULL DEFAULT 0,
    cache_creation_tokens  BIGINT       NOT NULL DEFAULT 0,
    cache_read_tokens      BIGINT       NOT NULL DEFAULT 0,
    cost_usd               DOUBLE       NOT NULL DEFAULT 0,
    latency_ms             BIGINT       NOT NULL DEFAULT 0,
    ts                     BIGINT       NOT NULL,
    prompt                 MEDIUMTEXT,
    response               MEDIUMTEXT,
    meta                   TEXT         NOT NULL DEFAULT ('{}'),
    blocked                TINYINT      NOT NULL DEFAULT 0,
    blocked_by             VARCHAR(64),
    block_reason           TEXT,
    guardrail_latency_ms   BIGINT,
    guardrail_verdict      VARCHAR(16),
    saved_cost_usd         DOUBLE,
    saved_latency_ms       BIGINT,
    upstream_latency_ms    BIGINT,
    time_to_first_token_ms BIGINT,
    upstream_attempts      INT          NOT NULL DEFAULT 0,
    fallback_provider      VARCHAR(64),
    fallback_model         VARCHAR(128),
    provider_request_id    VARCHAR(128),
    request_size_bytes     BIGINT       NOT NULL DEFAULT 0,
    quota_remaining        DOUBLE,
    user_id                VARCHAR(36),
    token_label            VARCHAR(255),
    detectors_fired        TEXT,
    scrub_applied          TINYINT      NOT NULL DEFAULT 0,
    response_raw           MEDIUMTEXT,
    prompt_scrubbed        MEDIUMTEXT,
    token_quota_remaining  DOUBLE,
    tenant_quota_remaining DOUBLE,
    trace_id               VARCHAR(36),
    PRIMARY KEY (id),
    KEY idx_log_trace_id  (trace_id),
    KEY idx_log_tenant_ts  (tenant_id, ts),
    KEY idx_log_gateway_ts (gateway_id, ts),
    KEY idx_log_ts         (ts)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS client_error_log (
    id         VARCHAR(36)  NOT NULL,
    message    TEXT         NOT NULL,
    stack      MEDIUMTEXT,
    url        VARCHAR(500),
    user_agent VARCHAR(500),
    ts         BIGINT       NOT NULL,
    PRIMARY KEY (id),
    KEY idx_client_error_ts (ts)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS semantic_cache (
    id            VARCHAR(36)  NOT NULL,
    gateway_id    VARCHAR(36)  NOT NULL,
    model         VARCHAR(128) NOT NULL,
    prompt_hash   VARCHAR(64)  NOT NULL,
    embedding     MEDIUMTEXT   NOT NULL,
    response_body MEDIUMTEXT   NOT NULL,
    cost_usd      DOUBLE       NOT NULL DEFAULT 0,
    created_at    BIGINT       NOT NULL,
    expires_at    BIGINT       NOT NULL DEFAULT 0,
    hit_count     INT          NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    KEY idx_semantic_cache_gw_model (gateway_id, model, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ---------------------------------------------------------------------------
-- Seed model prices (idempotent: ON DUPLICATE KEY UPDATE)
-- ---------------------------------------------------------------------------
INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('openai',    'gpt-4o',                      0.0025,   0.010,    NULL,      NULL,      UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('openai',    'gpt-4o-mini',                 0.00015,  0.0006,   NULL,      NULL,      UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('openai',    'gpt-4-turbo',                 0.010,    0.030,    NULL,      NULL,      UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('openai',    'gpt-3.5-turbo',               0.0005,   0.0015,   NULL,      NULL,      UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), updated_at=VALUES(updated_at);

-- Anthropic — Claude 4.6 (latest)
INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-opus-4-6',             0.005,    0.025,    0.00625,   0.0005,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-opus-4-6-20260205',    0.005,    0.025,    0.00625,   0.0005,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-sonnet-4-6',           0.003,    0.015,    0.00375,   0.0003,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-haiku-4-5',            0.001,    0.005,    0.00125,   0.0001,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-haiku-4-5-20251001',   0.001,    0.005,    0.00125,   0.0001,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

-- Anthropic — Claude 4.5
INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-opus-4-5',             0.005,    0.025,    0.00625,   0.0005,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-opus-4-5-20251101',    0.005,    0.025,    0.00625,   0.0005,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-sonnet-4-5',           0.003,    0.015,    0.00375,   0.0003,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-sonnet-4-5-20250929',  0.003,    0.015,    0.00375,   0.0003,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

-- Anthropic — Claude 4.1 / 4.0 (legacy)
INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-opus-4-1',             0.015,    0.075,    0.01875,   0.0015,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-opus-4-1-20250805',    0.015,    0.075,    0.01875,   0.0015,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-opus-4-0',             0.015,    0.075,    0.01875,   0.0015,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-opus-4-20250514',      0.015,    0.075,    0.01875,   0.0015,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-sonnet-4-0',           0.003,    0.015,    0.00375,   0.0003,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-sonnet-4-20250514',    0.003,    0.015,    0.00375,   0.0003,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

-- Anthropic — Claude 3.x (legacy/deprecated)
INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-3-7-sonnet-20250219',  0.003,    0.015,    0.00375,   0.0003,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-3-haiku-20240307',     0.00025,  0.00125,  0.0003,    0.00003,   UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('gemini',    'gemini-1.5-pro',              0.00125,  0.005,    NULL,      NULL,      UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('gemini',    'gemini-1.5-flash',            0.000075, 0.0003,   NULL,      NULL,      UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('mistral',   'mistral-large-latest',        0.002,    0.006,    NULL,      NULL,      UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('groq',      'llama-3.3-70b-versatile',     0.00059,  0.00079,  NULL,      NULL,      UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), updated_at=VALUES(updated_at);

-- vLLM / self-hosted
INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('vllm',      'qwen3-235b',                  0.0,      0.0,      NULL,      NULL,      UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('vllm',      'qwen3-30b-a3b',               0.0,      0.0,      NULL,      NULL,      UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), updated_at=VALUES(updated_at);

-- ---------------------------------------------------------------------------
-- Chat tables
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS chat_conversation (
    id            VARCHAR(36)  NOT NULL,
    user_id       VARCHAR(36)  NOT NULL,
    gateway_id    VARCHAR(36)  NOT NULL,
    title         VARCHAR(255) NOT NULL DEFAULT 'New conversation',
    model         VARCHAR(128) NOT NULL DEFAULT '',
    system_prompt TEXT,
    temperature   FLOAT        DEFAULT 0.7,
    max_tokens    INT          DEFAULT 2048,
    created_at    BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    updated_at    BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    deleted_at    BIGINT,
    PRIMARY KEY (id),
    KEY idx_chat_conv_user (user_id, updated_at),
    CONSTRAINT fk_chat_conv_user    FOREIGN KEY (user_id)    REFERENCES `user`(id)   ON DELETE CASCADE,
    CONSTRAINT fk_chat_conv_gateway FOREIGN KEY (gateway_id) REFERENCES gateway(id)  ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS chat_message (
    id                VARCHAR(36)  NOT NULL,
    conversation_id   VARCHAR(36)  NOT NULL,
    parent_message_id VARCHAR(36),
    role              VARCHAR(16)  NOT NULL,
    content           MEDIUMTEXT   NOT NULL,
    input_tokens      INT,
    output_tokens     INT,
    cost_usd          DOUBLE,
    latency_ms        INT,
    gateway_id        VARCHAR(36),
    model             VARCHAR(255),
    created_at        BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    deleted_at        BIGINT,
    PRIMARY KEY (id),
    KEY idx_chat_msg_conv_ts (conversation_id, created_at),
    CONSTRAINT fk_chat_msg_conv FOREIGN KEY (conversation_id)
        REFERENCES chat_conversation(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS chat_attachment (
    id          VARCHAR(36)  NOT NULL,
    message_id  VARCHAR(36)  NOT NULL,
    filename    VARCHAR(255) NOT NULL,
    mime_type   VARCHAR(128) NOT NULL,
    size_bytes  INT          NOT NULL,
    data        LONGTEXT     NOT NULL,
    created_at  BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (id),
    CONSTRAINT fk_chat_att_msg FOREIGN KEY (message_id)
        REFERENCES chat_message(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS chat_preset (
    id            VARCHAR(36)  NOT NULL,
    user_id       VARCHAR(36)  NOT NULL,
    name          VARCHAR(128) NOT NULL,
    model         VARCHAR(128) NOT NULL DEFAULT '',
    system_prompt TEXT,
    temperature   FLOAT,
    max_tokens    INT,
    created_at    BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    updated_at    BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (id),
    KEY idx_chat_preset_user (user_id),
    CONSTRAINT fk_chat_preset_user FOREIGN KEY (user_id)
        REFERENCES `user`(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS chat_feedback (
    id              VARCHAR(36)  NOT NULL,
    conversation_id VARCHAR(36)  NOT NULL,
    user_id         VARCHAR(36)  NOT NULL,
    rating          INT          NOT NULL,
    comment         TEXT,
    created_at      BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    updated_at      BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    processed       TINYINT(1)   NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    UNIQUE KEY uq_feedback_conv (conversation_id),
    KEY idx_chat_feedback_user (user_id, created_at),
    CONSTRAINT fk_chat_feedback_conv FOREIGN KEY (conversation_id)
        REFERENCES chat_conversation(id) ON DELETE CASCADE,
    CONSTRAINT fk_chat_feedback_user FOREIGN KEY (user_id)
        REFERENCES `user`(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ── Slash commands ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS chat_command (
    id          VARCHAR(36)  NOT NULL,
    user_id     VARCHAR(36)  NOT NULL,
    name        VARCHAR(64)  NOT NULL,
    description VARCHAR(255) NOT NULL DEFAULT '',
    template    TEXT         NOT NULL,
    created_at  BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    updated_at  BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (id),
    KEY idx_chat_command_user (user_id),
    CONSTRAINT fk_chat_command_user FOREIGN KEY (user_id)
        REFERENCES `user`(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- ── Projects ──────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS chat_project (
    id                 VARCHAR(36)   NOT NULL,
    tenant_id          VARCHAR(36)   NOT NULL,
    name               VARCHAR(255)  NOT NULL,
    description        TEXT,
    instructions       MEDIUMTEXT,
    icon               VARCHAR(8)    NOT NULL DEFAULT '📁',
    color              VARCHAR(16)   NOT NULL DEFAULT '#2563eb',
    default_gateway_id VARCHAR(36),
    default_model      VARCHAR(128),
    created_by         VARCHAR(36)   NOT NULL,
    created_at         BIGINT        NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    updated_at         BIGINT        NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    deleted_at         BIGINT,
    PRIMARY KEY (id),
    KEY idx_chat_project_tenant (tenant_id, updated_at),
    CONSTRAINT fk_chat_project_tenant  FOREIGN KEY (tenant_id)          REFERENCES tenant(id)  ON DELETE CASCADE,
    CONSTRAINT fk_chat_project_creator FOREIGN KEY (created_by)         REFERENCES `user`(id),
    CONSTRAINT fk_chat_project_gw      FOREIGN KEY (default_gateway_id) REFERENCES gateway(id) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS chat_project_member (
    project_id  VARCHAR(36)  NOT NULL,
    user_id     VARCHAR(36)  NOT NULL,
    role        VARCHAR(16)  NOT NULL DEFAULT 'viewer',
    invited_by  VARCHAR(36),
    joined_at   BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (project_id, user_id),
    KEY idx_chat_proj_member_user (user_id),
    CONSTRAINT fk_proj_member_project FOREIGN KEY (project_id) REFERENCES chat_project(id) ON DELETE CASCADE,
    CONSTRAINT fk_proj_member_user    FOREIGN KEY (user_id)    REFERENCES `user`(id)        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS chat_project_knowledge (
    id              VARCHAR(36)  NOT NULL,
    project_id      VARCHAR(36)  NOT NULL,
    filename        VARCHAR(255) NOT NULL,
    content_type    VARCHAR(128) NOT NULL DEFAULT 'text/plain',
    size_bytes      INT          NOT NULL DEFAULT 0,
    extracted_text  MEDIUMTEXT   NOT NULL,
    token_count     INT          NOT NULL DEFAULT 0,
    created_by      VARCHAR(36)  NOT NULL,
    created_at      BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (id),
    UNIQUE KEY uq_proj_know_name (project_id, filename),
    KEY idx_chat_proj_know_project (project_id, created_at),
    CONSTRAINT fk_proj_know_project FOREIGN KEY (project_id) REFERENCES chat_project(id) ON DELETE CASCADE,
    CONSTRAINT fk_proj_know_user    FOREIGN KEY (created_by) REFERENCES `user`(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Original binary for knowledge files uploaded via the /knowledge/upload endpoint.
-- Kept in a separate table so list/context-injection queries never load the blob.
CREATE TABLE IF NOT EXISTS chat_project_knowledge_blob (
    knowledge_id    VARCHAR(36)  NOT NULL,
    data            LONGBLOB     NOT NULL,
    PRIMARY KEY (knowledge_id),
    CONSTRAINT fk_proj_know_blob FOREIGN KEY (knowledge_id)
        REFERENCES chat_project_knowledge(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- Add project_id + gateway/model override columns to conversations (idempotent via ALTER IGNORE)
-- In MySQL 8+ use IF NOT EXISTS:
ALTER TABLE chat_conversation
    ADD COLUMN IF NOT EXISTS project_id          VARCHAR(36),
    ADD COLUMN IF NOT EXISTS gateway_id_override VARCHAR(36),
    ADD COLUMN IF NOT EXISTS model_override      VARCHAR(128);

-- Starring + archiving
ALTER TABLE chat_conversation
    ADD COLUMN IF NOT EXISTS starred     TINYINT NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS archived_at BIGINT  NULL;
ALTER TABLE chat_conversation
    ADD INDEX IF NOT EXISTS idx_conv_user_star (user_id, starred, updated_at);
