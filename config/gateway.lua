-- config/gateway.lua — AI Gateway runtime configuration
--
-- storage: "sqlite" | "postgres"
-- state:   "shared_dict" | "redis"
--
-- AIG_DATA_DIR env var sets the SQLite data directory.
-- Defaults to the directory containing this config file.

local _cfg_dir = debug.getinfo(1,"S").source:sub(2):match("^(.*/)") or "./"
local _data_dir = os.getenv("AIG_DATA_DIR") or (_cfg_dir .. "../data")

return {

    -- -------------------------------------------------------------------------
    -- Storage backend (persistent: tenants, gateways, keys, tokens, rules)
    -- -------------------------------------------------------------------------
    storage = "sqlite",

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
    -- Encryption key for BYOK secrets at rest (AES-256-GCM via OpenSSL)
    -- In production: load from environment variable or KMS, never hardcode.
    -- -------------------------------------------------------------------------
    master_key = os.getenv("AIG_MASTER_KEY") or "dev-insecure-key-change-in-prod-!!",

}
