-- Migration: 0007
-- Description: Add mcp_connector table and cache_deletion_tokens column

CREATE TABLE IF NOT EXISTS mcp_connector (
    id          VARCHAR(36)  NOT NULL,
    tenant_id   VARCHAR(36)  NOT NULL,
    gateway_id  VARCHAR(36)  DEFAULT NULL,
    name        VARCHAR(120) NOT NULL,
    server_url  VARCHAR(500) NOT NULL,
    auth_type   ENUM('none','bearer','header') NOT NULL DEFAULT 'none',
    auth_value  TEXT         DEFAULT NULL,
    created_at  BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    updated_at  BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (id),
    KEY idx_mcp_tenant  (tenant_id),
    KEY idx_mcp_gateway (gateway_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

ALTER TABLE request_log ADD COLUMN IF NOT EXISTS cache_deletion_tokens BIGINT NOT NULL DEFAULT 0;
