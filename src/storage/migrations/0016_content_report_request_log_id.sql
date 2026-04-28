-- Migration: 0016
-- Description: Add request_log_id to content_report so a "Report this response"
-- click links back to the exact gateway request_log row that produced the
-- assistant message. Highest-leverage triage field for chat feedback — gives
-- moderators model, provider, latency, tokens, guardrail hits, and (when
-- logged) full request/response bodies in a single JOIN.
--
-- VARCHAR(36) matches request_log.id (UUID). NULL allowed: legacy reports
-- without the linkage stay valid and a report submitted before the chat
-- streaming wired up the X-Request-Id capture remains valid as well.

ALTER TABLE content_report
    ADD COLUMN IF NOT EXISTS request_log_id VARCHAR(36) NULL;

CREATE INDEX IF NOT EXISTS idx_content_report_request_log
    ON content_report(request_log_id);
