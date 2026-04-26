-- Migration: 0008
-- Description: Tenant-scoped provider keys and Anthropic usage snapshots

-- Make gateway_id nullable so provider_config can hold tenant-scoped keys
-- (e.g. anthropic-admin) that are not tied to a specific gateway.
ALTER TABLE provider_config
    DROP FOREIGN KEY fk_provider_config_gateway;

ALTER TABLE provider_config
    MODIFY COLUMN gateway_id VARCHAR(36) NULL;

ALTER TABLE provider_config
    ADD CONSTRAINT fk_provider_config_gateway
        FOREIGN KEY (gateway_id) REFERENCES gateway(id) ON DELETE CASCADE;

-- Add tenant_id for tenant-scoped keys (null for gateway-scoped rows).
ALTER TABLE provider_config
    ADD COLUMN IF NOT EXISTS tenant_id VARCHAR(36) NULL AFTER gateway_id;

ALTER TABLE provider_config
    ADD CONSTRAINT fk_provider_config_tenant
        FOREIGN KEY (tenant_id) REFERENCES tenant(id) ON DELETE CASCADE;

-- Unique constraint for tenant-scoped keys.
ALTER TABLE provider_config
    ADD UNIQUE KEY uq_tenant_provider_config (tenant_id, provider, alias);

-- Per-tenant daily Anthropic API usage snapshots.
-- source='byok'  → pulled from Anthropic Admin API using tenant's own admin key.
-- source='local' → aggregated from our request_log (no admin key configured).
CREATE TABLE IF NOT EXISTS anthropic_usage_snapshot (
    id                      VARCHAR(36)    NOT NULL,
    tenant_id               VARCHAR(36)    NOT NULL,
    snapshot_date           DATE           NOT NULL,
    source                  ENUM('byok','local') NOT NULL DEFAULT 'local',
    model                   VARCHAR(128)   NOT NULL DEFAULT '',
    service_tier            VARCHAR(32)    NOT NULL DEFAULT 'standard',
    uncached_input_tokens   BIGINT         NOT NULL DEFAULT 0,
    output_tokens           BIGINT         NOT NULL DEFAULT 0,
    cache_write_5m_tokens   BIGINT         NOT NULL DEFAULT 0,
    cache_write_1h_tokens   BIGINT         NOT NULL DEFAULT 0,
    cache_read_tokens       BIGINT         NOT NULL DEFAULT 0,
    web_search_requests     INT            NOT NULL DEFAULT 0,
    cost_usd                DECIMAL(18,8)  NOT NULL DEFAULT 0,
    fetched_at              TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP
                                           ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uq_usage_snapshot (tenant_id, snapshot_date, model, service_tier, source),
    KEY idx_usage_tenant_date (tenant_id, snapshot_date),
    CONSTRAINT fk_usage_snapshot_tenant
        FOREIGN KEY (tenant_id) REFERENCES tenant(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
