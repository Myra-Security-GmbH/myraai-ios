-- 0012: device_tokens — APNs push notification device tokens per user
CREATE TABLE IF NOT EXISTS `device_token` (
    `id`           VARCHAR(36)  NOT NULL,
    `user_id`      VARCHAR(36)  NOT NULL,
    `token`        VARCHAR(200) NOT NULL,
    `platform`     VARCHAR(10)  NOT NULL DEFAULT 'ios',
    `created_at`   INT          NOT NULL,
    `updated_at`   INT          NOT NULL,
    PRIMARY KEY (`id`),
    UNIQUE KEY `uq_device_token_token` (`token`),
    KEY `idx_device_token_user` (`user_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
