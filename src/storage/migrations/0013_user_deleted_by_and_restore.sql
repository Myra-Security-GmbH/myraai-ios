-- Migration: 0013
-- Description: Track who soft-deleted a user account, to support audit and admin restore.
--
-- The `user.deleted_at` column already exists and marks an account as deleted
-- (in-app "Delete Account"). Restoration is admin-only and clears `deleted_at`
-- back to NULL. This migration records the actor that performed the deletion so
-- the admin UI can show "deleted by X on date Y" alongside the restore button.

ALTER TABLE `user`
    ADD COLUMN IF NOT EXISTS `deleted_by_id` CHAR(36) NULL DEFAULT NULL AFTER `deleted_at`;
