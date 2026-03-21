# AI Gateway — Architecture

> Nginx + OpenResty (LuaJIT) multi-tenant AI gateway.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Technology Stack](#2-technology-stack)
3. [Directory Layout](#3-directory-layout)
4. [Request Lifecycle](#4-request-lifecycle)
5. [URL Schema](#5-url-schema)
6. [Multi-Tenancy Model](#6-multi-tenancy-model)
7. [Storage & State](#7-storage--state)
8. [Provider Abstraction](#8-provider-abstraction)
9. [Routing Engine](#9-routing-engine)
10. [Security Subsystems](#10-security-subsystems)
11. [Observability](#11-observability)
12. [nginx Configuration](#12-nginx-configuration)
13. [Deployment Topology](#13-deployment-topology)

---

## 1. Overview

The gateway sits between API consumers and upstream AI providers. Every request passes through an ordered middleware chain that handles authentication, policy enforcement, caching, routing, and observability — all in-process within nginx, with no external sidecar.

```
Consumer
   │  POST /v1/{tenant}/{gateway}/{provider}/chat/completions
   ▼
┌──────────────────────────────────────────┐
│              nginx / OpenResty           │
│  ┌────────────────────────────────────┐  │
│  │     Access phase middleware        │  │
│  │  auth · rate-limit · IP allowlist  │  │
│  ├────────────────────────────────────┤  │
│  │     Content phase middleware       │  │
│  │  cache · DLP · guardrails ·        │  │
│  │  routing · BYOK · upstream ·       │  │
│  │  cost · cache-store                │  │
│  ├────────────────────────────────────┤  │
│  │     Log phase (best-effort)        │  │
│  │  structured log · Prometheus       │  │
│  └────────────────────────────────────┘  │
└──────────────────────────────────────────┘
          │                    │
   ┌──────┴──────┐      ┌──────┴──────┐
   │  SQLite DB  │      │  Upstream   │
   │ config.db   │      │  Providers  │
   │  logs.db    │      │ (OpenAI,    │
   └─────────────┘      │  Anthropic, │
                        │  Gemini…)   │
                        └─────────────┘
```

**Design principles:**
- All policy logic runs in LuaJIT inside the nginx worker — zero extra network hops for auth, rate limiting, or caching on a single-server deployment.
- `ngx.shared.dict` provides shared memory across workers for rate-limit state, config cache, and Prometheus counters.
- The middleware chain is linear and ordered; each step either short-circuits (cache hit, block) or enriches a per-request context object passed to the next step.

---

## 2. Technology Stack

| Layer | Technology | Notes |
|---|---|---|
| HTTP server | nginx + OpenResty (LuaJIT 2.1) | JIT-compiled Lua, co-routines for streaming |
| Config & persistent state | SQLite (dev) / PostgreSQL (prod) | Gateway config, tokens, routing rules, pricing |
| Request logs | SQLite `logs.db` (dev) / ClickHouse or Loki (prod) | Structured JSON per request |
| Hot state | `ngx.shared.dict` (single-server) / Redis (distributed) | Rate limits, config cache, Prometheus counters, BYOK cache |
| Encryption | AES-256-CBC + PKCS7 via OpenSSL | BYOK provider keys at rest (`AIG_MASTER_KEY` env var) |
| Content moderation | Llama Guard 3 (HTTP service) | Optional; fail-open by default |
| Frontend | React 19 + TypeScript + Vite | Admin UI at `frontend/` |
| Metrics | Prometheus exposition (`/metrics`) | Counters scraped into Grafana |

---

## 3. Directory Layout

```
src/
  core/
    gateway.lua          # Nginx phase hooks: access(), content(), log()
    context.lua          # Per-request context object (tenant, gateway, provider, tokens…)

  providers/
    init.lua             # Provider registry — maps provider name → module
    openai.lua           # OpenAI + Azure OpenAI (native format)
    anthropic.lua        # Anthropic Messages API adapter
    gemini.lua           # Google Gemini (GenerateContent) adapter
    mistral.lua          # Mistral AI (OpenAI-compatible)
    groq.lua             # Groq (OpenAI-compatible)

  middleware/
    auth.lua             # Bearer / x-aig-token / x-api-key validation
    cache_check.lua      # SHA-256 exact-match cache lookup
    cache_store.lua      # Persist non-streaming 200 responses to cache
    cost.lua             # Token counting + budget counter increment
    guardrails_request.lua  # Llama Guard 3 prompt classification
    quota.lua            # Budget hard-stop enforcement
    upstream.lua         # Provider HTTP call with retry + fallback chain

  observability/
    logger.lua           # Structured JSON log writer
    cost_table.lua       # Model → price per 1K tokens lookup table

  routing/
    engine.lua           # Rule evaluator (condition → action)

  security/
    dlp.lua              # PII / secrets pattern library (block/scrub/flag)
    guardrails.lua       # Response-side pattern check + Llama Guard wrapper
    ip_allowlist.lua     # Per-gateway CIDR allowlist check

  billing/
    tracker.lua          # Budget counter logic

  auth/
    byok.lua             # Provider key encryption/decryption (AES-256-CBC)

  admin/
    api.lua              # REST admin API (tenant/gateway/user/token CRUD)

  storage/
    sqlite.lua           # SQLite connection wrapper + all DB queries
    schema_config.sql    # Config DB schema (tenants, gateways, tokens, rules…)
    schema_logs.sql      # Logs DB schema (request_logs)

  state/
    init.lua             # State backend abstraction (shared_dict ↔ Redis)

  utils/                 # Shared helpers (HTTP, JSON, crypto, string)

config/
  gateway.lua            # Runtime config: DB paths, master key, defaults
  nginx.conf             # nginx server blocks and lua_shared_dict declarations

frontend/                # React + TypeScript admin UI (Vite build)
tests/
  unit/                  # busted unit tests per module
  integration/           # End-to-end tests against running gateway
  fixtures/              # Sample provider request/response JSON
```

---

## 4. Request Lifecycle

### Phase diagram

```
[Consumer]
    │
    ▼  ── ngx.access phase ─────────────────────────────────────
    │
    ├─ 1. request_id     Generate or forward X-Request-Id (UUID)
    ├─ 2. tenant         Resolve {tenant_slug}/{gateway_slug} → UUIDs; load gateway config
    ├─ 3. auth           Validate token (x-aig-token / Bearer / x-api-key)
    │                    Enforce role (viewer → 403); load per-token rate/budget overrides
    ├─ 4. rate_limit     Sliding-window check (dual-bucket approx in shared_dict)
    ├─ 5. ip_allowlist   CIDR match against gateway config allowlist
    │
    ▼  ── ngx.content phase ────────────────────────────────────
    │
    ├─ 6.  cache_check      SHA-256(provider:model:canonical_body) → serve if HIT
    ├─ 7.  dlp              Scan prompt; block / scrub / flag PII patterns
    ├─ 8.  guardrails_req   Call Llama Guard 3; block if unsafe (S1–S14)
    ├─ 9.  transform        Parse + normalize body; collect x-aig-meta-* headers
    ├─ 10. routing          Evaluate ordered routing rules → provider, model, fallbacks
    ├─ 11. byok             Decrypt provider API key (cache 60 s in aig_byok dict)
    ├─ 12. upstream         HTTP call to provider; retry on 5xx; walk fallback chain
    ├─ 13. guardrails_resp  Pattern-check response body (non-streaming only)
    ├─ 14. cost             Count tokens; compute cost_usd; increment budget counter
    ├─ 15. cache_store      Persist response to cache (non-streaming, status 200)
    │
    ▼  ── ngx.log phase (best-effort, after response sent) ─────
    │
    ├─ 16. logger           Write structured JSON to logs.db
    └─ 17. metrics          Increment Prometheus counters in aig_metrics shared dict

[Consumer Response]
```

### Context object

Each request carries a `ctx` table populated incrementally by middleware:

```lua
ctx = {
  request_id       = "...",
  tenant_id        = "...",   gateway_id = "...",
  provider         = "openai", model = "gpt-4o",
  auth_token       = { id, label, user_id, budget_usd, rate_limit },
  gateway_config   = { cache_ttl, rate_limit, dlp, guardrails, … },
  body             = { … },   -- parsed request JSON
  meta             = { … },   -- x-aig-meta-* headers
  -- populated after upstream:
  status           = 200,
  response_body    = "…",
  input_tokens     = 512,   output_tokens = 128,
  cost_usd         = 0.004,
  latency_ms       = 340,   upstream_latency_ms = 310,
  cached           = false,
  blocked          = false, blocked_by = nil,
}
```

---

## 5. URL Schema

```
# Provider-native endpoint
POST /v1/{tenant_slug}/{gateway_slug}/{provider}/chat/completions

# OpenAI-compatible unified endpoint (provider inferred from model name prefix)
POST /v1/{tenant_slug}/{gateway_slug}/compat/chat/completions

# Admin API
GET  /admin/v1/tenants
POST /admin/v1/tenants
GET  /admin/v1/tenants/{id}/gateways
POST /admin/v1/tenants/{id}/gateways
GET  /admin/v1/gateways/{id}
PATCH  /admin/v1/gateways/{id}
DELETE /admin/v1/gateways/{id}/budget
POST /admin/v1/gateways/{id}/keys          # BYOK key storage
GET  /admin/v1/gateways/{id}/tokens
POST /admin/v1/gateways/{id}/tokens
DELETE /admin/v1/gateways/{id}/tokens/{tid}
GET  /admin/v1/tenants/{id}/users
POST /admin/v1/tenants/{id}/users
PATCH  /admin/v1/users/{id}
DELETE /admin/v1/users/{id}
POST /admin/v1/users/{id}/tokens
GET  /admin/v1/users/{id}/tokens
POST /admin/v1/users/{id}/gateways/{gw_id}   # grant access
DELETE /admin/v1/users/{id}/gateways/{gw_id} # revoke access
GET  /admin/v1/stats
GET  /admin/v1/logs

# Observability
GET  /metrics     # Prometheus text format (IP-restricted to 10.0.0.0/8)
```

---

## 6. Multi-Tenancy Model

```
Tenant  (id, slug, plan, budget_limit, deleted_at)
  │
  ├── Gateway  (id, slug, config JSONB)
  │     ├── ProviderConfig  (provider, alias, encrypted_key)   ← BYOK
  │     ├── AuthToken       (token_hash, expiry, label, rate_limit, budget_usd, user_id)
  │     └── RoutingRule     (priority, conditions JSONB, actions JSONB, enabled)
  │
  └── User  (id, email, role: admin|member|viewer)
        └── UserGatewayAccess  (user_id, gateway_id)
```

**Isolation mechanisms:**

| Boundary | Mechanism |
|---|---|
| URL routing | `{tenant_slug}/{gateway_slug}` prefix resolved at access phase |
| shared_dict keys | Namespaced: `{tenant_id}:{gateway_id}:rl:…`, `…:cache:…` |
| Database | `tenant_id` foreign keys on all tables; queries always filter by tenant |
| BYOK keys | Encrypted with a key derived from `AIG_MASTER_KEY` (global; per-tenant derivation is a planned upgrade) |
| Auth tokens | Scoped to a single gateway; cross-gateway use is rejected |

---

## 7. Storage & State

### Config database (SQLite / PostgreSQL)

Stores durable configuration that changes infrequently: tenants, gateways, tokens, routing rules, provider keys, pricing.

Gateway config is loaded from the DB and cached in `aig_config` shared dict for `config_cache_ttl` seconds (default: 30 s) to avoid per-request DB reads.

**Key tables:**

| Table | Contents |
|---|---|
| `tenants` | id, slug, plan, budget_limit |
| `gateways` | id, tenant_id, slug, config (JSON) |
| `gateway_provider_configs` | gateway_id, provider, alias, encrypted_key |
| `auth_tokens` | gateway_id, token_hash, label, expiry, rate_limit, budget_usd, user_id |
| `routing_rules` | gateway_id, priority, conditions (JSON), actions (JSON), enabled |
| `users` | id, tenant_id, email, role |
| `user_gateway_access` | user_id, gateway_id |
| `model_price` | provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k |

### Log database (SQLite / ClickHouse)

One row per request. In development: `logs.db` via `storage/sqlite.lua`. In production: swap for UDP → Vector/Loki or HTTP → ClickHouse.

**Key fields:** `request_id`, `tenant_id`, `gateway_id`, `provider`, `model`, `status`, `cached`, `input_tokens`, `output_tokens`, `cost_usd`, `latency_ms`, `upstream_latency_ms`, `time_to_first_token_ms`, `blocked`, `blocked_by`, `prompt`, `response`, `meta`

### Shared memory (`ngx.shared.dict`)

| Dict | Size | Contents |
|---|---|---|
| `aig_cache` | 10 MB | Exact-match response cache |
| `aig_ratelimit` | 50 MB | Sliding-window rate-limit buckets |
| `aig_config` | 20 MB | Gateway config + routing rules |
| `aig_byok` | 10 MB | Decrypted provider keys (TTL 60 s) |
| `aig_metrics` | 5 MB | Prometheus counters |

### Redis (distributed deployments)

Replaces `ngx.shared.dict` for multi-server setups. Architecture is backend-agnostic via `state/init.lua`. Rate limiting uses an atomic EVALSHA sliding-window script in the Redis path.

---

## 8. Provider Abstraction

Each provider module exposes a common interface:

```lua
provider.build_request(ctx)          -- returns headers, body for upstream call
provider.parse_response(ctx, body)   -- extracts tokens, normalizes response
provider.parse_sse_chunk(ctx, line)  -- streaming: accumulate tokens per SSE line
```

**Provider → wire format mapping:**

| Provider | Format | Notes |
|---|---|---|
| OpenAI | Native | Direct pass-through |
| Azure OpenAI | OpenAI | Requires `azure_endpoint` + `azure_api_version` |
| Anthropic | Messages API | Role/content conversion; extended thinking support |
| Gemini | GenerateContent | System instruction conversion |
| Mistral | OpenAI-compatible | |
| Groq | OpenAI-compatible | |

The **compat endpoint** (`/compat/chat/completions`) accepts OpenAI-format requests and infers the provider from the model name prefix (e.g., `claude-` → Anthropic, `gemini-` → Gemini), then delegates to the appropriate provider module.

### Streaming

SSE responses are passed through chunk-by-chunk with `ngx.flush(true)` after each write. Token counts are accumulated by `parse_sse_chunk()` as chunks arrive, so cost attribution works without buffering the full response.

---

## 9. Routing Engine

Rules are loaded from the DB, cached for 30 s, and evaluated in ascending `priority` order. The first matching rule wins.

```
Rule
 ├── conditions: [{field, op, value}, …]   -- ALL must match (AND)
 └── actions:
       provider:   "anthropic"
       model:      "claude-sonnet-4-6"
       fallbacks:  [{provider, model}, …]
```

**Condition fields:** `model`, `provider`, `tenant_id`, `header:{name}`, `meta:{key}`

**Operators:** `eq`, `neq`, `prefix`, `contains`, `regex`

### Fallback chain

```
upstream.lua attempts:
  1. Primary provider — up to retry_count attempts (default 2) on 5xx
  2. fallbacks[1]     — 1 attempt
  3. fallbacks[2]     — 1 attempt
  …
  → 502 ALL_PROVIDERS_FAILED if all exhausted

4xx from any provider → return immediately to client (no retry)
```

BYOK keys are re-fetched and decrypted each time the active provider changes during the fallback walk. `fallback_provider` and `fallback_model` are recorded in the request log.

---

## 10. Security Subsystems

### Authentication

Token accepted from (in priority order): `x-aig-token` → `Authorization: Bearer` → `x-api-key`.

SHA-256 hash stored in DB; plaintext never persisted. Token carries optional per-token `rate_limit` and `budget_usd` overrides that take precedence over gateway-level config.

### BYOK key vault

```
Store:   AES-256-CBC encrypt(api_key, IV=random_16B, key=SHA256(AIG_MASTER_KEY))
         → store as base64(IV):base64(ciphertext) in provider_configs table

Retrieve: decrypt on first use → cache plaintext in aig_byok shared dict for 60 s
          → inject as Authorization header on upstream call
```

### Rate limiting

Dual-bucket sliding window in `aig_ratelimit` shared dict:

```
weight = 1 - (time_into_current_window / window_sec)
effective_count = prev_bucket * weight + cur_bucket
```

### Budget enforcement

Costs stored as micro-dollars (`cost * 1e6`) in the state backend. Checked pre-request against both per-token and per-gateway caps. Incremented atomically after the upstream response.

### DLP

Lua pattern scan on the serialized request body. Configurable per gateway:
- `block` — reject with 400
- `scrub` — replace match with `[REDACTED]`, forward sanitized body
- `flag` — log only, forward unchanged

### Guardrails

**Request:** Last user message sent to Llama Guard 3 HTTP service. Blocked categories S1–S14 returned as a synthetic 200 in the correct wire format (JSON or SSE depending on `stream`).

**Response:** Regex patterns for `self_harm` and `violence` checked on the buffered response body (non-streaming only).

### IP allowlist

CIDR-based allow list per gateway. Matching uses 32-bit integer masking via LuaJIT `bit` library. Empty list = allow all.

---

## 11. Observability

### Structured request log

Written at the log phase after every request. Schema lives in `storage/schema_logs.sql`. Fields:

```
request_id, tenant_id, gateway_id, user_id, token_label,
provider, model, fallback_provider, fallback_model, upstream_attempts,
status, blocked, blocked_by, block_reason,
cached, saved_cost_usd, saved_latency_ms,
input_tokens, output_tokens, cache_creation_tokens, cache_read_tokens,
cost_usd,
latency_ms, upstream_latency_ms, time_to_first_token_ms,
prompt, response,
meta (JSON map of x-aig-meta-* headers)
```

Payload logging can be disabled globally (`log_payloads: false` in gateway config) or per-request (`x-aig-collect-log-payload: false` header).

### Prometheus metrics

Exposed at `GET /metrics`. Four metrics, all with labels `{provider, tenant_id, status, cached}`:

| Metric | Type |
|---|---|
| `aig_requests_total` | Counter |
| `aig_latency_ms` (count + sum) | Histogram approximation |
| `aig_input_tokens_total` | Counter |
| `aig_output_tokens_total` | Counter |

### Cost attribution

`src/observability/cost_table.lua` maps `(provider, model)` → `{input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k}`. The DB `model_price` table overrides the hardcoded defaults. Anthropic prompt-caching token types are tracked separately.

---

## 12. nginx Configuration

```nginx
lua_package_path '/opt/ai-gateway/src/?.lua;;';

lua_shared_dict  aig_cache      10m;
lua_shared_dict  aig_ratelimit  50m;
lua_shared_dict  aig_config     20m;
lua_shared_dict  aig_byok       10m;
lua_shared_dict  aig_metrics    5m;

init_by_lua_block {
    require("core.gateway").init()
}

server {
    listen 443 ssl http2;

    location ~ ^/v1/([^/]+)/([^/]+)/(.+)$ {
        access_by_lua_block  { require("core.gateway").access()  }
        content_by_lua_block { require("core.gateway").content() }
        log_by_lua_block     { require("core.gateway").log()     }
    }

    location /admin/ {
        content_by_lua_block { require("admin.api").handle() }
    }

    location /metrics {
        allow 10.0.0.0/8;
        deny  all;
        content_by_lua_block { require("observability.metrics").exposition() }
    }
}
```

Temporary directories created by nginx (`client_body_temp/`, `fastcgi_temp/`, `proxy_temp/`, `scgi_temp/`, `uwsgi_temp/`) are excluded from version control via `.gitignore`.

---

## 13. Deployment Topology

### Single-server (current default)

```
┌──────────────────────────────────┐
│  nginx/OpenResty process         │
│  ┌──────────┐  ┌──────────────┐  │
│  │ worker 1 │  │   worker 2   │  │
│  └────┬─────┘  └──────┬───────┘  │
│       └────────┬───────┘         │
│           ngx.shared.dict        │
│       (rate-limit, cache, …)     │
└──────────────┬───────────────────┘
               │
     ┌─────────┴─────────┐
     │     SQLite         │
     │  config.db         │
     │  logs.db           │
     └────────────────────┘
```

State is shared across workers via `ngx.shared.dict`. No external processes required for a functional single-server deployment.

### Distributed (production path)

```
                    ┌─────────────┐
                    │  Load       │
                    │  Balancer   │
                    └──────┬──────┘
              ┌────────────┼────────────┐
              ▼            ▼            ▼
         [GW node 1]  [GW node 2]  [GW node 3]
              │            │            │
         ┌────┴────────────┴────────────┴────┐
         │               Redis               │
         │  (rate-limit, cache, BYOK cache)   │
         └───────────────────────────────────┘
              │
         ┌────┴──────────┐
         │  PostgreSQL   │  ← config DB
         └───────────────┘
              │
         ┌────┴──────────┐
         │  ClickHouse   │  ← request logs
         └───────────────┘
```

The state backend abstraction in `state/init.lua` switches from `ngx.shared.dict` to Redis by changing a single config flag. All rate-limit keys and cache entries are already namespaced for multi-node use.
