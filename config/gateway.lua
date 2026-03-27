-- config/gateway.lua — AI Gateway runtime configuration
--
-- storage: "sqlite" | "postgres" | "mysql"
-- state:   "shared_dict" | "redis"
--
-- Bootstrap admin: set AIG_BOOTSTRAP_ADMIN_EMAIL to auto-create the first
-- admin user on startup. Subsequent starts are no-ops if an admin exists.
--   AIG_BOOTSTRAP_ADMIN_EMAIL=admin@example.com
--   AIG_BOOTSTRAP_ADMIN_NAME=Admin  (optional)

local _cfg_dir = debug.getinfo(1,"S").source:sub(2):match("^(.*/)") or "./"
local _data_dir = os.getenv("AIG_DATA_DIR") or (_cfg_dir .. "../data")

return {

    -- -------------------------------------------------------------------------
    -- Admin authentication (JWT + Google SSO + Email OTP)
    -- -------------------------------------------------------------------------
    auth = {
        -- HS256 secret — MUST be changed in production.
        jwt_secret           = os.getenv("AIG_JWT_SECRET") or "dev-change-me",
        -- Session lifetime in seconds (default 8 h).
        jwt_expiry_secs      = tonumber(os.getenv("AIG_JWT_EXPIRY_SECS")) or 28800,
        -- Google OAuth 2.0 credentials (optional; leave nil to disable Google SSO).
        google_client_id     = os.getenv("AIG_GOOGLE_CLIENT_ID"),
        google_client_secret = os.getenv("AIG_GOOGLE_CLIENT_SECRET"),
        google_redirect_uri  = os.getenv("AIG_GOOGLE_REDIRECT_URI")
                               or "http://localhost:8081/admin/auth/google/callback",
        -- From-address used in OTP emails.
        otp_from_email       = os.getenv("AIG_OTP_FROM_EMAIL") or "noreply@localhost",
        -- OTP code lifetime in seconds (default 15 min).
        otp_expiry_secs      = tonumber(os.getenv("AIG_OTP_EXPIRY_SECS")) or 900,
    },

    -- -------------------------------------------------------------------------
    -- Storage backend (persistent: tenants, gateways, keys, tokens, rules)
    -- -------------------------------------------------------------------------
    storage = os.getenv("AIG_STORAGE") or "sqlite",

    sqlite = {
        config_db = _data_dir .. "/config.db",
        logs_db   = _data_dir .. "/logs.db",
    },

    postgres = {
        host     = "127.0.0.1",
        port     = 5432,
        database = "ai_gateway",
        user     = "gateway",
        password = "",
        pool_size    = 50,
        pool_timeout = 10000,
    },

    mysql = {
        host         = os.getenv("AIG_MYSQL_HOST") or "127.0.0.1",
        port         = tonumber(os.getenv("AIG_MYSQL_PORT")) or 3306,
        database     = os.getenv("AIG_MYSQL_DB")   or "gateway_dev",
        user         = os.getenv("AIG_MYSQL_USER")  or "gateway",
        password     = os.getenv("AIG_MYSQL_PASS")  or "gateway",
        pool_size    = 200,
        pool_timeout = 10000,
    },

    -- -------------------------------------------------------------------------
    -- State backend (ephemeral hot state: cache, rate limits, counters)
    -- -------------------------------------------------------------------------
    state = "shared_dict",

    shared_dict = {
        cache      = "aig_cache",       -- exact-match response cache
        rate_limit = "aig_ratelimit",   -- rate limit sliding windows
        config     = "aig_config",      -- hot gateway config cache
        byok       = "aig_byok",        -- decrypted provider keys (short TTL)
        metrics    = "aig_metrics",     -- prometheus counters
    },

    redis = {
        host     = "127.0.0.1",
        port     = 6379,
        auth     = nil,
        timeout  = 2000,
        pool_size    = 100,
        pool_timeout = 10000,
    },

    -- -------------------------------------------------------------------------
    -- Gateway behaviour defaults (overridable per gateway in DB)
    -- -------------------------------------------------------------------------
    defaults = {
        cache_ttl      = 0,       -- seconds; 0 = disabled
        retry_count    = 2,
        timeout_ms     = 60000,
        log_payloads   = true,    -- store prompt+response bodies in logs
        config_cache_ttl = 30,    -- seconds to cache gateway config in state
        byok_cache_ttl   = 60,    -- seconds to cache decrypted provider keys
    },

    -- -------------------------------------------------------------------------
    -- Provider base URL overrides (optional; use when providers aren't on
    -- their default ports or are hosted on remote machines)
    -- -------------------------------------------------------------------------
    provider_base_urls = {
        ollama = os.getenv("OLLAMA_BASE_URL") or "http://10.232.10.252:11439",
    },

    -- Ollama provider options
    ollama = {
        -- Disable the reasoning/analysis channel so models like gpt-oss route
        -- their answer to delta.content instead of delta.reasoning.
        -- Override per-gateway via gateway_config.ollama.think = true.
        think = false,
    },

    -- -------------------------------------------------------------------------
    -- Encryption key for BYOK secrets at rest (AES-256-GCM via OpenSSL)
    -- In production: load from environment variable or KMS, never hardcode.
    -- -------------------------------------------------------------------------
    master_key = os.getenv("AIG_MASTER_KEY") or "dev-insecure-key-change-in-prod-!!",

}
