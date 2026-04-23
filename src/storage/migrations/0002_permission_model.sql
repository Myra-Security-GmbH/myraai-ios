-- Migration: 0002
-- Description: Add missing columns and tables from pre-migration installs
-- All statements use IF NOT EXISTS and are fully idempotent.
-- Note: the organization_id -> tenant_id column rename is handled in the Lua
-- migration runner (M.migrate) because it requires conditional Lua logic.

ALTER TABLE `user`            ADD COLUMN IF NOT EXISTS last_login_at        BIGINT;
ALTER TABLE tenant            ADD COLUMN IF NOT EXISTS chat_presets_config   TEXT;
ALTER TABLE tenant            ADD COLUMN IF NOT EXISTS slash_commands_config TEXT;
ALTER TABLE chat_message      ADD COLUMN IF NOT EXISTS gateway_id            VARCHAR(36);
ALTER TABLE chat_message      ADD COLUMN IF NOT EXISTS model                 VARCHAR(255);
ALTER TABLE chat_conversation ADD COLUMN IF NOT EXISTS project_id            VARCHAR(36);
ALTER TABLE chat_conversation ADD COLUMN IF NOT EXISTS gateway_id_override   VARCHAR(36);
ALTER TABLE chat_conversation ADD COLUMN IF NOT EXISTS model_override        VARCHAR(128);
ALTER TABLE chat_conversation ADD COLUMN IF NOT EXISTS starred               TINYINT NOT NULL DEFAULT 0;
ALTER TABLE chat_conversation ADD COLUMN IF NOT EXISTS archived_at           BIGINT  NULL;
ALTER TABLE chat_conversation ADD COLUMN IF NOT EXISTS memory_disabled       TINYINT NOT NULL DEFAULT 0;
ALTER TABLE chat_conversation ADD INDEX  IF NOT EXISTS idx_conv_user_star (user_id, starred, updated_at);
ALTER TABLE chat_project_knowledge ADD COLUMN IF NOT EXISTS source          VARCHAR(32) NOT NULL DEFAULT 'text';
ALTER TABLE chat_memory       ADD COLUMN IF NOT EXISTS project_id            VARCHAR(36) NULL DEFAULT NULL;
ALTER TABLE chat_memory       ADD INDEX  IF NOT EXISTS idx_memory_project (project_id, created_at);

CREATE TABLE IF NOT EXISTS chat_command (
    id          VARCHAR(36)  NOT NULL,
    user_id     VARCHAR(36)  NOT NULL,
    name        VARCHAR(64)  NOT NULL,
    description VARCHAR(255) NOT NULL DEFAULT '',
    template    TEXT         NOT NULL,
    created_at  BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    updated_at  BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (id),
    KEY idx_chat_command_user (user_id),
    CONSTRAINT fk_chat_command_user FOREIGN KEY (user_id)
        REFERENCES `user`(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS chat_feedback (
    id              VARCHAR(36)  NOT NULL,
    conversation_id VARCHAR(36)  NOT NULL,
    user_id         VARCHAR(36)  NOT NULL,
    rating          INT          NOT NULL,
    comment         TEXT,
    created_at      BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    updated_at      BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    processed       TINYINT(1)   NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    UNIQUE KEY uq_feedback_conv (conversation_id),
    KEY idx_chat_feedback_user (user_id, created_at),
    CONSTRAINT fk_chat_feedback_conv FOREIGN KEY (conversation_id)
        REFERENCES chat_conversation(id) ON DELETE CASCADE,
    CONSTRAINT fk_chat_feedback_user FOREIGN KEY (user_id)
        REFERENCES `user`(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS app_feedback (
    id          VARCHAR(36)   NOT NULL,
    user_id     VARCHAR(36),
    type        VARCHAR(32)   NOT NULL DEFAULT 'other',
    summary     VARCHAR(255)  NOT NULL,
    description TEXT,
    url         VARCHAR(1024),
    created_at  BIGINT        NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    processed   TINYINT       NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    KEY idx_app_feedback_created (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS chat_share (
    id              VARCHAR(36)  NOT NULL,
    conversation_id VARCHAR(36)  NOT NULL,
    user_id         VARCHAR(36)  NOT NULL,
    token           VARCHAR(64)  NOT NULL,
    snapshot_json   LONGTEXT     NOT NULL,
    created_at      BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (id),
    UNIQUE KEY uq_share_conv  (conversation_id),
    UNIQUE KEY uq_share_token (token),
    CONSTRAINT fk_share_conv FOREIGN KEY (conversation_id)
        REFERENCES chat_conversation(id) ON DELETE CASCADE,
    CONSTRAINT fk_share_user FOREIGN KEY (user_id)
        REFERENCES `user`(id) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS chat_memory (
    id          VARCHAR(36)  NOT NULL,
    user_id     VARCHAR(36)  NOT NULL,
    content     TEXT         NOT NULL,
    type        VARCHAR(16)  NOT NULL DEFAULT 'fact',
    source      VARCHAR(16)  NOT NULL DEFAULT 'manual',
    project_id  VARCHAR(36)  NULL DEFAULT NULL,
    created_at  BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    updated_at  BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (id),
    KEY idx_memory_user (user_id, created_at),
    KEY idx_memory_project (project_id, created_at),
    CONSTRAINT fk_memory_user    FOREIGN KEY (user_id)    REFERENCES `user`(id)        ON DELETE CASCADE,
    CONSTRAINT fk_memory_project FOREIGN KEY (project_id) REFERENCES chat_project(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS conversation_embeddings (
    conversation_id  VARCHAR(36)  NOT NULL,
    user_id          VARCHAR(36)  NOT NULL,
    text             TEXT         NOT NULL,
    embedding        MEDIUMTEXT   NOT NULL,
    created_at       BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    updated_at       BIGINT       NOT NULL DEFAULT (UNIX_TIMESTAMP()),
    PRIMARY KEY (conversation_id),
    KEY idx_conv_emb_user (user_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

-- FK additions: tolerated errors 1826 (duplicate constraint) mean already applied
ALTER TABLE chat_conversation
    ADD CONSTRAINT fk_chat_conv_project
        FOREIGN KEY (project_id) REFERENCES chat_project(id) ON DELETE SET NULL;

ALTER TABLE chat_memory
    ADD CONSTRAINT fk_memory_project_conv
        FOREIGN KEY (project_id) REFERENCES chat_project(id);
