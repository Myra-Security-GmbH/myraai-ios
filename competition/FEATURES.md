# AI Gateway — Feature Reference

**Stack:** OpenResty (LuaJIT)
**Pattern:** Multi-tenant reverse proxy with a middleware chain across three Nginx phases (access → content → log)
**Storage:** SQLite (dev/single-server), MySQL 8.0+, or PostgreSQL (production)
**State:** `ngx.shared.dict` (single-server) or Redis (distributed)

---

## Table of Contents

1. [Request Pipeline](#1-request-pipeline)
2. [Multi-Provider Support](#2-multi-provider-support)
3. [Authentication & Authorization](#3-authentication--authorization)
4. [Dynamic Routing & Fallback](#4-dynamic-routing--fallback)
5. [Caching](#5-caching)
6. [Rate Limiting](#6-rate-limiting)
7. [Budget & Quota Enforcement](#7-budget--quota-enforcement)
8. [Guardrail Pipeline](#8-guardrail-pipeline)
9. [Web Search](#9-web-search)
10. [Reasoning Model Support](#10-reasoning-model-support)
11. [Provider Key Management (BYOK)](#11-provider-key-management-byok)
12. [IP Allowlist](#12-ip-allowlist)
13. [Response Streaming](#13-response-streaming)
14. [Cost Attribution & Pricing](#14-cost-attribution--pricing)
15. [Observability & Logging](#15-observability--logging)
16. [Prometheus Metrics](#16-prometheus-metrics)
17. [Multi-Tenancy](#17-multi-tenancy)
18. [Admin REST API](#18-admin-rest-api)
19. [Dashboard UI](#19-dashboard-ui)
20. [Playground UI](#20-playground-ui)
21. [Chat Console UI](#21-chat-console-ui)
22. [Gateway Configuration Reference](#22-gateway-configuration-reference)
23. [Error Handling](#23-error-handling)

---

## 1. Request Pipeline

Requests flow through a fixed middleware chain in phase order:

**Access phase** (before body is read):
1. `request_id` — Inject or forward `X-Request-Id`
2. `tenant` — Resolve tenant/gateway/provider from URL path
3. `auth` — Validate bearer token
4. `rate_limit` — Sliding-window rate limit check
5. `quota` — Budget hard-stop: per-token → per-tenant → per-gateway
6. `ip_allowlist` — CIDR allowlist enforcement

**Content phase** (body available):
1. `cache_check` — SHA-256 exact-match lookup; serve immediately on hit; falls back to semantic embedding similarity check if configured
2. `guardrails` — Guardrail pipeline: Tier 1 (regex, keyword, jailbreak, json_schema, contains_code, gibberish, language) then Tier 2 (presidio, prompt_guard, pii_protector) on request
3. `transform` — Parse and normalize request body
4. `routing` — Rules engine (provider, model, fallback chain)
5. `byok` — Decrypt and inject provider API key
6. `web_search` — Optional: two-leg agentic search loop (Brave API)
7. `upstream` — Call provider with retry + fallback
8. `guardrails_response` — Guardrail pipeline scan on response
9. `send_response` — Write buffered response body to client
10. `cost` — Token counting and budget increment
11. `cache_store` — Persist non-streaming 200 responses

**Log phase** (best-effort, after response sent):
1. Structured JSON request log
2. Prometheus metrics update
3. SIEM export (Splunk HEC / Elasticsearch / Vector / Syslog-CEF) — if configured
4. OpenTelemetry span export (OTLP/HTTP JSON) — if `tracing.otlp_endpoint` is set

---

## 2. Multi-Provider Support

### Supported Providers

| Provider | Wire Format | Auth | Notes |
|---|---|---|---|
| OpenAI | Native OpenAI | Bearer | Direct pass-through |
| Azure OpenAI | OpenAI | Bearer | Requires `azure_endpoint`, `azure_deployment`, `azure_api_version` |
| Anthropic | Messages API | x-api-key | System prompt, extended thinking, prompt caching |
| Google Gemini | GenerateContent | Bearer | System instruction conversion, safety settings |
| Vertex AI | GenerateContent | Bearer + OAuth2 | Google ADC / service account; `vertex_project`, `vertex_region` |
| AWS Bedrock | Bedrock Converse | SigV4 | HMAC-SHA256 request signing; `bedrock_region` |
| Mistral AI | OpenAI-compatible | Bearer | |
| Groq | OpenAI-compatible | Bearer | |
| Together AI | OpenAI-compatible | Bearer | `meta-llama/`, `Qwen/`, `microsoft/` prefixes |
| Fireworks | OpenAI-compatible | Bearer | `accounts/fireworks/models/` prefix |
| Cerebras | OpenAI-compatible | Bearer | Fast inference |
| DeepSeek | OpenAI-compatible | Bearer | `deepseek-` prefix |
| OpenRouter | OpenAI-compatible | Bearer | Aggregates 300+ models; universal compat fallback |
| Perplexity | OpenAI-compatible | Bearer | `sonar-` prefix |
| SambaNova | OpenAI-compatible | Bearer | |
| xAI | OpenAI-compatible | Bearer | `grok-` prefix |
| NVIDIA NIM | OpenAI-compatible | Bearer | `nvidia/` prefix |
| Cloudflare AI | OpenAI-compatible | Bearer | `@cf/` prefix |
| Cohere | Cohere Chat API | Bearer | Native request/response translation |
| HuggingFace | OpenAI-compatible | Bearer | Org-prefix routing (`tiiuae/`, `bigcode/`, etc.) |
| Ollama | OpenAI-compatible | None | Local inference; `OLLAMA_BASE_URL` env; `think` flag support |

### Endpoints

- **Native:** `/v1/{tenant}/{gateway}/{provider}/chat/completions`
- **Unified (OpenAI-compat):** `/v1/{tenant}/{gateway}/compat/chat/completions` — provider inferred from model name

### Compat Model Resolution (3-tier)

The compat endpoint resolves the provider from the `model` field in three steps:

1. **Exact match** — known model IDs mapped directly (e.g. `gpt-4o` → openai, `claude-sonnet-4-6` → anthropic)
2. **Prefix match** — model name prefix (e.g. `gpt-` → openai, `claude-` → anthropic, `@cf/` → cloudflare, `meta.` → bedrock)
3. **OpenRouter fallback** — any unrecognized model name is routed to OpenRouter, which aggregates 300+ models

This means any model available on OpenRouter is accessible via the compat endpoint with no gateway configuration changes (only a valid OpenRouter BYOK key is required).

### HuggingFace Org-Prefix Routing

The following HuggingFace-hosted org prefixes are recognized:

`HuggingFaceH4/`, `tiiuae/`, `bigcode/`, `EleutherAI/`, `microsoft/`, `google/` (HF-hosted), `stabilityai/`, `mistralai/`

### LiteLLM-Style Provider Prefix Stripping

The `transform` middleware strips LiteLLM-style namespace prefixes from model names before forwarding to the provider. This allows clients that use LiteLLM naming conventions (e.g. `gemini/gemma-3-27b-it`, `groq/llama3-8b-8192`, `fireworks_ai/accounts/fireworks/models/llama-v3p1-8b-instruct`) to route through the gateway unchanged.

Recognised prefixes (17 providers): `gemini/`, `vertex_ai/`, `azure_ai/`, `azure/`, `groq/`, `text-completion-codestral/`, `mistral/`, `together_ai/`, `fireworks_ai/`, `nvidia_nim/`, `sambanova/`, `deepseek/`, `xai/`, `perplexity/`, `cerebras/`, `cohere/`, `bedrock/`, `openrouter/`, `ollama/`.

### Request Translation

- **Anthropic:** Converts OpenAI `chat/completions` to the Messages API; system messages extracted; extended thinking via `x-aig-provider-anthropic-beta: interleaved-thinking-2025-05-14`
- **Gemini / Vertex:** Converts to `GenerateContent` with system instruction support; SSE chunks normalised; native `googleSearch` grounding used when web search is enabled (Gemini models only — not Gemma)
- **Bedrock:** Converse API with SigV4 HMAC-SHA256 request signing; region from `bedrock_region` gateway config
- **Cohere:** Native Chat API format; response translated back to OpenAI shape
- **OpenRouter / Groq / Fireworks / etc.:** Forwarded as-is (OpenAI format)

### Provider Header Pass-Through

`x-aig-provider-*` headers are forwarded as raw provider headers.
Example: `x-aig-provider-anthropic-beta: interleaved-thinking-2025-05-14`

---

## 3. Authentication & Authorization

### Token Acceptance

Tokens are accepted from any of these headers (in priority order):

1. `x-aig-token`
2. `Authorization: Bearer <token>`
3. `x-api-key` (Anthropic SDK compatibility)

### Token Storage

SHA-256 hashes are stored — plaintext is never persisted. Per-token metadata:

| Field | Description |
|---|---|
| `expiration` | ISO-8601 timestamp; lexicographic comparison |
| `scopes` | JSON array (reserved for future use) |
| `user_id` | Optional user binding |
| `label` | Human-readable name (e.g., "dev laptop") |
| `rate_limit` | Per-token override `{requests, window_sec}` |
| `budget_usd` | Per-token spend cap |

### User Roles

| Role | Inference | Admin scope |
|---|---|---|
| `admin` | Yes | Full platform access; may assign any role |
| `tenant_admin` | Yes | Full access within own tenant; may create/manage gateways and users (member/viewer only); cannot manage other tenants |
| `member` | Yes (assigned gateways only) | No admin access; may not assign roles |
| `viewer` | No (403 Forbidden) | Read-only; inference blocked |

### Role Assignment Rules

A caller may only assign roles strictly below their own:

| Caller | Assignable roles |
|---|---|
| `admin` | `admin`, `tenant_admin`, `member`, `viewer` |
| `tenant_admin` | `member`, `viewer` |
| `member` / `viewer` | *(none)* |

### Access Control

- Gateway auth is required by default; disable with `auth_required: false`
- Per-user gateway access matrix (`user_gateway_access` table) — enforced for `member` role
- `tenant_admin` users are automatically scoped to their own tenant; cross-tenant requests return 403
- Deleting a user immediately disables all their tokens

---

## 4. Dynamic Routing & Fallback

### Rules Engine

Routing rules are evaluated in ascending priority order; the first matching rule wins.

**Rule structure:**
```json
{
  "priority": 10,
  "conditions": [{"field": "model", "op": "prefix", "value": "gpt-"}],
  "actions": {
    "provider": "openai",
    "model": "gpt-4o",
    "fallbacks": [{"provider": "anthropic", "model": "claude-sonnet-4-6"}]
  },
  "enabled": true
}
```

### Condition Fields

| Field | Example |
|---|---|
| `model` | Request model name |
| `provider` | Current provider |
| `tenant_id` | Tenant UUID |
| `header:{name}` | Any HTTP header (e.g., `header:x-customer-tier`) |
| `meta:{key}` | Custom `x-aig-meta-*` header value |

### Condition Operators

`eq`, `neq`, `prefix`, `contains`, `regex`

### Fallback Chain

- Primary provider: up to `retry_count` attempts (default: 2)
- Each fallback: one attempt only
- BYOK keys are automatically swapped when a fallback uses a different provider
- If all providers fail: `502 ALL_PROVIDERS_FAILED`
- 4xx from provider: returned to client immediately (no retry)
- `fallback_provider` and `fallback_model` recorded in request logs

### Load Balancing

A routing rule can use a `load_balance` action instead of `provider`/`model` to distribute traffic across multiple targets:

```json
{
  "actions": {
    "load_balance": {
      "strategy": "weighted_random",
      "targets": [
        { "provider": "openai",    "model": "gpt-4o",            "weight": 7 },
        { "provider": "anthropic", "model": "claude-sonnet-4-6", "weight": 3 }
      ]
    }
  }
}
```

| Strategy | Behaviour |
|---|---|
| `weighted_random` | Probabilistic selection proportional to weight (default) |
| `round_robin` | Sequential rotation via atomic shared-dict counter |

- `weight: 0` disables a target without removing it from config
- Non-selected active targets are automatically tried as fallbacks on failure
- **Sticky sessions** — `sticky.field` (supports `meta.<key>` notation) pins a user/session to one target for `sticky.ttl` seconds

### Circuit Breaker

Automatically opens when a provider accumulates failures, then probes after a cooldown. State machine: **CLOSED → OPEN → HALF_OPEN → CLOSED**.

```json
"circuit_breaker": {
  "enabled": true,
  "failure_threshold": 5,
  "window_sec": 60,
  "cooldown_ms": 30000,
  "failure_status_codes": [500, 502, 503, 504]
}
```

- Connection/timeout errors always count as failures regardless of `failure_status_codes`
- State stored in `ngx.shared` dicts (or Redis in distributed mode) — no database writes
- Breaker state checked **before** each upstream attempt; open breakers skip the provider and advance to the next fallback
- Status visible via `GET /admin/v1/gateways/{id}/circuit-breaker`

---

## 5. Caching

### Exact-Match Cache

- **Key:** SHA-256(`provider:model:canonical_json_body`)
- Excluded from key: `stream`, `user`, `metadata` (ensures semantic correctness)
- **Storage:** `aig_cache` shared dict or Redis
- **TTL:** Configured per gateway via `cache_ttl` (seconds); 0 = disabled
- **Cache hit:** Returns 200 immediately with `X-AIG-Cache: HIT`
- **Stored format:** `{body, cost_usd}` — only for non-streaming 200 responses
- **Savings tracking:** Logs `saved_cost_usd` and `saved_latency_ms` on cache hits

### Semantic Cache

Embedding-based similarity cache that serves near-duplicate and rephrased prompts from cache without calling the upstream model.

**How it works:**

1. On cache miss, the incoming prompt is embedded via a configurable embedding API
2. Cosine similarity is computed against stored embeddings for the same gateway + model
3. If the best match exceeds the configured threshold, the cached response is returned
4. On upstream success, the prompt embedding and response are stored asynchronously via `ngx.timer.at(0, ...)` — never blocking the response path

**Configuration:**

```json
"semantic_cache": {
  "enabled": true,
  "threshold": 0.95,
  "embedding_url": "https://api.openai.com/v1/embeddings",
  "embedding_api_key": "sk-...",
  "embedding_model": "text-embedding-3-small",
  "max_candidates": 100,
  "ttl": 86400
}
```

| Field | Default | Description |
|---|---|---|
| `enabled` | `false` | Enable semantic cache for this gateway |
| `threshold` | `0.95` | Cosine similarity threshold (0.0–1.0); lower = more aggressive caching |
| `embedding_url` | — | OpenAI-compatible embeddings endpoint |
| `embedding_api_key` | — | API key for the embedding service |
| `embedding_model` | — | Embedding model name (e.g. `text-embedding-3-small`) |
| `max_candidates` | `100` | Maximum stored embeddings to compare per lookup |
| `ttl` | `86400` | Cache entry TTL in seconds (default: 24 h) |

**Response headers on semantic hit:**
- `X-AIG-Cache: SEMANTIC_HIT`
- `X-AIG-Similarity: <score>` (e.g. `0.9823`)

**Threshold guidance:**
- `0.97–1.00` — strict (exact or near-exact phrasing only)
- `0.95` — balanced (recommended starting point)
- `0.92–0.94` — loose (rephrased or expanded questions; higher false-positive risk)

**Storage:** `semantic_cache` table in the logs SQLite database. Entries indexed by `(gateway_id, model, created_at DESC)`.

**Constraints:**
- Streaming responses are not semantically cached
- Embedding API call adds ~50 ms on cache miss (negligible vs 500 ms–3 s LLM latency)
- Works with any OpenAI-compatible embedding endpoint, including Ollama (`/api/embeddings`) for on-premise deployments

---

## 6. Rate Limiting

### Algorithm

Sliding-window approximation using dual time buckets:

```
effective_count = prev_bucket * (1 - elapsed/window) + cur_bucket
```

### Configuration

- **Per gateway:** `gateway_config.rate_limit: {requests: N, window_sec: S}` — shared across all tokens
- **Per token:** `auth_token.rate_limit` JSON `{requests: N, window_sec: S}` — independent per-token limit

Both limits are checked independently in the same access phase. Token creation via the admin UI exposes rate limit fields.

### Behavior

- Returns `429` with `X-RateLimit-Limit`, `X-RateLimit-Remaining`, `Retry-After` headers
- Logs `blocked_by="rate_limit"` with scope (`token:` prefix for per-token blocks)
- Shared dict keys: `rl:{gateway_id}` (gateway), `rl:token:{token_id}` (token)

---

## 7. Budget & Quota Enforcement

### Levels (checked in order, most specific first)

1. **Per-token budget:** `auth_token.budget_usd` — blocks this token when cumulative cost exceeds cap
2. **Per-tenant budget:** `tenant.budget_usd` — blocks all gateways under the tenant
3. **Per-gateway budget:** `gateway_config.budget_usd` — blocks this gateway only

### Cost Calculation

```
cost = (input_tokens / 1000) * price.input_per_1k
     + (output_tokens / 1000) * price.output_per_1k
     + (cache_write_tokens / 1000) * price.cache_write_per_1k   # Anthropic only
     + (cache_read_tokens / 1000) * price.cache_read_per_1k     # Anthropic only
```

Costs are stored as micro-dollars (`cost * 1e6`) to avoid floating-point precision loss.

### Behavior

- Budget counters incremented atomically after each request
- Returns `429 QUOTA_EXCEEDED` when `spent >= budget` at any scope
- Budget resets:
  - Gateway: `DELETE /admin/v1/gateways/{id}/budget`
  - Tenant: `DELETE /admin/v1/tenants/{id}/budget`
  - User tokens: `DELETE /admin/v1/users/{id}/budget`
- Budget exceeded events fire the `budget_exceeded` webhook (see §7a)

---

## 7a. Webhooks

Real-time HTTP POST notifications on gateway events. Configured per gateway in `gateway_config.webhooks`.

### Configuration

```json
"webhooks": {
  "url":    "https://hooks.example.com/ai-gateway",
  "secret": "optional-hmac-signing-key",
  "events": ["blocked", "budget_exceeded", "circuit_open"]
}
```

| Field | Required | Description |
|---|---|---|
| `url` | Yes | HTTPS endpoint to POST events to |
| `secret` | No | Signs body: `X-AIG-Signature: sha256=<hex>` |
| `events` | No | Subscribed events; absent = all events |

### Events

| Event | When fired | Key `data` fields |
|---|---|---|
| `blocked` | Any request blocked (guardrail / quota / rate limit) | `blocked_by`, `block_reason`, `provider`, `model`, `request_id` |
| `budget_exceeded` | Spend limit reached at token / tenant / gateway scope | `scope`, `budget_usd`, `spent_usd` |
| `circuit_open` | Circuit breaker transitions to OPEN for a provider | `provider`, `failures`, `threshold`, `window_sec` |

### Delivery

- Asynchronous via `ngx.timer.at(0, ...)` — never blocks the request path
- Timeout: 5 s; failed deliveries log WARN (no retry)

---

## 8. Guardrail Pipeline

A two-tier content safety system that runs on every request and (for applicable detectors) on responses before they are forwarded to the client.

### Architecture

Guardrails are configured as an ordered array on each gateway. The orchestrator (`src/guardrails/orchestrator.lua`) assigns each detector to a tier, stable-sorts by tier (preserving original order within a tier), and short-circuits the chain on the first block.

```json
"guardrails": [
  {"type": "keyword", "name": "jailbreak", "action": "block", "target": "request", "keywords": ["ignore previous instructions"]},
  {"type": "prompt_guard", "name": "safety", "action": "block", "target": "request", "categories": ["S1","S3","S4","S9","S11","S12","S14"]}
]
```

### Tier 1 — In-Process (Fast)

Runs synchronously in the Lua middleware with no external dependencies.

| Detector | Method | Phase | Key config fields |
|---|---|---|---|
| `regex` | Named pattern sets + custom regex | both | `patterns` (built-in sets), `custom_patterns` (regex strings) |
| `keyword` | String search with optional whole-word matching | both | `keywords`, `case_sensitive`, `whole_word` |
| `jailbreak` | Regex + heuristic pattern matching for prompt injection | request | `sensitivity` (`low`/`medium`/`high`) |
| `json_schema` | Validates response body against a JSON Schema draft-7 spec | response | `schema` (inline JSON Schema object); strips code fences before validation |
| `contains_code` | Detects code blocks via fence markers and heuristics across 6 languages | both | `languages` (array: `python`, `javascript`, `bash`, `sql`, `html`, `css`), `min_signals` (default 2) |
| `gibberish` | Three-signal model: Shannon entropy + word repetition ratio + alpha ratio | response | `entropy_threshold` (default 2.5), `repetition_threshold` (default 0.15), `alpha_threshold` (default 0.6) |
| `language` | UTF-8 byte-range heuristics across 7 writing systems | both | `allowed` (array of script names), `blocked` (array), `min_ratio` (default 0.1) |

### Tier 2 — Sidecar HTTP (Accurate)

Calls external HTTP services. Each detector has a configurable `url`, `timeout_ms`, and `fail_open` flag.

| Detector | Default port | Description |
|---|---|---|
| `presidio` | 5002 | Microsoft Presidio NLP; detects PII entities by type with configurable score threshold |
| `prompt_guard` | 8083 | Llama Guard 3; classifies against 14 safety categories (S1–S14) |
| `pii_protector` | 5002 | Presidio-backed redaction; replaces PII with opaque tokens and restores them in the response |

### Actions

| Action | Behavior |
|---|---|
| `block` | Request or response denied; synthetic error returned to client |
| `flag` | Violation recorded in log; request continues |
| `scrub` | PII tokens replaced in-flight; original values restored in response (pii_protector only) |

### Detector Config Fields (common)

| Field | Description |
|---|---|
| `type` | Detector type: `regex`, `keyword`, `jailbreak`, `json_schema`, `contains_code`, `gibberish`, `language`, `presidio`, `prompt_guard`, `pii_protector` |
| `name` | Human-readable label (appears in block messages and logs) |
| `action` | `block`, `flag`, or `scrub` |
| `target` | `request`, `response`, or `both` |
| `fail_open` | If `true` (default), sidecar errors allow the request to pass |

### Prompt Guard Categories

Llama Guard 3 classifies against 14 safety categories. False-positive rates benchmarked on OR-Bench-hard:

| Code | Category | FP risk |
|---|---|---|
| S1 | Violent Crimes | Low |
| S2 | Non-Violent Crimes | **High** — 14.5% FP on security/education content (7.2% with `context_prompt`) |
| S3 | Sex-Related Crimes | Low |
| S4 | Child Sexual Exploitation | Low |
| S5 | Defamation | Medium |
| S6 | Specialized Advice | **High** |
| S7 | Privacy | Medium |
| S8 | Intellectual Property | Medium |
| S9 | CBRN Weapons | Low |
| S10 | Hate | Medium |
| S11 | Suicide / Self-Harm | Low |
| S12 | Sexual Content | Low |
| S13 | Elections | Medium |
| S14 | Code Interpreter Abuse | Low |

Recommended block set (all low-FP): `S1, S3, S4, S9, S11, S12, S14` — ~1.7% FP; drops to ~1.1% with `context_prompt`.

The `context_prompt` field prepends deployment context to each user message before classification, reducing false positives on professional platforms.

### Presidio Entity Config

The `presidio` and `pii_protector` detectors accept an `entities` array and a `score_threshold` (default 0.7). The built-in `pii_focused` preset covers 13 low-FP entities (EMAIL_ADDRESS, PHONE_NUMBER, US_SSN, CREDIT_CARD, US_BANK_NUMBER, IBAN_CODE, US_PASSPORT, US_DRIVER_LICENSE, US_ITIN, CRYPTO, IP_ADDRESS, MEDICAL_LICENSE, URL) and achieves 0% FP on OR-Bench-hard, XSTest-safe, and Dolly-15k.

High-FP entities (PERSON, LOCATION, DATE_TIME, NRP) have their threshold auto-raised to 0.9 by the gateway.

---

## 9. Web Search

Server-side agentic web search loop using the Brave Search API.

### Configuration

```json
"web_search": {
  "enabled": true,
  "api_key": "BSA...",
  "max_results": 5,
  "mode": "opt-in"
}
```

- `mode: "opt-in"` (default) — client must send `X-Web-Search: 1` to activate
- `mode: "always"` — applied to every request on this gateway

### Flow

1. **Leg 1** — Non-streaming buffered call with `web_search` tool injected into the request
2. **Search** — Parallel Brave API calls (non-blocking `ngx.thread.spawn`)
3. **Fetch** — Parallel HTTP fetches for top-2 result URLs; emits `data: {"aig_status":"fetching","count":N}` SSE event
4. **Leg 2** — Request updated with enriched search context; provider called again, response streamed to client

### Provider Support

Two-leg tool-use loop: Anthropic (native), OpenAI, Groq, Mistral, DeepSeek, Cerebras, Together, Fireworks, OpenRouter, xAI, Ollama.

Gemini / Vertex: native `googleSearch` grounding (single leg, no tool loop).

### Client-Side Integration

The playground UI shows a live status badge cycling through `searching → fetching N URLs → searched` and persists the final query in the panel footer.

The `X-Web-Search-Query` response header carries the query string that was searched; logged as `web_search_query`.

---

## 10. Reasoning Model Support

### Anthropic Extended Thinking

Pass `x-aig-provider-anthropic-beta: interleaved-thinking-2025-05-14` to enable extended thinking. The gateway forwards the header and normalises the SSE stream.

### OpenAI / Compat Reasoning (o-series, DeepSeek-R1)

`delta.reasoning` content is stripped from the compat stream — only `delta.content` (the final answer) is forwarded to the client.

### Ollama Think Mode

The `ollama.think` config field controls whether the `think` parameter is injected into Ollama requests.

- `false` (default) — injects `think: false`; routes the model's answer to `delta.content` rather than the reasoning channel
- `true` — enables chain-of-thought; `<think>` tag content is stripped from the visible stream
- Per-gateway override via `gateway_config.ollama.think`

### Qwen3 / DeepSeek-R1 `<think>` Block Handling

Models that embed chain-of-thought inside `<think>...</think>` tags in the response text are handled as follows:

- **Gateway streaming:** `<think>` tags are passed through verbatim in the compat SSE stream — they are visible to the client if desired
- **Auto-title generation** (Chat UI): `/no_think` prefix injected for Qwen3 models to suppress `<think>` output in the short title call; `<think>` blocks are stripped from the title response after generation
- **Chat UI rendering:** `<think>...</think>` blocks are parsed and displayed as a collapsible "Thought process" panel above the visible response (see §21)

---

## 11. Provider Key Management (BYOK)

### Encryption

- **Algorithm:** AES-256-CBC + PKCS7 via OpenSSL (`resty.aes`)
- **Key derivation:** SHA-256 of `AIG_MASTER_KEY` environment variable
- **IV:** 16-byte random per encryption operation
- **Storage format:** `base64(iv):base64(ciphertext)` stored as a single field

### Key Lookup

- Keyed by: `gateway_id + provider + alias` (default alias: `"default"`)
- Override alias per-request via `x-aig-byok-alias` header
- Decrypted keys cached in `aig_byok` shared dict for 60 seconds

### Key Management

```
POST   /admin/v1/gateways/{id}/keys
DELETE /admin/v1/gateways/{id}/keys/{provider}/{alias}
GET    /admin/v1/gateways/{id}/keys
```

```json
{
  "provider": "anthropic",
  "alias": "production",
  "key": "sk-ant-..."
}
```

---

## 12. IP Allowlist

- Configured as a list of CIDR blocks: `["10.0.0.0/8", "203.0.113.42/32"]`
- Bare IPs treated as `/32`
- Empty list = allow all (default)
- Returns `403 Forbidden` with `blocked_by="ip_allowlist"` if client IP is not matched

---

## 13. Response Streaming

- Server-Sent Events (SSE) pass-through via `text/event-stream`
- Each chunk flushed to client immediately (`ngx.flush(true)`) — no buffering
- Token usage accumulated from SSE chunks on the fly:
  - OpenAI: `delta.content` chunks, usage in final chunk
  - Anthropic: `content_block_delta`, `message_delta` (with usage), `message_stop`
  - Gemini / Vertex: candidate chunks with `usageMetadata`
- `time_to_first_token_ms` tracked from request start to first non-header data chunk
- Streaming responses are not cached

### Compat Streaming (SSE Format Normalisation)

The compat endpoint converts provider-native SSE to OpenAI `chat.completion.chunk` format so any OpenAI-compatible client works. The sequence is:

1. Role delta chunk (`delta: {role: "assistant", content: ""}`)
2. Content delta chunks as they arrive
3. Finish chunk (`finish_reason: "stop"`)
4. **Usage chunk** — emitted before `[DONE]`, following the `stream_options.include_usage` convention:
   ```json
   {"id":"...","object":"chat.completion.chunk","model":"...","usage":{"prompt_tokens":N,"completion_tokens":N,"total_tokens":N}}
   ```
   Cache token fields (`cache_creation_tokens`, `cache_read_tokens`) are included when non-zero (Anthropic prompt caching).
5. `data: [DONE]`

---

## 14. Cost Attribution & Pricing

### Pricing Sources

1. `model_price` table in the database (runtime-configurable via Admin API)
2. Hardcoded fallback defaults in `src/observability/cost_table.lua`

### Model Catalog

- `GET /admin/v1/models` — list all models with pricing (supports `?provider=` filter)
- `GET /admin/v1/model-prices` — same data via model-prices route
- `PUT /admin/v1/model-prices` — upsert a single model price
- `DELETE /admin/v1/model-prices/{provider}/{model}` — remove a price entry

### Bulk Import Scripts

| Script | Source | Description |
|---|---|---|
| `scripts/import_litellm_prices.sh` | LiteLLM price list | ~1400 models across all providers |
| `scripts/sync_openrouter_models.sh` | OpenRouter `/v1/models` API | Live pricing + context lengths for OpenRouter-aggregated models |

### Pre-loaded Models (cost_table.lua defaults)

| Provider | Models |
|---|---|
| OpenAI | gpt-4o, gpt-4o-mini, gpt-4-turbo, gpt-3.5-turbo |
| Anthropic | claude-opus-4-6, claude-sonnet-4-6, claude-haiku-4-5-20251001, claude-3-5-sonnet-20241022, claude-3-opus-20240229 |
| Gemini | gemini-1.5-pro, gemini-1.5-flash |
| Mistral | mistral-large-latest |
| Groq | llama-3.3-70b-versatile |

Anthropic prompt caching has separate per-1k prices for cache write (typically 1.25× input) and cache read (typically 0.1× input).

---

## 15. Observability & Logging

### Structured Request Logs (JSON)

Written after each request completes. Fields:

| Group | Fields |
|---|---|
| Identity | `id`, `tenant_id`, `gateway_id`, `user_id`, `token_label` |
| Routing | `provider`, `model`, `fallback_provider`, `fallback_model`, `upstream_attempts` |
| Status | `status`, `blocked`, `blocked_by`, `block_reason` |
| Cache | `cached`, `saved_cost_usd`, `saved_latency_ms` |
| Tokens | `input_tokens`, `output_tokens`, `cache_creation_tokens`, `cache_read_tokens` |
| Cost | `cost_usd` |
| Timing | `latency_ms`, `upstream_latency_ms`, `time_to_first_token_ms` |
| Request | `request_size_bytes`, `prompt` (user messages), `response` (null for streaming) |
| Guardrails | `detectors_fired` (array of names), `scrub_applied` (bool) |
| Custom | `meta` (all `x-aig-meta-*` headers) |

### Payload Logging Control

- Disable globally per gateway: `log_payloads: false`
- Disable per request: `x-aig-collect-log: false` (skip log entirely) or `x-aig-collect-log-payload: false` (log metadata only)

### Client Error Reporting

Frontend JavaScript errors are reported to `POST /admin/v1/client-errors` and stored in the `client_errors` table. Queryable via `GET /admin/v1/client-errors?limit=N`.

### SIEM Integration

Structured log events forwarded to external security and observability platforms. Configured per gateway under `siem` in gateway config. Delivery is asynchronous via `ngx.timer.at(0, ...)`.

| Backend | Protocol | Notes |
|---|---|---|
| Splunk HEC | HTTPS POST | `Authorization: Splunk <token>`; event wrapped in `{"event": ...}` |
| Elasticsearch | HTTPS POST | `/_doc` index endpoint; Basic Auth or API key |
| Vector | HTTP JSON | Compatible with Vector's HTTP source |
| Syslog/CEF | Syslog UDP/TCP | Common Event Format; `DeviceVendor=AIGateway`, `DeviceProduct=RequestLog` |

```json
"siem": {
  "type": "splunk_hec",
  "url": "https://splunk.corp.example.com:8088/services/collector",
  "token": "xxx",
  "timeout_ms": 3000,
  "fail_open": true
}
```

- `fail_open: true` (default) — SIEM delivery errors do not affect the request log
- Fields forwarded: full structured log entry (identity, routing, status, cache, tokens, cost, timing, guardrails, meta)

### OpenTelemetry Distributed Tracing

W3C `traceparent` propagation with OTLP/HTTP JSON span export. Enabled by setting `tracing.otlp_endpoint`.

**Config:**

```json
"tracing": {
  "otlp_endpoint": "http://otel-collector:4318",
  "service_name": "ai-gateway",
  "headers": {},
  "sample_rate": 1.0,
  "include_bodies": false
}
```

| Field | Default | Description |
|---|---|---|
| `otlp_endpoint` | — | OTLP/HTTP collector URL; required to enable export |
| `service_name` | `"ai-gateway"` | `service.name` resource attribute |
| `headers` | `{}` | Extra headers injected into every OTLP POST (e.g. auth) |
| `sample_rate` | `1.0` | Fraction of requests exported (0.0–1.0) |
| `include_bodies` | `false` | Include prompt/response text in span attributes |

**Span model:**

| Span | Kind | Name | Parent |
|---|---|---|---|
| Root span | SERVER (2) | `inference` | Incoming `traceparent` (if present) |
| Upstream span | CLIENT (3) | `upstream.<provider>` | Root span |

**Root span attributes (GenAI semantic conventions):**

`gen_ai.system`, `gen_ai.request.model`, `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.request.cost_usd`, `http.status_code`, `aig.tenant_id`, `aig.gateway_id`, `aig.cached`, `aig.blocked`

**Upstream span attributes:**

`gen_ai.system`, `gen_ai.request.model`, `http.status_code`, `aig.upstream_latency_ms`, `aig.upstream_attempts`, `aig.fallback_provider` (when fallback was used)

**W3C traceparent forwarding:**

Incoming `traceparent` header is parsed and propagated. If present, its `trace_id` is reused and the gateway's root span becomes a child. The `traceparent` header is also injected into every upstream provider call for end-to-end correlation.

---

## 16. Prometheus Metrics

Stored in `aig_metrics` shared dict. Exposed at `GET /metrics` (Prometheus text format 0.0.4, IP-restricted).

| Metric | Type | Labels |
|---|---|---|
| `aig_requests_total` | Counter | `provider`, `tenant_id`, `status`, `cached` |
| `aig_latency_ms` | Histogram | same |
| `aig_input_tokens_total` | Counter | same |
| `aig_output_tokens_total` | Counter | same |

---

## 17. Multi-Tenancy

### URL Structure

```
/v1/{tenant_slug}/{gateway_slug}/{provider}/chat/completions
/v1/{tenant_slug}/{gateway_slug}/compat/chat/completions
```

Slugs are resolved to UUIDs at the access phase and cached.

### Isolation

- All Redis / shared-dict keys namespaced: `{tenant_id}:{gateway_id}:...`
- Database foreign keys enforce tenant isolation
- Auth tokens are scoped to a single gateway → tenant
- Budgets and rate limits tracked per gateway, not per tenant

### Object Hierarchy

```
Tenant
├── Gateway (config JSON)
│   ├── Provider Keys (BYOK, encrypted)
│   ├── Auth Tokens
│   └── Routing Rules
├── Users (admin / member / viewer)
└── User-Gateway Access Matrix
```

---

## 18. Admin REST API

All endpoints are under `/admin/v1/`.

### Tenants & Gateways

| Method | Path | Description |
|---|---|---|
| GET | `/tenants` | List tenants |
| POST | `/tenants` | Create tenant |
| PATCH | `/tenants/{id}` | Update tenant (plan, budget) |
| DELETE | `/tenants/{id}` | Delete tenant |
| GET | `/tenants/{id}/gateways` | List gateways |
| POST | `/tenants/{id}/gateways` | Create gateway |
| GET | `/gateways/{id}` | Get gateway |
| PATCH | `/gateways/{id}` | Update gateway config |
| DELETE | `/gateways/{id}` | Delete gateway |
| DELETE | `/gateways/{id}/budget` | Reset gateway budget counter |

### Users & Tokens

| Method | Path | Description |
|---|---|---|
| GET | `/tenants/{id}/users` | List users |
| POST | `/tenants/{id}/users` | Create user |
| PATCH | `/users/{id}` | Update user |
| DELETE | `/users/{id}` | Delete user (disables tokens) |
| DELETE | `/users/{id}/budget` | Reset all token budgets for a user |
| GET | `/gateways/{id}/tokens` | List gateway tokens |
| POST | `/gateways/{id}/tokens` | Create gateway token |
| DELETE | `/gateways/{id}/tokens/{tid}` | Revoke token |
| GET | `/users/{id}/tokens` | List user tokens |
| POST | `/users/{id}/tokens` | Create user token |

### Access Control & Keys

| Method | Path | Description |
|---|---|---|
| GET | `/users/{id}/gateways` | List gateways user has access to |
| POST | `/users/{id}/gateways/{gw_id}` | Grant user gateway access |
| DELETE | `/users/{id}/gateways/{gw_id}` | Revoke user gateway access |
| GET | `/gateways/{id}/keys` | List provider key configs |
| POST | `/gateways/{id}/keys` | Store encrypted provider key |
| DELETE | `/gateways/{id}/keys/{provider}/{alias}` | Delete provider key |

### Routing Rules

| Method | Path | Description |
|---|---|---|
| GET | `/gateways/{id}/rules` | List routing rules |
| POST | `/gateways/{id}/rules` | Create routing rule |
| PATCH | `/gateways/{id}/rules/{rule_id}` | Update routing rule |
| DELETE | `/gateways/{id}/rules/{rule_id}` | Delete routing rule |

### Model Catalog & Pricing

| Method | Path | Description |
|---|---|---|
| GET | `/models` | List model catalog (supports `?provider=` filter) |
| GET | `/model-prices` | List all model prices |
| PUT | `/model-prices` | Upsert a model price |
| DELETE | `/model-prices/{provider}/{model}` | Delete a model price |

### Analytics

| Method | Path | Description |
|---|---|---|
| GET | `/stats` | Aggregated usage statistics (last_min, hour, today, yesterday, last_7d; recent requests) |
| GET | `/stats/timeseries` | Time-bucketed request/cost/blocked counts (params: `bucket` 5m/15m/30m/1h/6h/1d, `n` 1–168, `until` unix seconds, `tenant_id`) |
| GET | `/stats/analytics` | Latency percentiles (p50/p95/p99), top models by volume, and usage by tenant — all scoped to `?since=<unix_ms>` (default: last 24 h) |
| GET | `/tenants/{id}/analytics` | Per-tenant timeseries + top models for the analytics drilldown page |
| GET | `/logs` | Query request logs (filters: `tenant_id`, `gateway_id`, `provider`, `since`, `limit`, `offset`) |

### Playground

| Method | Path | Description |
|---|---|---|
| POST | `/playground/token` | Issue a short-lived (10-min) gateway token for the playground UI |
| GET | `/playground/search?q=` | Web search proxy (Brave Search API) |

### Chat Console

| Method | Path | Description |
|---|---|---|
| GET | `/conversations` | List conversations (all visible to the requesting user) |
| POST | `/conversations` | Create conversation (gateway_id, model, system_prompt, temperature, max_tokens) |
| GET | `/conversations/{id}` | Get conversation with all messages |
| PATCH | `/conversations/{id}` | Update title / model / settings |
| DELETE | `/conversations/{id}` | Delete conversation and all messages |
| POST | `/conversations/{id}/messages` | Append a message (role, content, tokens, cost, latency) |
| PATCH | `/conversations/{id}/messages/{mid}` | Edit message content |
| DELETE | `/conversations/{id}/messages/{mid}` | Delete a message |
| POST | `/conversations/{id}/attachments` | Upload attachment (base64, stored in DB) |
| GET | `/chat-presets` | List saved chat presets |
| POST | `/chat-presets` | Create preset (name, model, system_prompt, temperature, max_tokens) |
| PATCH | `/chat-presets/{id}` | Update preset |
| DELETE | `/chat-presets/{id}` | Delete preset |
| POST | `/chat/files` | Extract text from uploaded file (DOCX, PDF, image via MinerU/OCR; spreadsheet via Files API) |
| POST | `/chat/export-pdf` | Render conversation markdown as PDF; returns binary `application/pdf` |
| POST | `/auth/otp/request` | Request OTP email for email-code login |
| POST | `/auth/otp/verify` | Verify OTP, issue session cookie |
| POST | `/auth/logout` | Clear session |

### Client Error Reporting

| Method | Path | Description |
|---|---|---|
| POST | `/client-errors` | Report a frontend JavaScript error |
| GET | `/client-errors` | List recent client errors (supports `?limit=`) |

---

## 19. Dashboard UI

The Dashboard page displays real-time and historical gateway metrics as hero cards with sparklines.

### Hero Cards

Three top-level metric cards are always visible:

| Card | Metric | Sub-label |
|---|---|---|
| Requests | Total request count | Cache hit rate (%) |
| Cost | Total cost in USD | Savings via cache |
| Guardrail Hits | blocked + scrubbed + flagged total | Individual breakdown (N blocked · N scrubbed · N flagged) |

Each card contains an inline SVG sparkline showing the trend over the selected timeframe.

### Timeframe Switcher

A tab bar above the hero cards selects the reporting period. The selection applies to **all** dashboard sections: hero cards, Top Models, and Usage by Tenant.

| Tab | Period | Chart granularity |
|---|---|---|
| Today | Since UTC midnight | 1 h buckets × hours elapsed today |
| Yesterday | Previous UTC day | 1 h buckets × 24 |
| Last 7 days | Rolling 7 days | 1 d buckets × 7 |
| Last hour | Rolling 60 minutes | 5 m buckets × 12 |
| Last minute | Rolling 60 seconds | 5 m buckets × 12 |

### Top Models

Shows the top 10 models by request volume for the selected timeframe, with provider, requests, cost, and average latency. Sourced from `/stats/analytics?since=<unix_ms>`. Only rendered when data is non-empty.

### Usage by Tenant

Shows all tenants with their request count, token consumption, and cost for the selected timeframe. Sourced from `/stats/analytics?since=<unix_ms>`. Only rendered when data is non-empty.

### Data Fetching

On mount, period stats and timeseries data are loaded in a single `Promise.allSettled` batch — the dashboard always renders with whatever data arrived and never shows an error page. On each timeframe change, `/stats/analytics` is re-fetched with the matching `since` timestamp to update the Top Models and Usage by Tenant tables. Missing or failed fetches fall back to zero values or hidden sections silently.

---

## 20. Playground UI

A React single-page app (`frontend/`) for interactive model testing and comparison.

### Multi-Model Comparison

- Add up to 4 model panels side-by-side
- All active panels receive the same prompt simultaneously
- Each panel can select a different gateway + model independently

### Request Configuration

- System prompt — always visible; pre-filled with a sensible default; a "restore default" link appears when the prompt has been modified
- Temperature slider (0–2, default 1)
- Max tokens input (default 2048)
- Web search toggle — injects `X-Web-Search: 1`; only shown when the active gateway has `web_search.enabled: true` and the selected model supports tool use

### Streaming

- Responses stream in real-time via SSE
- Markdown rendered as formatted output (headers, code blocks, tables, lists)

### Real-Time Status Bar

Each panel shows a live metrics footer that updates as the response streams:

| Metric | Description |
|---|---|
| Elapsed / Latency | Live ms counter while loading; final ms when complete |
| Input tokens | Prompt token count (from usage SSE chunk) |
| Output tokens | Completion token count |
| Cache write | Anthropic prompt cache write tokens (shown when > 0) |
| Cache read | Anthropic prompt cache read tokens (shown when > 0) |
| Cost | Estimated cost in USD (calculated from model price catalog) |
| Web search badge | Shows `searching → fetching N URLs → searched` status during search; final query persists in footer |

### Debug Log

A collapsible append-only debug trace panel records every input, computed value, and SSE event for the active session. Entries include wall-clock timestamps and a dot-namespaced event identifier (e.g. `run.start`, `panel.sse_chunk`). Maximum 5,000 entries retained.

### Error Display

Structured error badges with contextual hints:

| Badge | HTTP | Hint |
|---|---|---|
| AUTH ERROR | 401 | Check token is valid and not expired |
| FORBIDDEN | 403 | Check user role and gateway access |
| NOT FOUND | 404 | Check tenant/gateway slugs |
| RATE LIMITED | 429 | Request exceeds gateway rate limit or quota |
| SERVER ERROR | 500/502/5xx | Provider or gateway internal error |

Network errors (DNS, connection refused) shown as "Network error — is the gateway running?"

### State Persistence

Playground state is saved to `localStorage` (key: `aig_playground_v1`) across page reloads:

- Selected tenant, gateway
- Active model panels (model IDs only)
- System prompt text
- Temperature, max tokens

Stale IDs (deleted tenant/gateway/model) are validated against loaded data and silently discarded.

### Authentication

The admin UI issues a short-lived (10-minute) playground token per-gateway via `POST /admin/v1/playground/token`. This token is used to authenticate SSE requests to the compat endpoint during the playground session.

---

## 21. Chat Console UI

A full-featured conversational AI interface built into the admin React SPA (`/chat`). Separate from the multi-model Playground; designed for sustained multi-turn conversations with persistent history.

### Conversation Management

- Sidebar lists all conversations with title, date, and rename-in-place
- Search / filter by title
- Create new conversation (preserves tenant/gateway/model selection across sessions via `localStorage`)
- Delete conversation (with confirmation)
- Each conversation stores: model, system prompt, temperature, max tokens, gateway

### Configuration Bar

- Tenant selector — scoped to accessible tenants
- Gateway selector — updates available models
- Model picker with provider-aware grouping and runnability indicators
- **Preset mode** — when a tenant has named presets (`chat_presets`), the gateway/model dropdowns are replaced by preset buttons; preset applies a full configuration (gateway, model, system prompt, temperature, max tokens) with one click
- Web search toggle (🌐 icon) — sends `X-Web-Search: 1` on the next request
- Export buttons: PDF (server-side WeasyPrint) and Markdown (client-side download)
- Settings gear — opens settings drawer

### Settings Drawer

- System prompt (textarea, multi-line; default includes: date, formatting rules, decision table emoji conventions, enumerated list emoji guidance)
- Temperature slider
- Max tokens input
- Preset save / load / delete (user-level, shared across conversations)

### Message Rendering

- **Markdown** — GitHub Flavoured Markdown via `react-markdown` with:
  - GFM tables, task lists, strikethrough
  - KaTeX math (`$inline$` and `$$display$$`)
  - Code blocks with syntax highlighting (highlight.js, `github-dark-dimmed` theme), language label, and per-block Copy button
  - Emoji shortcodes (`:dog:` etc.)
- **Thinking blocks** — `<think>...</think>` content from reasoning models (Qwen3, DeepSeek-R1) is parsed and displayed as a collapsible "Thought process" panel:
  - Shown above the visible response
  - While streaming: open by default with a spinner and "Thinking…" label
  - After completion: auto-collapses; duration badge shows elapsed time (e.g. `4.2s`)
  - User can expand/collapse independently
- **Artifact panel** — when a response contains an `html` or `svg` fenced code block ≥ 8 lines, a live preview panel opens to the right of the thread:
  - HTML rendered in a sandboxed `<iframe sandbox="allow-scripts">` (no external network access)
  - SVG wrapped in minimal HTML and rendered the same way
  - During streaming: shows "Generating…" spinner until the closing fence arrives
  - Popout button opens the rendered result in a new browser tab
  - Dismiss button removes the panel for the current message
- **Streaming cursor** — animated blinking cursor at end of in-progress stream
- **Message metadata** — input tokens, output tokens, cost (USD), latency shown below each assistant message
- **Copy / Edit / Regenerate** actions — appear on hover:
  - Copy: copies full message text to clipboard
  - Edit (user messages): inline textarea with Save/Cancel
  - Regenerate (last assistant message): deletes last assistant response, re-runs inference

### File Attachments

Attached via paperclip button or drag-and-drop. Supported formats:

| Format | Handling |
|---|---|
| Images (JPEG, PNG, GIF, WebP) | Sent as `image_url` blocks for vision-capable models; OCR via MinerU for text-only models |
| PDF | Anthropic native document block (Claude); MinerU text extraction for others |
| Plain text (`.txt`) | Anthropic native document block |
| **Markdown (`.md`)** | Decoded in-browser (base64 → UTF-8); injected as text block `[Document: filename]\n\ncontent`; shown as chip |
| Word (`.docx`) | Server-side text extraction via `/chat/files`; content injected as text block; shown as chip |
| CSV / TSV | Server-side file upload via Files API; sent as `document` with file reference |
| Excel (`.xlsx`, `.xlsm`) | Same as CSV |
| OpenDocument (`.ods`) | Same as CSV |

- Attachments shown as chips in the input bar and in the sent user bubble (filename only, no content dump)
- Drop zone overlay with label "Images · PDF · DOCX · XLSX · ODS · CSV · TXT · MD"

### Input Box

- Auto-growing textarea (44 px min, 200 px max)
- `spellCheck=false`, `autoCorrect=off`, `autoCapitalize=off` — prevents mobile IME language-detection interference when typing in a non-keyboard-default language
- Enter to send (Shift+Enter for newline)
- Send / Stop button (stop aborts the active stream and saves partial content)

### Auto-Title Generation

After the first exchange in a new conversation, a non-blocking background request generates a 3–6 word title:

- Uses the same model as the conversation (no separate model required)
- Qwen3 models: `/no_think` prefix injected into the system prompt to suppress `<think>` output
- `<think>` blocks stripped from title response
- Surrounding quotes and trailing punctuation stripped
- 90-second timeout to handle slow local vLLM models

### Auto-Continue

If the model returns `finish_reason: "max_tokens"`, the chat automatically continues with `"Continue"` injected as the next user message, up to 10 times. Accumulated content is stitched together into a single assistant message.

### Export

- **Markdown** — full conversation rendered as `# Title\n\n**You**\n\n...\n\n**Claude**\n\n...`; downloaded as `{slug}-{date}.md`
- **PDF** — Markdown sent to `POST /chat/export-pdf` (WeasyPrint, server-side); downloaded as `{slug}-{date}.pdf`

---

## 22. Gateway Configuration Reference

```json
{
  "cache_ttl": 0,
  "retry_count": 2,
  "timeout_ms": 60000,
  "log_payloads": true,
  "auth_required": true,
  "budget_usd": null,
  "rate_limit": {"requests": 100, "window_sec": 60},
  "circuit_breaker": {
    "enabled": false,
    "failure_threshold": 5,
    "window_sec": 60,
    "cooldown_ms": 30000,
    "failure_status_codes": [500, 502, 503, 504]
  },
  "ip_allowlist": [],
  "guardrails": [],
  "web_search": {
    "enabled": false,
    "api_key": null,
    "max_results": 5,
    "mode": "opt-in"
  },
  "ollama": {"think": false},
  "semantic_cache": {
    "enabled": false,
    "threshold": 0.95,
    "embedding_url": null,
    "embedding_api_key": null,
    "embedding_model": null,
    "max_candidates": 100,
    "ttl": 86400
  },
  "siem": null,
  "tracing": {
    "otlp_endpoint": null,
    "service_name": "ai-gateway",
    "headers": {},
    "sample_rate": 1.0,
    "include_bodies": false
  },
  "azure_endpoint": null,
  "azure_deployment": null,
  "azure_api_version": "2024-02-01",
  "bedrock_region": "us-east-1",
  "vertex_project": null,
  "vertex_region": "us-central1",
  "provider_base_urls": {}
}
```

### Per-Request Header Overrides

| Header | Effect |
|---|---|
| `x-aig-byok-alias` | Select a named provider key |
| `x-aig-meta-*` | Attach custom metadata (available in routing conditions and logs) |
| `x-aig-collect-log` | `false` = skip request log entirely |
| `x-aig-collect-log-payload` | `false` = log metadata but omit prompt/response body |
| `x-aig-provider-*` | Forwarded as raw headers to provider |
| `X-Web-Search` | `1` = activate web search for this request (when `mode: "opt-in"`) |

---

## 23. Error Handling

All errors return a JSON body:

```json
{"error": {"code": "error_code", "message": "Human-readable detail"}}
```

| Code | HTTP | Cause |
|---|---|---|
| `unauthorized` | 401 | Missing or invalid token |
| `forbidden` | 403 | Viewer role, or IP not in allowlist |
| `tenant_not_found` | 404 | Unknown tenant or gateway slug |
| `invalid_request` | 400 | Malformed request or missing required fields |
| `rate_limited` | 429 | Sliding-window limit exceeded |
| `quota_exceeded` | 429 | Budget cap reached |
| `guardrail_blocked` | 400 | Guardrail pipeline blocked the request |
| `provider_error` | 502 | Upstream provider returned 5xx |
| `all_providers_failed` | 502 | All retry and fallback attempts exhausted |
| `internal` | 500 | Gateway internal error |
