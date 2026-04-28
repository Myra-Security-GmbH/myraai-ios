-- Migration: 0015
-- Description: Add client_context JSON column to app_feedback and content_report
-- so submissions can carry browser- and device-side diagnostic context (route,
-- viewport, timezone, locale, color_scheme, app/OS version, battery, disk,
-- connection — populated by Layer 1 + Layer 2 collectors on the client).
--
-- Layer 3 (server-supplied identity, request_id, etc.) is folded into the same
-- JSON under client_context.server, so the column is the single canonical
-- location for diagnostic context across all feedback paths.
--
-- The column is nullable for backwards compatibility with rows submitted by
-- old client builds that don't include the collector.

ALTER TABLE app_feedback
    ADD COLUMN IF NOT EXISTS client_context JSON NULL;

ALTER TABLE content_report
    ADD COLUMN IF NOT EXISTS client_context JSON NULL;
