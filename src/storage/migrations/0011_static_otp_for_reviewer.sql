-- Migration: 0011
-- Description: static_otp_for_reviewer
-- When static_otp_hash is set on a user, the email OTP flow is bypassed:
-- otp/request skips the email send, otp/verify accepts the static code directly.
-- Intended for service accounts (e.g. app store reviewers) that cannot receive email.
ALTER TABLE `user`
    ADD COLUMN IF NOT EXISTS static_otp_hash VARCHAR(64) NULL DEFAULT NULL;
