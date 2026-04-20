-- config/gateway.docker.lua — Docker image runtime configuration.
-- All settings are read from environment variables.
-- Loaded via AIG_CONFIG=/opt/ai-gateway/config/gateway.lua inside the container.

local function env(name, default)
    return os.getenv(name) or default
end

return {

    -- -------------------------------------------------------------------------
    -- Admin authentication (JWT + Google SSO + Email OTP)
    -- -------------------------------------------------------------------------
    auth = {
        jwt_secret           = env("AIG_JWT_SECRET",          "dev-change-me"),
        jwt_expiry_secs      = tonumber(env("AIG_JWT_EXPIRY_SECS", "28800")),
        google_client_id     = env("AIG_GOOGLE_CLIENT_ID"),
        google_client_secret = env("AIG_GOOGLE_CLIENT_SECRET"),
        google_redirect_uri  = env("AIG_GOOGLE_REDIRECT_URI",
                                   "https://ai-api-admin.myra.eu/admin/auth/google/callback"),
        otp_from_email       = env("AIG_OTP_FROM_EMAIL",      "noreply@ai.myra.eu"),
        otp_expiry_secs      = tonumber(env("AIG_OTP_EXPIRY_SECS",  "900")),
    },

    -- -------------------------------------------------------------------------
    -- Storage backend
    -- -------------------------------------------------------------------------
    storage = env("AIG_STORAGE", "sqlite"),

    sqlite = {
        config_db = env("AIG_DATA_DIR", "/data") .. "/config.db",
        logs_db   = env("AIG_DATA_DIR", "/data") .. "/logs.db",
    },

    mysql = {
        host         = env("AIG_MYSQL_HOST", "127.0.0.1"),
        port         = tonumber(env("AIG_MYSQL_PORT", "3306")),
        database     = env("AIG_MYSQL_DB",   "ai_gateway"),
        user         = env("AIG_MYSQL_USER",  "gateway"),
        password     = env("AIG_MYSQL_PASS",  ""),
        pool_size    = 20,
        pool_timeout = 10000,
    },

    -- -------------------------------------------------------------------------
    -- State backend
    -- -------------------------------------------------------------------------
    state = env("AIG_STATE", "shared_dict"),

    shared_dict = {
        cache      = "aig_cache",
        rate_limit = "aig_ratelimit",
        config     = "aig_config",
        byok       = "aig_byok",
        metrics    = "aig_metrics",
    },

    redis = {
        host         = env("REDIS_HOST", "127.0.0.1"),
        port         = tonumber(env("REDIS_PORT", "6379")),
        auth         = env("REDIS_AUTH"),
        timeout      = 2000,
        pool_size    = 10,
        pool_timeout = 10000,
    },

    -- -------------------------------------------------------------------------
    -- Behaviour defaults
    -- -------------------------------------------------------------------------
    defaults = {
        cache_ttl        = 0,
        retry_count      = 2,
        timeout_ms       = 60000,
        log_payloads     = env("AIG_LOG_PAYLOADS", "true") == "true",
        config_cache_ttl = tonumber(env("AIG_CONFIG_CACHE_TTL", "30")),
        byok_cache_ttl   = tonumber(env("AIG_BYOK_CACHE_TTL",   "60")),
    },

    -- -------------------------------------------------------------------------
    -- Provider base URL overrides
    -- -------------------------------------------------------------------------
    provider_base_urls = {
        ollama = env("OLLAMA_BASE_URL", "http://ollama:11434"),
    },

    ollama = { think = false },

    -- -------------------------------------------------------------------------
    -- Encryption key for BYOK secrets at rest
    -- -------------------------------------------------------------------------
    master_key = env("AIG_MASTER_KEY", "dev-insecure-key-change-in-prod-!!"),

}
