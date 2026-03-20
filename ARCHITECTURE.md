# AI Gateway — Architecture & Implementation Strategy

> Nginx + OpenResty (LuaJIT) multi-tenant AI gateway inspired by Cloudflare AI Gateway.

---

## 1. Feature Parity Target

| Feature | Cloudflare | Our Implementation |
|---|---|---|
| Multi-provider routing | ✓ 20+ providers | OpenAI, Anthropic, Gemini, Azure, Bedrock, Mistral, Groq, Cohere, DeepSeek, xAI |
| OpenAI-compatible unified API | ✓ | ✓ `/v1/{tenant}/{gateway}/compat/chat/completions` |
| Exact-match caching | ✓ | Redis SHA-256 keyed cache |
| Semantic caching | roadmap | pgvector / Redis vector similarity |
| Rate limiting | ✓ sliding/fixed window | Redis EVALSHA sliding window |
| Dynamic routing / fallback | ✓ | Rule-engine in Lua + Redis config |
| Model fallbacks & retries | ✓ up to 5 | Configurable retry chain |
| Authenticated gateway | ✓ Bearer token | `x-aig-token` per tenant/gateway |
| BYOK key management | ✓ encrypted | AES-256-GCM in Postgres, per-tenant |
| Observability / logs | ✓ | Structured JSON → ClickHouse / Loki |
| Analytics | ✓ GraphQL | REST + WebSocket metrics endpoint |
| Cost tracking | ✓ per-token pricing | Token counting + price table per model |
| Guardrails / content mod | ✓ | Regex + optional LLM-based classifier |
| DLP / PII scrubbing | ✓ | lua-regex pattern library |
| Streaming (SSE) | ✓ | `ngx.flush` chunked SSE passthrough |
| Custom metadata tagging | ✓ | `x-aig-meta-*` headers stored in log |
| Budget / quota enforcement | ✓ | Redis counters per tenant/model |

---

## 2. Technology Stack

| Layer | Technology | Rationale |
|---|---|---|
| HTTP server | nginx + OpenResty | Already our CDN layer; LuaJIT JIT performance |
| Lua runtime | LuaJIT 2.1 | Fast FFI, co-routines for streaming |
| Hot config / state | Redis 7 (Cluster) | Sub-ms read for rate limits, cache, config |
| Persistent store | PostgreSQL 16 | Tenants, keys, routing rules, budgets |
| Analytics OLAP | ClickHouse | Columnar, handles 10M+ log rows/day |
| Secret encryption | libsodium (via lua-resty-sodium) | AES-256-GCM for BYOK keys at rest |
| Embeddings (semantic cache) | pgvector or Redis vector | Cosine similarity on prompt embeddings |
| Metrics export | Prometheus exposition (`/metrics`) | Scrape into Grafana |
| Tracing | OpenTelemetry OTLP (HTTP) | Trace per request across providers |

---

## 3. Directory Layout

```
src/
  core/
    gateway.lua          -- Main request lifecycle orchestrator
    pipeline.lua         -- Ordered middleware chain execution
    config.lua           -- Per-gateway runtime config loader (Redis + Postgres)
    context.lua          -- Per-request context object (tenant, gateway, provider)
    errors.lua           -- Typed error codes & HTTP responses

  providers/
    init.lua             -- Provider registry
    openai.lua           -- OpenAI + Azure OpenAI adapter
    anthropic.lua        -- Anthropic adapter
    gemini.lua           -- Google Gemini / Vertex AI adapter
    bedrock.lua          -- AWS Bedrock (SigV4 signing)
    mistral.lua          -- Mistral AI adapter
    groq.lua             -- Groq adapter
    cohere.lua           -- Cohere adapter
    deepseek.lua         -- DeepSeek adapter
    xai.lua              -- xAI Grok adapter
    compat.lua           -- OpenAI-compatible unified normalizer

  middleware/
    init.lua             -- Middleware registry & ordering
    request_id.lua       -- Inject x-request-id
    auth.lua             -- Gateway token validation
    tenant.lua           -- Tenant resolution from path/header
    rate_limit.lua       -- Sliding-window rate limiter
    quota.lua            -- Budget / token quota enforcement
    cache_check.lua      -- Cache lookup (exact + semantic)
    dlp.lua              -- DLP / PII detection & scrubbing
    guardrails.lua       -- Content moderation (prompt + response)
    transform.lua        -- Request normalisation to provider format
    retry.lua            -- Retry + fallback orchestration
    cache_store.lua      -- Store response in cache after upstream
    cost.lua             -- Token counting + cost attribution
    log.lua              -- Structured request log emission

  auth/
    tokens.lua           -- Gateway token CRUD (hash + store in Postgres)
    byok.lua             -- BYOK key vault (AES-256-GCM, per-tenant)
    signing.lua          -- AWS SigV4, GCP service account JWT

  cache/
    exact.lua            -- SHA-256 keyed Redis cache
    semantic.lua         -- Vector embedding similarity cache
    key.lua              -- Cache key construction (model + messages + params)

  observability/
    logger.lua           -- Structured JSON log emitter (UDP → Loki/Vector)
    metrics.lua          -- Prometheus counters/histograms (shared dict)
    tracer.lua           -- OTLP HTTP span emitter
    cost_table.lua       -- Model → price per 1K tokens lookup table

  routing/
    engine.lua           -- Rule evaluator (condition → action)
    rules.lua            -- Rule DSL parser (JSON config from Postgres)
    balancer.lua         -- Weighted round-robin across provider keys

  security/
    guardrails.lua       -- Regex + classifier-based content safety
    dlp.lua              -- PII / secrets pattern library
    ip_allowlist.lua     -- Per-tenant IP allowlist check

  billing/
    tracker.lua          -- Increment Redis cost counters
    budget.lua           -- Hard-stop when budget exceeded
    invoice.lua          -- Aggregate daily spend from ClickHouse

  admin/
    api.lua              -- REST admin API (tenant/gateway/key CRUD)
    dashboard.lua        -- Metrics aggregation for UI

  utils/
    http.lua             -- lua-resty-http wrapper
    json.lua             -- cjson wrapper with error handling
    crypto.lua           -- AES-GCM encrypt/decrypt via libsodium
    redis.lua            -- lua-resty-redis connection pool
    postgres.lua         -- pgmoon connection pool
    string.lua           -- Shared string utilities

tests/
  unit/
  integration/
  fixtures/
    requests/            -- Sample provider request/response JSON
    tenants/             -- Test tenant configs
```

---

## 4. Request Lifecycle (nginx phases)

```
[Client]
    │
    ▼  ngx.access phase
┌─────────────────────────────────────────────────────────────┐
│  1. request_id     inject x-request-id (UUID v7)            │
│  2. tenant         resolve tenant+gateway from URL path      │
│  3. auth           validate x-aig-token Bearer              │
│  4. rate_limit     sliding-window check (Redis EVALSHA)      │
│  5. quota          budget hard-stop check                    │
│  6. ip_allowlist   per-tenant CIDR check                     │
└─────────────────────────────────────────────────────────────┘
    │
    ▼  ngx.content phase
┌─────────────────────────────────────────────────────────────┐
│  7. cache_check    exact SHA-256 lookup → return if HIT      │
│  8. dlp            scrub PII from prompt before forwarding   │
│  9. guardrails     block unsafe prompts                      │
│ 10. transform      normalise to provider wire format         │
│ 11. routing        select provider+model (rule engine)       │
│ 12. byok           inject provider API key (decrypted)       │
│ 13. upstream call  lua-resty-http to provider (with retry)   │
│ 14. guardrails     check response safety                     │
│ 15. cache_store    persist to Redis if cacheable             │
│ 16. cost           count tokens, update Redis budget counter │
│ 17. log            emit structured log to ClickHouse/Loki    │
│ 18. metrics        increment Prometheus counters             │
└─────────────────────────────────────────────────────────────┘
    │
    ▼
[Client Response]
```

---

## 5. URL Schema

```
# Provider-native (pass-through with gateway features)
POST /v1/{tenant_id}/{gateway_id}/{provider}/{...provider_path}

# OpenAI-compatible unified endpoint
POST /v1/{tenant_id}/{gateway_id}/compat/chat/completions
POST /v1/{tenant_id}/{gateway_id}/compat/completions
POST /v1/{tenant_id}/{gateway_id}/compat/embeddings

# Admin API (separate vhost / mTLS)
GET  /admin/v1/tenants
POST /admin/v1/tenants
GET  /admin/v1/tenants/{tenant_id}/gateways
POST /admin/v1/tenants/{tenant_id}/gateways
GET  /admin/v1/tenants/{tenant_id}/gateways/{gateway_id}/logs
GET  /admin/v1/tenants/{tenant_id}/gateways/{gateway_id}/analytics
POST /admin/v1/tenants/{tenant_id}/keys          -- BYOK
GET  /metrics                                     -- Prometheus scrape
```

---

## 6. Multi-Tenancy Model

```
Account
  └── Tenant (account_id, plan, budget_limit)
        └── Gateway (gateway_id, config: cache_ttl, rate_limits, routing_rules)
              ├── ProviderConfig (provider, byok_key_alias, model_overrides)
              ├── AuthTokens  (hashed, expiry, scopes)
              └── RoutingRules (priority-ordered conditions → actions)
```

Isolation is enforced by:
- URL-path tenant/gateway prefix (resolved before any upstream call)
- Redis keyspacing: `{tenant}:{gateway}:rl:...`, `{tenant}:{gateway}:cache:...`
- ClickHouse partition key = `tenant_id`
- BYOK keys encrypted per-tenant master key (derived from tenant secret)

---

## 7. Data Schemas

### PostgreSQL

```sql
-- tenants
CREATE TABLE tenants (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug        TEXT UNIQUE NOT NULL,
    plan        TEXT NOT NULL DEFAULT 'free',
    budget_usd  NUMERIC(12,6),
    created_at  TIMESTAMPTZ DEFAULT now()
);

-- gateways
CREATE TABLE gateways (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    UUID REFERENCES tenants(id) ON DELETE CASCADE,
    slug         TEXT NOT NULL,
    config       JSONB NOT NULL DEFAULT '{}',
    created_at   TIMESTAMPTZ DEFAULT now(),
    UNIQUE(tenant_id, slug)
);

-- provider_configs (BYOK)
CREATE TABLE provider_configs (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    gateway_id   UUID REFERENCES gateways(id) ON DELETE CASCADE,
    provider     TEXT NOT NULL,
    alias        TEXT NOT NULL DEFAULT 'default',
    encrypted_key BYTEA NOT NULL,       -- AES-256-GCM ciphertext
    nonce        BYTEA NOT NULL,
    created_at   TIMESTAMPTZ DEFAULT now(),
    UNIQUE(gateway_id, provider, alias)
);

-- auth_tokens
CREATE TABLE auth_tokens (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    gateway_id   UUID REFERENCES gateways(id) ON DELETE CASCADE,
    token_hash   TEXT NOT NULL,        -- SHA-256 of bearer token
    scopes       TEXT[] DEFAULT '{}',
    expires_at   TIMESTAMPTZ,
    created_at   TIMESTAMPTZ DEFAULT now()
);

-- routing_rules
CREATE TABLE routing_rules (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    gateway_id   UUID REFERENCES gateways(id) ON DELETE CASCADE,
    priority     INT NOT NULL DEFAULT 0,
    conditions   JSONB NOT NULL,       -- [{field, op, value}]
    actions      JSONB NOT NULL,       -- {provider, model, fallbacks: [...]}
    enabled      BOOLEAN DEFAULT true
);

-- model_pricing
CREATE TABLE model_pricing (
    provider     TEXT NOT NULL,
    model        TEXT NOT NULL,
    input_per_1k NUMERIC(10,8) NOT NULL,
    output_per_1k NUMERIC(10,8) NOT NULL,
    updated_at   TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY(provider, model)
);
```

### ClickHouse (logs)

```sql
CREATE TABLE gateway_logs (
    request_id      UUID,
    tenant_id       UUID,
    gateway_id      UUID,
    provider        LowCardinality(String),
    model           String,
    status          UInt16,
    cached          Bool,
    input_tokens    UInt32,
    output_tokens   UInt32,
    cost_usd        Float64,
    latency_ms      UInt32,
    ts              DateTime64(3, 'UTC'),
    meta            Map(String, String)
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(ts)
ORDER BY (tenant_id, gateway_id, ts);
```

---

## 8. Key Implementation Details

### Rate Limiting (Redis sliding window EVALSHA)
```lua
-- Atomic sliding window: remove old entries, count, add new, expire
local SCRIPT = [[
  local key = KEYS[1]
  local now = tonumber(ARGV[1])
  local window = tonumber(ARGV[2])
  local limit = tonumber(ARGV[3])
  redis.call('ZREMRANGEBYSCORE', key, 0, now - window)
  local count = redis.call('ZCARD', key)
  if count >= limit then return 0 end
  redis.call('ZADD', key, now, now .. math.random())
  redis.call('EXPIRE', key, window)
  return 1
]]
```

### Streaming (SSE passthrough)
```lua
-- In content handler, after upstream connect:
ngx.header['Content-Type'] = 'text/event-stream'
ngx.header['Cache-Control'] = 'no-cache'
local res, err = httpc:request({...})
-- Chunked read loop:
while true do
  local chunk, err = res.body_reader(8192)
  if not chunk then break end
  ngx.print(chunk)
  ngx.flush(true)
  -- Intercept token counts from SSE data: lines
end
```

### BYOK Encryption (libsodium AES-256-GCM)
```lua
-- Encrypt on store:
local nonce = sodium.randombytes(24)
local ct = sodium.crypto_aead_xchacha20poly1305_ietf_encrypt(
    plaintext, nil, nonce, tenant_master_key)

-- Decrypt on use (in hot path, cache decrypted key in shared dict TTL=60s):
local cached = ngx.shared.byok_cache:get(key_id)
if not cached then
    cached = decrypt(row.encrypted_key, row.nonce, master_key)
    ngx.shared.byok_cache:set(key_id, cached, 60)
end
```

### Cost Attribution
```lua
-- Token counting from provider response (or streaming accumulation):
local input_tokens  = res.usage.prompt_tokens     or 0
local output_tokens = res.usage.completion_tokens or 0
local pricing = cost_table.get(provider, model)
local cost = (input_tokens / 1000 * pricing.input_per_1k)
           + (output_tokens / 1000 * pricing.output_per_1k)
-- Atomic increment budget counter:
redis.incrbyfloat("budget:" .. tenant_id, cost)
```

---

## 9. nginx Config Skeleton

```nginx
# /etc/nginx/conf.d/ai-gateway.conf
lua_package_path '/opt/ai-gateway/src/?.lua;;';
lua_shared_dict  byok_cache    10m;
lua_shared_dict  config_cache  20m;
lua_shared_dict  metrics       5m;
lua_shared_dict  rate_limit    50m;

init_by_lua_block {
    require("core.config").init()
    require("observability.metrics").init()
}

init_worker_by_lua_block {
    require("core.config").start_refresh_timer()
}

server {
    listen 443 ssl http2;
    server_name gateway.example.com;

    location ~ ^/v1/([^/]+)/([^/]+)/(.+)$ {
        set $tenant_id  $1;
        set $gateway_id $2;
        set $remainder  $3;

        access_by_lua_block  { require("core.gateway").access()  }
        content_by_lua_block { require("core.gateway").content() }
        log_by_lua_block     { require("core.gateway").log()     }
    }

    location /metrics {
        allow 10.0.0.0/8;
        deny  all;
        content_by_lua_block { require("admin.dashboard").metrics() }
    }
}
```

---

## 10. Implementation Phases

### Phase 1 — Core Plumbing (MVP)
- [ ] `core/context.lua` — request context object
- [ ] `core/pipeline.lua` — middleware chain
- [ ] `core/gateway.lua` — access/content/log hooks
- [ ] `providers/openai.lua` + `providers/compat.lua`
- [ ] `middleware/tenant.lua` + `middleware/auth.lua`
- [ ] `utils/redis.lua` + `utils/postgres.lua` + `utils/http.lua`
- [ ] nginx config skeleton
- [ ] Integration test: proxied OpenAI call end-to-end

### Phase 2 — Performance Layer
- [ ] `cache/exact.lua` — Redis SHA-256 cache
- [ ] `middleware/rate_limit.lua` — sliding window
- [ ] `middleware/quota.lua` — budget hard-stop
- [ ] `middleware/retry.lua` — retry + provider fallback
- [ ] `observability/metrics.lua` — Prometheus shared dict

### Phase 3 — Observability
- [ ] `observability/logger.lua` — ClickHouse/Loki emit
- [ ] `observability/tracer.lua` — OTLP spans
- [ ] `observability/cost_table.lua` — pricing table
- [ ] `billing/tracker.lua` + `billing/budget.lua`
- [ ] `middleware/cost.lua` — token counting

### Phase 4 — Security Layer
- [ ] `auth/byok.lua` — AES-256-GCM key vault
- [ ] `auth/tokens.lua` — bearer token CRUD
- [ ] `security/dlp.lua` — PII pattern library
- [ ] `security/guardrails.lua` — content safety
- [ ] `middleware/dlp.lua` + `middleware/guardrails.lua`

### Phase 5 — Routing & Multi-Provider
- [ ] Remaining provider adapters (Anthropic, Gemini, Bedrock, etc.)
- [ ] `routing/engine.lua` — rule evaluator
- [ ] `routing/rules.lua` — DSL parser
- [ ] `routing/balancer.lua` — weighted round-robin
- [ ] `providers/bedrock.lua` — AWS SigV4 signing

### Phase 6 — Admin API & Semantic Cache
- [ ] `admin/api.lua` — REST CRUD
- [ ] `cache/semantic.lua` — vector similarity
- [ ] `billing/invoice.lua` — spend aggregation
- [ ] Dashboard endpoint + WebSocket metrics stream

---

## 11. Testing Strategy

- **Unit tests**: `busted` framework, each module tested in isolation with mocked Redis/Postgres
- **Integration tests**: Docker Compose (nginx+OpenResty, Redis, Postgres, ClickHouse, mock provider)
- **Load tests**: k6 with 1k concurrent connections, assert p99 < 10ms overhead vs direct provider
- **Security tests**: OWASP ZAP scan on admin API; fuzz DLP patterns; test token isolation across tenants

```
tests/
  unit/
    test_cache_key.lua
    test_rate_limit.lua
    test_cost.lua
    test_dlp.lua
    test_routing_engine.lua
    test_provider_compat.lua
  integration/
    test_openai_proxy.lua
    test_caching.lua
    test_auth.lua
    test_streaming.lua
    test_fallback.lua
  fixtures/
    requests/openai_chat.json
    requests/anthropic_messages.json
    tenants/test_tenant.json
```
