-- Migration: 0004
-- Description: Add conversation sharing columns (shared_in_project, shared_at, shared_by)

ALTER TABLE chat_conversation ADD COLUMN IF NOT EXISTS shared_in_project TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE chat_conversation ADD COLUMN IF NOT EXISTS shared_at          BIGINT NULL;
ALTER TABLE chat_conversation ADD COLUMN IF NOT EXISTS shared_by          VARCHAR(36) NULL;
