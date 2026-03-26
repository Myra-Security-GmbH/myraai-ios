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
11. [Detector Pipeline](#11-detector-pipeline)
12. [Observability](#12-observability)
13. [Admin UI (Frontend)](#13-admin-ui-frontend)
14. [nginx Configuration](#14-nginx-configuration)
15. [Deployment Topology](#15-deployment-topology)

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
│  │  auth · rate-limit · quota ·       │  │
│  │  IP allowlist                      │  │
│  ├────────────────────────────────────┤  │
│  │     Content phase middleware       │  │
│  │  cache · detectors · routing ·     │  │
│  │  BYOK · upstream ·                 │  │
│  │  cost · cache-store                │  │
│  ├────────────────────────────────────┤  │
│  │     Log phase (best-effort)        │  │
│  │  structured log · SIEM · OTel ·   │  │
│  │  Prometheus                        │  │
│  └────────────────────────────────────┘  │
└──────────────────────────────────────────┘
          │                    │
   ┌──────┴──────┐      ┌──────┴──────┐
   │  SQLite DB  │      │  Upstream   │
   │ config.db   │      │  Providers  │
   │  logs.db    │      │ (21 total)  │
   └─────────────┘      └─────────────┘
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
| AWS auth | SigV4 signing (`src/utils/sigv4.lua`) | Used by Bedrock provider |
| Content moderation | Llama Guard 3 (HTTP service) | Optional; fail-open by default |
| PII detection | Presidio (HTTP sidecar) | Optional Tier 2 detector |
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
    compat.lua           # OpenAI-compat unified endpoint; model→provider inference
    openai.lua           # OpenAI (native format)
    anthropic.lua        # Anthropic Messages API adapter
    gemini.lua           # Google Gemini (GenerateContent) adapter
    azure.lua            # Azure OpenAI (API key header, deployment routing)
    bedrock.lua          # AWS Bedrock (SigV4 auth, InvokeModel API)
    vertex.lua           # Google Vertex AI (x-goog-api-key, project config)
    mistral.lua          # Mistral AI (OpenAI-compatible)
    groq.lua             # Groq (OpenAI-compatible)
    together.lua         # Together AI (OpenAI-compatible)
    fireworks.lua        # Fireworks AI (OpenAI-compatible)
    cerebras.lua         # Cerebras (OpenAI-compatible)
    deepseek.lua         # DeepSeek (OpenAI-compatible)
    openrouter.lua       # OpenRouter (OpenAI-compatible; 300+ models)
    perplexity.lua       # Perplexity (OpenAI-compatible)
    sambanova.lua        # SambaNova (OpenAI-compatible)
    xai.lua              # xAI / Grok (OpenAI-compatible)
    nvidia.lua           # NVIDIA NIM (OpenAI-compatible)
    cloudflare.lua       # Cloudflare Workers AI (@cf/ model prefix)
    cohere.lua           # Cohere v2 Chat API (native format)
    huggingface.lua      # HuggingFace Inference API (org/model routing)
    ollama.lua           # Ollama local server (OpenAI-compatible)

  cache/
    semantic.lua         # Vector-similarity cache: embed prompt → cosine search → serve hit
                         # Store path is async (ngx.timer.at); query path is synchronous

  middleware/
    auth.lua             # Bearer / x-aig-token / x-api-key validation
    cache_check.lua      # SHA-256 exact-match lookup; semantic cache fallback
    cache_store.lua      # Persist non-streaming 200 responses; async semantic embedding store
    cost.lua             # Token counting + budget counter increment
    guardrails.lua       # Request-phase guardrail pipeline entry point
    guardrails_response.lua  # Response-phase guardrail pipeline entry point
    quota.lua            # Budget hard-stop enforcement
    request_id.lua       # Generate/forward X-Request-Id; init OTel trace context
    upstream.lua         # Provider HTTP call with retry + fallback chain; inject traceparent

  guardrails/
    orchestrator.lua     # Tier 1 → Tier 2 sequencing, action merging
    regex.lua            # Tier 1: in-process regex patterns (block/scrub/flag)
    keyword.lua          # Tier 1: exact keyword matching
    jailbreak.lua        # Tier 1: zero-config jailbreak phrase detection
    json_schema.lua      # Tier 1: JSON schema validation for structured-output responses
    contains_code.lua    # Tier 1: source-code detection (fence + heuristic, 6 languages)
    gibberish.lua        # Tier 1: low-quality response detection (entropy/repetition/alpha signals)
    language.lua         # Tier 1: writing-system detection via UTF-8 byte-range heuristics
    presidio.lua         # Tier 2: Presidio sidecar (HTTP, NER-based PII detection)
    prompt_guard.lua     # Tier 2: Llama Guard 3 sidecar (prompt/response safety)
    pii_protector.lua    # Tier 2: Presidio-backed tokenisation + response restoration
    patterns.lua         # Shared named pattern library (email, SSN, CC, JWT, …)

  observability/
    logger.lua           # Structured JSON log writer; fires SIEM + OTel emit at log phase
    tracer.lua           # OpenTelemetry: W3C traceparent propagation + OTLP/HTTP span export
    siem.lua             # Async security event delivery (Splunk HEC / ES / Vector / Syslog CEF)
    cost_table.lua       # Model → price per 1K tokens lookup table

  routing/
    engine.lua           # Rule evaluator (condition → action)

  auth/
    byok.lua             # Provider key encryption/decryption (AES-256-CBC)

  admin/
    api.lua              # REST admin API (tenant/gateway/user/token CRUD + playground)

  storage/
    sqlite.lua           # SQLite connection wrapper + all DB queries
    schema_config.sql    # Config DB schema (tenants, gateways, tokens, rules…)
    schema_logs.sql      # Logs DB schema (request_logs)

  state/
    init.lua             # State backend abstraction (shared_dict ↔ Redis)

  utils/
    sigv4.lua            # AWS SigV4 request signing (used by Bedrock)
    # + shared helpers: HTTP, JSON, crypto, string, uuid

config/
  gateway.lua            # Runtime config: DB paths, master key, defaults
  nginx.conf             # nginx server blocks and lua_shared_dict declarations

frontend/                # React + TypeScript admin UI (Vite build)
scripts/
  import_litellm_prices.sh   # Bulk-import model prices from LiteLLM price table
  sync_openrouter_models.sh  # Sync OpenRouter model catalog + prices to DB
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
    │                    Enforce role (viewer → 403); load per-token rate/budget config
    ├─ 4. rate_limit     Sliding-window check (dual-bucket approx in shared_dict)
    ├─ 5. quota          Budget hard-stop: token → tenant → gateway spend caps
    ├─ 6. ip_allowlist   CIDR match against gateway config allowlist
    │
    ▼  ── ngx.content phase ────────────────────────────────────
    │
    ├─ 7.  cache_check      SHA-256(provider:model:canonical_body) → serve if HIT
    │                       on miss: semantic embedding similarity search → serve if score ≥ threshold
    ├─ 8.  guardrails       Tier 1 (regex, keyword, jailbreak, json_schema, contains_code,
    │                               gibberish, language)
    │                       → Tier 2 (presidio, prompt_guard, pii_protector)
    ├─ 9.  transform        Parse + normalize body; collect x-aig-meta-* headers
    ├─ 10. routing          Evaluate ordered routing rules → provider, model, fallbacks
    ├─ 11. byok             Decrypt provider API key (cache 60 s in aig_byok dict)
    ├─ 12. upstream         HTTP call to provider; retry on 5xx; walk fallback chain
    │                       [streaming: emit usage chunk + [DONE] after stream]
    ├─ 13. guardrails_resp  Response-phase guardrail pipeline
    ├─ 14. send_response    Write buffered response body to client
    ├─ 15. cost             Count tokens; compute cost_usd; increment budget counter
    ├─ 16. cache_store      Persist response to cache (non-streaming, status 200)
    │
    ▼  ── ngx.log phase (best-effort, after response sent) ─────
    │
    ├─ 17. logger           Write structured JSON to logs.db
    │                       → SIEM async delivery (Splunk/ES/Vector/Syslog) if configured
    │                       → OTel OTLP span export (async) if otlp_endpoint configured
    └─ 18. metrics          Increment Prometheus counters in aig_metrics shared dict

[Consumer Response]
```

### Context object

Each request carries a `ctx` table populated incrementally by middleware:

```lua
ctx = {
  request_id       = "...",
  tenant_id        = "...",   gateway_id = "...",
  provider         = "openai", model = "gpt-4o",
  is_compat        = false,   -- true when routed through /compat/ endpoint
  auth_token       = { id, label, user_id, budget_usd, rate_limit },
  gateway_config   = { cache_ttl, rate_limit, detectors, semantic_cache, tracing, … },
  body             = { … },   -- parsed request JSON
  meta             = { … },   -- x-aig-meta-* headers
  -- OTel trace context (set by request_id.lua when tracing configured):
  otel_trace_id       = "4bf92f3577b34da6a3ce929d0e0e4736",  -- 32 hex
  otel_root_span_id   = "00f067aa0ba902b7",                  -- 16 hex
  otel_parent_span_id = nil,   -- propagated from incoming W3C traceparent
  otel_start_ns       = 1700000000000000000,
  -- populated after upstream:
  status           = 200,
  response_body    = "…",
  input_tokens     = 512,   output_tokens = 128,
  cache_creation_tokens = 0, cache_read_tokens = 0,
  cost_usd         = 0.004,
  latency_ms       = 340,   upstream_latency_ms = 310,
  time_to_first_token_ms = 120,
  upstream_t_start = 1700000000.1,  -- ngx.now() at start of provider call
  cached           = false,
  semantic_cache_hit = false,       -- true when served from semantic cache
  blocked          = false, blocked_by = nil,
  fallback_provider = nil,  fallback_model = nil,
}
```

---

## 5. URL Schema

```
# Provider-native endpoint
POST /v1/{tenant_slug}/{gateway_slug}/{provider}/chat/completions

# OpenAI-compatible unified endpoint (provider inferred from model name)
POST /v1/{tenant_slug}/{gateway_slug}/compat/chat/completions
POST /v1/{tenant_slug}/{gateway_slug}/compat/embeddings

# Admin API
GET    /admin/v1/tenants
POST   /admin/v1/tenants
PATCH  /admin/v1/tenants/{id}
DELETE /admin/v1/tenants/{id}
GET    /admin/v1/tenants/{id}/gateways
POST   /admin/v1/tenants/{id}/gateways
GET    /admin/v1/gateways/{id}
PATCH  /admin/v1/gateways/{id}
DELETE /admin/v1/gateways/{id}
DELETE /admin/v1/gateways/{id}/budget
POST   /admin/v1/gateways/{id}/keys
DELETE /admin/v1/gateways/{id}/keys/{provider}/{alias}
GET    /admin/v1/gateways/{id}/rules
POST   /admin/v1/gateways/{id}/rules
PATCH  /admin/v1/gateways/{id}/rules/{rule_id}
DELETE /admin/v1/gateways/{id}/rules/{rule_id}
GET    /admin/v1/gateways/{id}/tokens
POST   /admin/v1/gateways/{id}/tokens
DELETE /admin/v1/gateways/{id}/tokens/{tid}
GET    /admin/v1/tenants/{id}/users
POST   /admin/v1/tenants/{id}/users
PATCH  /admin/v1/users/{id}
DELETE /admin/v1/users/{id}
DELETE /admin/v1/users/{id}/budget
GET    /admin/v1/users/{id}/tokens
POST   /admin/v1/users/{id}/tokens
GET    /admin/v1/users/{id}/gateways
POST   /admin/v1/users/{id}/gateways/{gw_id}
DELETE /admin/v1/users/{id}/gateways/{gw_id}
GET    /admin/v1/stats
GET    /admin/v1/stats/timeseries?bucket=1h&n=24&until={unix_sec}  # time-bucketed chart data
GET    /admin/v1/logs
GET    /admin/v1/models                    # model catalog with optional ?provider= filter
GET    /admin/v1/model-prices
PUT    /admin/v1/model-prices
DELETE /admin/v1/model-prices/{provider}/{model}
POST   /admin/v1/playground/token         # issue short-lived playground token
GET    /admin/v1/playground/search?q=...  # Brave Search proxy for web search
POST   /admin/v1/client-errors            # frontend error reporting
GET    /admin/v1/client-errors
GET    /admin/v1/organizations
POST   /admin/v1/organizations
GET    /admin/v1/organizations/{id}
PATCH  /admin/v1/organizations/{id}
DELETE /admin/v1/organizations/{id}

# Admin authentication (no session guard)
GET    /admin/auth/me                      # return user from JWT cookie
POST   /admin/auth/logout
POST   /admin/auth/otp/request             # send 6-digit code via email
POST   /admin/auth/otp/verify              # exchange code for session cookie
GET    /admin/auth/google                  # initiate Google OAuth flow
GET    /admin/auth/google/callback         # OAuth callback

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
| `users` | id, tenant_id, email, role, organization_id |
| `organization` | id, name, slug, created_at, deleted_at |
| `user_gateway_access` | user_id, gateway_id |
| `model_price` | provider, model, input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k |
| `client_errors` | id, message, stack, url, user_agent, ts (frontend error reports) |
| `email_otp` | id, email, code_hash (SHA-256), expires_at, used_at, ip_addr |
| `oauth_link` | user_id, provider, subject (Google sub), email |

### Log database (SQLite / ClickHouse)

Two tables in `logs.db`:

**`request_logs`** — one row per request. In development: `logs.db` via `storage/sqlite.lua`. In production: swap for UDP → Vector/Loki or HTTP → ClickHouse.

**Key fields:** `request_id`, `tenant_id`, `gateway_id`, `provider`, `model`, `status`, `cached`, `input_tokens`, `output_tokens`, `cache_creation_tokens`, `cache_read_tokens`, `cost_usd`, `latency_ms`, `upstream_latency_ms`, `time_to_first_token_ms`, `blocked`, `blocked_by`, `prompt`, `response`, `meta`

**`semantic_cache`** — one row per stored embedding.

| Column | Type | Description |
|---|---|---|
| `id` | TEXT PK | UUID |
| `gateway_id` | TEXT | Gateway scope |
| `model` | TEXT | Model name (candidates filtered by gateway + model) |
| `prompt_hash` | TEXT | SHA-256 of prompt text (dedup guard) |
| `embedding` | TEXT | JSON float array |
| `response_body` | TEXT | Cached response body |
| `cost_usd` | REAL | Cost of the original upstream call |
| `created_at` | INTEGER | Unix seconds |
| `expires_at` | INTEGER | Unix seconds (created_at + `ttl`) |
| `hit_count` | INTEGER | Incremented on each semantic cache hit |

Index on `(gateway_id, model, created_at DESC)` for efficient candidate retrieval.

### Caching

**Exact-match cache** (`aig_cache` shared dict): keyed on SHA-256(provider:model:canonical_body). `stream`, `user`, and `metadata` fields are excluded before hashing; all other request fields are included. TTL configured per gateway via `cache_ttl` (seconds). Hit returns `X-AIG-Cache: HIT`.

**Semantic cache** (`semantic_cache` table in `logs.db`): activated per gateway via `semantic_cache.enabled`. On an exact-match miss, the incoming prompt is embedded via a configurable OpenAI-compatible endpoint and compared (cosine similarity) against stored embeddings filtered by `(gateway_id, model)`. If `best_score ≥ threshold` (default 0.95), the stored response is returned with `X-AIG-Cache: SEMANTIC_HIT` and `X-AIG-Similarity: <score>`. The store path is fully asynchronous (`ngx.timer.at(0, ...)`): after a successful upstream response, the prompt is embedded and inserted into `semantic_cache`. Streaming responses are not semantically cached.

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
provider.base_url(ctx)               -- construct upstream URL
provider.build_headers(ctx, api_key) -- Authorization + provider-specific headers
provider.build_request(ctx)          -- serialize body for the provider wire format
provider.parse_response(body)        -- extract tokens + content from buffered response
provider.parse_sse_chunk(line)       -- streaming: parse one SSE line → {delta, tokens, done}
```

**Provider → wire format mapping:**

| Provider | Format | Auth | Notes |
|---|---|---|---|
| OpenAI | Native | Bearer | Direct pass-through |
| Azure OpenAI | OpenAI | `api-key` header | Requires `azure_endpoint` + `azure_api_version`; deployment name from config |
| Anthropic | Messages API | `x-api-key` | Role/content conversion; extended thinking; prompt caching |
| Gemini | GenerateContent | Bearer | System instruction conversion |
| Vertex AI | GenerateContent | `x-goog-api-key` | Requires GCP project ID + region config |
| AWS Bedrock | InvokeModel | SigV4 | BYOK format: `ACCESS_KEY_ID:SECRET_ACCESS_KEY[:SESSION_TOKEN]` |
| Mistral | OpenAI-compat | Bearer | |
| Groq | OpenAI-compat | Bearer | |
| Together AI | OpenAI-compat | Bearer | |
| Fireworks AI | OpenAI-compat | Bearer | |
| Cerebras | OpenAI-compat | Bearer | |
| DeepSeek | OpenAI-compat | Bearer | |
| OpenRouter | OpenAI-compat | Bearer | 300+ aggregated models; universal compat fallback |
| Perplexity | OpenAI-compat | Bearer | |
| SambaNova | OpenAI-compat | Bearer | |
| xAI / Grok | OpenAI-compat | Bearer | |
| NVIDIA NIM | OpenAI-compat | Bearer | |
| Cloudflare Workers AI | OpenAI-compat | Bearer | `@cf/` model prefix |
| Cohere | Cohere v2 Chat | Bearer | Native format, different schema |
| HuggingFace | Inference API | Bearer | org/model routing (HuggingFaceH4/, tiiuae/, etc.) |
| Ollama | OpenAI-compat | None | Local server; base URL from `provider_base_urls.ollama` |

### Compat endpoint model resolution

`/compat/chat/completions` infers the provider from the model name in three tiers:

1. **Exact match** — hardcoded map (e.g., `gpt-4o` → openai, `claude-sonnet-4-6` → anthropic)
2. **Prefix match** — sorted longest-first (e.g., `claude-` → anthropic, `gemini-` → gemini, `@cf/` → cloudflare)
3. **Fallback** — `openrouter` (catches any unknown model; routes to OpenRouter's aggregated catalog)

### Streaming

For compat requests, `handle_compat_streaming` re-encodes provider-native SSE (Anthropic format, Gemini format, etc.) into OpenAI `chat.completion.chunk` format. A usage chunk containing token counts and cache stats is emitted just before `[DONE]`, enabling clients to display real-time metrics.

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

SHA-256 hash stored in DB; plaintext never persisted. Token carries optional per-token `rate_limit` and `budget_usd` that are checked independently alongside gateway-level limits.

### Admin panel authentication

The admin panel (`/admin/*`) is protected by a stateless JWT session:

```
Algorithm : HS256 (HMAC-SHA256)
Secret    : AIG_JWT_SECRET env var (required in production; warns if using "dev-change-me")
Expiry    : AIG_JWT_EXPIRY_SECS (default 28800 = 8 h)
Cookie    : aig_admin=<token>; Path=/; HttpOnly; SameSite=Strict
```

**JWT payload:** `{ sub, email, role, org, iat, exp }`

**nginx routing split:**
- `/admin/auth/*` — public, no guard → `admin.auth_handlers`
- `/admin/*` — `access_by_lua_block { auth.require_session() }` → `admin.api`

`require_session()` validates the cookie, populates `ngx.ctx.admin_user`, and returns `401` with `{"error":"unauthenticated"}` on any failure.

**Login methods:**
- **Google SSO** — server-side OAuth 2.0 code flow; CSRF state in `aig_ratelimit` shared dict (10-min TTL); id_token payload decoded via base64url (sig verify skipped — HTTPS transport trusted); user must be pre-provisioned with `admin` or `admin_org` role
- **Email OTP** — 6-digit cryptographically-random code (via `resty.random`), SHA-256 hashed in `email_otp` table, delivered via `sendmail -t`; 15-min TTL; single-use; generic response to prevent email enumeration

**Roles:**

| Role | Access |
|---|---|
| `admin` | Full platform — all organizations, tenants, gateways |
| `admin_org` | Own organization only — tenants/gateways/users scoped by `org_id` |
| `member` / `viewer` | Inference-layer identities; cannot log in to admin panel |

**Bootstrap admin:** `storage.bootstrap_admin()` is called in `init_by_lua_block`. If no admin user exists and `AIG_BOOTSTRAP_ADMIN_EMAIL` is set, it creates an `admin` user with that email.

**Implementation:** `src/admin/auth.lua`, `src/admin/auth_handlers.lua`, `src/utils/jwt.lua`, `src/utils/email.lua`

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

### Guardrails

Two-tier content safety pipeline running at both request and response phase. See §11 for full details. Blocked responses are returned as synthetic 200s in the correct wire format (JSON or SSE) so clients receive a valid-shaped response rather than a hard error.

### IP allowlist

CIDR-based allow list per gateway. Matching uses 32-bit integer masking via LuaJIT `bit` library. Empty list = allow all.

---

## 11. Guardrail Pipeline

Tiered content safety pipeline. Runs at both request and response phase.

```
Tier 1 (in-process, ~microseconds):
  regex          — named pattern sets + custom regex (block / scrub / flag)
  keyword        — exact string match (block / flag)
  jailbreak      — zero-config built-in jailbreak phrase list (18 phrases, block / flag)
  json_schema    — JSON schema validation for structured-output responses (response-only)
                   block reason codes: json_parse_error, missing_field, type_mismatch, range_violation
  contains_code  — source-code detection using fence + structural heuristics (both phases)
                   supported: sql, python, javascript, bash, html, lua; min_signals configurable
  gibberish      — low-quality response detection via 3 signals (response-only)
                   signals: Shannon entropy, word repetition ratio, alpha-char ratio
                   1 signal → always flagged; ≥2 signals → configured action
  language       — writing-system detection via UTF-8 byte-range heuristics (both phases)
                   detected scripts: latin, cjk, cyrillic, arabic, hebrew, thai, devanagari

Tier 2 (HTTP sidecar, ~milliseconds):
  presidio      — Presidio Analyzer + Anonymizer for NER-based PII detection
  prompt_guard  — Llama Guard 3 for prompt/response safety classification (14 categories)
  pii_protector — Presidio-backed tokenisation; restores real values in response
```

The orchestrator (`src/guardrails/orchestrator.lua`) runs all Tier 1 detectors first; Tier 2 detectors only run if Tier 1 passes. Within each tier, detectors run in configuration order. The most restrictive action (`block` > `scrub` > `flag`) wins when multiple detectors fire on the same request.

Synthetic blocked responses match the request wire format (OpenAI streaming, OpenAI non-streaming, or Anthropic) so clients receive a valid-shaped response rather than a hard error.

---

## 12. Observability

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

### Stats API

`GET /admin/v1/stats` returns aggregated `PeriodStats` for five windows: `last_min`, `hour`, `today`, `yesterday`, `last_7d`. Each window includes request count, blocked, cached, token totals, cost, and avg latencies. Also returns `by_tenant` summary (6 fields) and `recent` / `recent_blocked` log entries.

`GET /admin/v1/stats/analytics?since=<unix_ms>` returns latency percentiles (p50/p95/p99), top 10 models by volume, and full per-tenant/per-gateway/per-user breakdowns. Used by the analytics dashboard.

`GET /admin/v1/stats/timeseries` returns zero-filled time-bucketed data for sparklines:

| Param | Values | Default |
|---|---|---|
| `bucket` | `5m`, `15m`, `30m`, `1h`, `6h`, `1d` | `1h` |
| `n` | 1–168 buckets | 24 |
| `until` | Unix seconds (end of window) | now |
| `tenant_id` | UUID string | (all tenants) |

`GET /admin/v1/tenants/{id}/analytics` returns per-tenant timeseries + top models, used by the cost analytics drilldown page.

Buckets are aligned to bucket boundaries. Missing buckets are zero-filled in Lua before returning. SQLite integer division is enforced by embedding the bucket-size-in-ms as an integer literal in the SQL string (binding it as a Lua number causes SQLite to use REAL division, producing one row per request).

### Prometheus metrics

Exposed at `GET /metrics`. Four metrics, all with labels `{provider, tenant_id, status, cached}`:

| Metric | Type |
|---|---|
| `aig_requests_total` | Counter |
| `aig_latency_ms` (count + sum) | Histogram approximation |
| `aig_input_tokens_total` | Counter |
| `aig_output_tokens_total` | Counter |

### Cost attribution

`src/observability/cost_table.lua` maps `(provider, model)` → `{input_per_1k, output_per_1k, cache_write_per_1k, cache_read_per_1k}`. The DB `model_price` table overrides the hardcoded defaults. The `scripts/import_litellm_prices.sh` and `scripts/sync_openrouter_models.sh` scripts populate the table in bulk.

### SIEM integration

`src/observability/siem.lua` forwards security events to an external SIEM asynchronously in the log phase. Delivery is fire-and-forget (via `ngx.timer.at`); it never adds latency to inference requests.

Supported backends: `splunk_hec` (HTTPS/Bearer), `elasticsearch` / `opensearch` (HTTPS/Basic), `vector` (HTTP, fan-out), `syslog` (UDP or TCP, CEF or RFC 5424 format).

Config lives under `gateway_config.siem` (gateway-level) or `tenant.siem` (tenant default, overridden by gateway). Event filter controls which events are forwarded: `blocked`, `guardrail`, `scrubbed`, `all`.

### OpenTelemetry distributed tracing

`src/observability/tracer.lua` emits W3C-compliant OTLP/HTTP JSON spans to any OpenTelemetry collector. This is independent of the internal pipeline trace (playground/Traces API).

**Initialisation** (`request_id.lua`): parses the incoming `traceparent` header (if present), propagates `trace_id` and `parent_span_id`, or generates new IDs. Sets `ctx.otel_trace_id`, `ctx.otel_root_span_id`, `ctx.otel_start_ns`.

**Traceparent forwarding** (`upstream.lua`): injects a `traceparent` header into every upstream provider call, enabling end-to-end trace correlation through the provider's infrastructure.

**Span export** (`logger.lua` log phase): builds and asynchronously POSTs the OTLP payload to `{otlp_endpoint}/v1/traces`.

**Span model:**

| Span | Kind | Name | When |
|---|---|---|---|
| Root span | SERVER (2) | `inference` | Every request |
| Upstream span | CLIENT (3) | `upstream.<provider>` | Only when upstream was called |

Root span carries GenAI semantic convention attributes: `gen_ai.system`, `gen_ai.request.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.request.cost_usd`, plus `aig.*` gateway-specific attributes.

**Config** under `gateway_config.tracing`:

| Field | Default | Notes |
|---|---|---|
| `otlp_endpoint` | — | Base URL, e.g. `http://otel-collector:4318`. Required to enable OTLP export |
| `service_name` | `ai-gateway` | `service.name` resource attribute |
| `headers` | `{}` | Extra HTTP headers (e.g. auth for managed collectors) |
| `sample_rate` | `1.0` | Fraction of requests to export (applied post-response, not head-based) |
| `include_bodies` | `false` | Adds `aig.request_size_bytes` to spans |

---

## 13. Admin UI (Frontend)

React 19 + TypeScript SPA built with Vite. Proxied through Vite dev server (`/admin` and `/v1` → `localhost:8081`).

**Modules:**

| Module | Description |
|---|---|
| Login | Google SSO + Email OTP two-step login; `AuthProvider` + `AuthGuard` protect all routes |
| Dashboard | Hero cards (Requests, Cost, Guardrail Hits) with sparklines; timeframe switcher (Today/Yesterday/Last 7d/Last hour/Last minute) |
| Analytics | Cost analytics with per-tenant drilldown, timeseries chart, and top-models table |
| Organizations | Organization CRUD (`admin` only); `admin_org` users see read-only view of their own org |
| Tenants | Tenant CRUD |
| Gateways | Gateway config, routing rules, BYOK keys |
| Users | User management, role assignment, gateway access |
| Logs | Request log viewer with provider/tenant/gateway filters |
| Prices | Model price table management |
| Guardrails | Guardrail configuration builder (GuardrailBuilder UI) |
| Monitor | Real-time monitoring with optional tenant filter |
| Playground | Interactive model comparison UI (see below) |

### Dashboard

The Dashboard page fetches all data in parallel with `Promise.allSettled` — it always renders regardless of API failures, falling back to zero values for any failed request.

Data sources:
- `GET /admin/v1/stats` — period aggregates (last_min, hour, today, yesterday, last_7d)
- Five parallel `GET /admin/v1/stats/timeseries` calls covering different windows and granularities

Three hero metric cards (Requests, Cost, Blocked) each contain an inline pure-SVG sparkline (area fill + polyline, `preserveAspectRatio="none"`). The sparkline dataset switches when the user changes the timeframe tab. Chart data selection:

| Timeframe | Timeseries params |
|---|---|
| Today | `bucket=1h&n={hoursElapsedToday}` |
| Yesterday | `bucket=1h&n=24&until={midnightToday-1}` |
| Last 7 days | `bucket=1d&n=7` |
| Last hour / Last minute | `bucket=5m&n=12` |

### Playground

Multi-panel AI chat interface for testing models against a live gateway:

- **Multi-model comparison** — up to 4 panels side-by-side, each targeting a different model
- **Streaming** — real-time SSE streaming with progressive text display and blinking cursor
- **Real-time metrics** — live elapsed-ms counter; token counts (input, output, cache write, cache read) and cost estimate displayed as soon as the usage chunk arrives (before `[DONE]`)
- **Markdown rendering** — `react-markdown` + `remark-gfm`; Raw/Rendered toggle per panel
- **Web search** — optional toggle sends web search tool call to the model (Brave Search API proxied via `/admin/v1/playground/search`)
- **Persisted state** — tenant, gateway, model selection, system prompt, temperature, max tokens saved to `localStorage` (`aig_playground_v1`) and restored on reload
- **Error handling** — structured error badges (AUTH ERROR, RATE LIMITED, NOT FOUND, SERVER ERROR) with contextual hints; network errors detected separately
- **Playground tokens** — short-lived gateway auth tokens (10 min TTL, `playground` scope); at most one token per gateway (old tokens purged on new issue)

---

## 14. nginx Configuration

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

---

## 15. Deployment Topology

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
