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
    siem_config   TEXT,
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
    id         VARCHAR(36)  NOT NULL,
    tenant_id  VARCHAR(36),
    email      VARCHAR(255) NOT NULL,
    name       VARCHAR(255),
    role       VARCHAR(32)  NOT NULL DEFAULT 'member',
    deleted_at BIGINT,
    created_at BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
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

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-opus-4-6',             0.015,    0.075,    0.01875,   0.0015,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-sonnet-4-6',           0.003,    0.015,    0.00375,   0.0003,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-haiku-4-5-20251001',   0.0008,   0.004,    0.001,     0.00008,   UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-haiku-4-5',            0.0008,   0.004,    0.001,     0.00008,   UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-3-5-sonnet-20241022',  0.003,    0.015,    0.00375,   0.0003,    UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-3-5-haiku-20241022',   0.0008,   0.004,    0.001,     0.00008,   UNIX_TIMESTAMP())
ON DUPLICATE KEY UPDATE input_per_1k=VALUES(input_per_1k), output_per_1k=VALUES(output_per_1k), cache_write_per_1k=VALUES(cache_write_per_1k), cache_read_per_1k=VALUES(cache_read_per_1k), updated_at=VALUES(updated_at);

INSERT INTO model_price (provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k, updated_at)
VALUES ('anthropic', 'claude-3-opus-20240229',      0.015,    0.075,    0.01875,   0.0015,    UNIX_TIMESTAMP())
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
