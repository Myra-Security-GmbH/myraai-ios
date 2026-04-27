-- Migration: 0010
-- Description: Provider health status table — tracks live availability from status-page polling

CREATE TABLE IF NOT EXISTS provider_health (
    provider   VARCHAR(64)       NOT NULL,
    status     VARCHAR(16)       NOT NULL DEFAULT 'unknown',
    message    VARCHAR(255)      NULL,
    latency_ms SMALLINT UNSIGNED NULL,
    checked_at BIGINT            NOT NULL DEFAULT 0,
    PRIMARY KEY (provider)
);
