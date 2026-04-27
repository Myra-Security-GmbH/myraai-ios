-- Migration: 0014
-- Description: content_report — user-submitted reports of inappropriate or
-- inaccurate model output. Required by Google Play's generative-AI policy
-- (effective Jan 28 2026): users must be able to flag offensive AI output
-- without leaving the app, and the developer must operate a moderation
-- pipeline.
--
-- A report carries a snapshot of the offending message_text at the time of
-- the report so subsequent edits or deletions don't erase the evidence
-- moderators need to triage it.

CREATE TABLE IF NOT EXISTS `content_report` (
    `id`               CHAR(36)     NOT NULL,
    `user_id`          CHAR(36)     NOT NULL,
    `tenant_id`        CHAR(36)     NULL,
    `conversation_id`  CHAR(36)     NULL,
    `message_id`       CHAR(36)     NULL,
    `message_text`     TEXT         NULL,
    `reason`           VARCHAR(32)  NOT NULL,   -- offensive | inaccurate | unsafe | other
    `notes`            TEXT         NULL,
    `status`           VARCHAR(16)  NOT NULL DEFAULT 'open',  -- open | triaged | dismissed
    `created_at`       BIGINT       NOT NULL,
    `triaged_at`       BIGINT       NULL,
    `triaged_by_id`    CHAR(36)     NULL,
    PRIMARY KEY (`id`),
    KEY `idx_content_report_status_time` (`status`, `created_at`),
    KEY `idx_content_report_tenant_status` (`tenant_id`, `status`),
    KEY `idx_content_report_user` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
