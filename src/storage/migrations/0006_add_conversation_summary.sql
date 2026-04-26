-- Migration: 0006
-- Description: Add conversation_summary table for context compaction

CREATE TABLE IF NOT EXISTS conversation_summary (
    id                VARCHAR(36)  NOT NULL,
    conversation_id   VARCHAR(36)  NOT NULL,
    summary_text      TEXT         NOT NULL,
    first_message_id  VARCHAR(36)  NOT NULL,
    last_message_id   VARCHAR(36)  NOT NULL,
    message_count     INT          NOT NULL DEFAULT 0,
    model_used        VARCHAR(128) NOT NULL,
    created_at        BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (id),
    KEY idx_conv_summary (conversation_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
