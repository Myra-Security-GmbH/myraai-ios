-- Migration: 0004
-- Description: add_compaction_triggered_to_request_log

-- Track whether context compaction actually fired on a given request,
-- and how large the context was at the point compaction was triggered.
-- compaction_triggered: 1 when Anthropic returned a compaction_summary block (confirmed)
-- compaction_tokens_before: estimated input token count at the moment compaction was injected
ALTER TABLE request_log
    ADD COLUMN IF NOT EXISTS compaction_triggered    TINYINT(1) NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS compaction_tokens_before INT       NOT NULL DEFAULT 0;
