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
│  │  auth · rate-limit · IP allowlist  │  │
│  ├────────────────────────────────────┤  │
│  │     Content phase middleware       │  │
│  │  cache · detectors · guardrails ·  │  │
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

  middleware/
    auth.lua             # Bearer / x-aig-token / x-api-key validation
    cache_check.lua      # SHA-256 exact-match cache lookup
    cache_store.lua      # Persist non-streaming 200 responses to cache
    cost.lua             # Token counting + budget counter increment
    detectors.lua        # Request-phase detector pipeline entry point
    detectors_response.lua  # Response-phase detector pipeline entry point
    dlp.lua              # Legacy DLP pattern scan (block/scrub/flag)
    guardrails_request.lua  # Llama Guard 3 prompt classification
    guardrails_response.lua # Response-side pattern + Llama Guard check
    quota.lua            # Budget hard-stop enforcement
    upstream.lua         # Provider HTTP call with retry + fallback chain

  detectors/
    orchestrator.lua     # Tier 1 → Tier 2 sequencing, action merging
    regex.lua            # Tier 1: in-process regex patterns (block/scrub/flag)
    keyword.lua          # Tier 1: exact keyword matching
    presidio.lua         # Tier 2: Presidio sidecar (HTTP, NER-based PII detection)
    llm_guard.lua        # Tier 2: Llama Guard 3 sidecar (prompt/response safety)
    patterns.lua         # Shared named pattern library (email, SSN, CC, JWT, …)

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
    │                    Enforce role (viewer → 403); load per-token rate/budget overrides
    ├─ 4. rate_limit     Sliding-window check (dual-bucket approx in shared_dict)
    ├─ 5. ip_allowlist   CIDR match against gateway config allowlist
    │
    ▼  ── ngx.content phase ────────────────────────────────────
    │
    ├─ 6.  cache_check      SHA-256(provider:model:canonical_body) → serve if HIT
    ├─ 7.  detectors        Tier 1 (regex, keyword) → Tier 2 (presidio, llm_guard)
    ├─ 8.  dlp              Legacy pattern scan; block / scrub / flag PII patterns
    ├─ 9.  guardrails_req   Call Llama Guard 3; block if unsafe (S1–S14)
    ├─ 10. transform        Parse + normalize body; collect x-aig-meta-* headers
    ├─ 11. routing          Evaluate ordered routing rules → provider, model, fallbacks
    ├─ 12. byok             Decrypt provider API key (cache 60 s in aig_byok dict)
    ├─ 13. upstream         HTTP call to provider; retry on 5xx; walk fallback chain
    │                       [streaming: emit usage chunk + [DONE] after stream]
    ├─ 14. guardrails_resp  Pattern-check response body (non-streaming only)
    ├─ 15. detectors_resp   Response-phase detector pipeline
    ├─ 16. cost             Count tokens; compute cost_usd; increment budget counter
    ├─ 17. cache_store      Persist response to cache (non-streaming, status 200)
    │
    ▼  ── ngx.log phase (best-effort, after response sent) ─────
    │
    ├─ 18. logger           Write structured JSON to logs.db
    └─ 19. metrics          Increment Prometheus counters in aig_metrics shared dict

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
  gateway_config   = { cache_ttl, rate_limit, dlp, guardrails, … },
  body             = { … },   -- parsed request JSON
  meta             = { … },   -- x-aig-meta-* headers
  -- populated after upstream:
  status           = 200,
  response_body    = "…",
  input_tokens     = 512,   output_tokens = 128,
  cache_creation_tokens = 0, cache_read_tokens = 0,
  cost_usd         = 0.004,
  latency_ms       = 340,   upstream_latency_ms = 310,
  time_to_first_token_ms = 120,
  cached           = false,
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
GET    /admin/v1/logs
GET    /admin/v1/models                    # model catalog with optional ?provider= filter
GET    /admin/v1/model-prices
PUT    /admin/v1/model-prices
DELETE /admin/v1/model-prices/{provider}/{model}
POST   /admin/v1/playground/token         # issue short-lived playground token
GET    /admin/v1/playground/search?q=...  # Brave Search proxy for web search
POST   /admin/v1/client-errors            # frontend error reporting
GET    /admin/v1/client-errors

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
| `client_errors` | id, message, stack, url, user_agent, ts (frontend error reports) |

### Log database (SQLite / ClickHouse)

One row per request. In development: `logs.db` via `storage/sqlite.lua`. In production: swap for UDP → Vector/Loki or HTTP → ClickHouse.

**Key fields:** `request_id`, `tenant_id`, `gateway_id`, `provider`, `model`, `status`, `cached`, `input_tokens`, `output_tokens`, `cache_creation_tokens`, `cache_read_tokens`, `cost_usd`, `latency_ms`, `upstream_latency_ms`, `time_to_first_token_ms`, `blocked`, `blocked_by`, `prompt`, `response`, `meta`

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

### DLP (legacy)

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

## 11. Detector Pipeline

A more flexible, tiered replacement for the legacy DLP + Guardrails middleware. Runs at both request and response phase.

```
Tier 1 (in-process, ~microseconds):
  regex    — named patterns + custom regex (block / scrub / flag)
  keyword  — exact string match (block / flag)

Tier 2 (HTTP sidecar, ~milliseconds):
  presidio  — Presidio Analyzer + Anonymizer for NER-based PII detection
  llm_guard — Llama Guard 3 for prompt/response safety classification
```

The orchestrator runs all Tier 1 detectors first; Tier 2 detectors only run if Tier 1 passes. Within each tier, detectors run in configuration order. The most restrictive action (`block` > `scrub` > `flag`) wins when multiple detectors fire on the same request.

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

---

## 13. Admin UI (Frontend)

React 19 + TypeScript SPA built with Vite. Proxied through Vite dev server (`/admin` and `/v1` → `localhost:8081`).

**Modules:**

| Module | Description |
|---|---|
| Dashboard | Usage stats, request volume, cost summary |
| Tenants | Tenant CRUD |
| Gateways | Gateway config, routing rules, BYOK keys |
| Users | User management, role assignment, gateway access |
| Logs | Request log viewer with provider/tenant/gateway filters |
| Prices | Model price table management |
| Detectors | Detector configuration builder (DetectorBuilder UI) |
| Monitor | Real-time monitoring |
| Settings | Gateway-level settings |
| Playground | Interactive model comparison UI (see below) |

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
