# AI Gateway — Feature Reference

**Stack:** OpenResty (LuaJIT)
**Pattern:** Multi-tenant reverse proxy with a middleware chain across three Nginx phases (access → content → log)
**Storage:** MySQL 8.0+ / MariaDB
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
   - [7a. Webhooks](#7a-webhooks)
8. [Guardrail Pipeline](#8-guardrail-pipeline)
9. [Web Search](#9-web-search)
   - [9a. URL Fetch](#9a-url-fetch)
   - [9b. Server-Side Tool Loop](#9b-server-side-tool-loop-tool_loop-middleware)
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
    - [19a. Other Admin UI Pages](#19a-other-admin-ui-pages)
20. [Playground UI](#20-playground-ui)
21. [Chat Console UI](#21-chat-console-ui)
    - [21b. Memory System](#21b-memory-system)
22. [Gateway Configuration Reference](#22-gateway-configuration-reference)
23. [Error Handling](#23-error-handling)
24. [Development Cost Estimation](#24-development-cost-estimation)

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
6. `tool_loop` — Server-side tool orchestration: injects read_file, write_file, fetch_url, web_search, and MCP tools; sets `ctx.tool_loop_active`; the actual execution happens inside `upstream` after each streaming leg
7. `upstream` — Call provider with retry + fallback; runs the multi-leg streaming tool loop when `ctx.tool_loop_active` is set
9. `guardrails_response` — Guardrail pipeline scan on response
10. `send_response` — Write buffered response body to client (re-emits as SSE when `ctx.buffered_needs_sse_reemit` is set — see §9)
11. `cost` — Token counting and budget increment
12. `cache_store` — Persist non-streaming 200 responses

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
| vLLM | OpenAI-compatible | None (optional) | Local/self-hosted vLLM server; `vllm/` prefix stripped; per-model port overrides; `provider_base_urls.vllm` config |

### Endpoints

- **Native:** `/v1/{tenant}/{gateway}/{provider}/chat/completions`
- **Unified (OpenAI-compat):** `/v1/{tenant}/{gateway}/compat/chat/completions` — provider inferred from model name
- **vLLM native:** `/v1/{tenant}/{gateway}/vllm/chat/completions` — direct vLLM local server routing

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

Recognised prefixes (17 providers, 19 distinct prefix strings): `gemini/`, `vertex_ai/`, `azure_ai/`, `azure/`, `groq/`, `text-completion-codestral/`, `mistral/`, `together_ai/`, `fireworks_ai/`, `nvidia_nim/`, `sambanova/`, `deepseek/`, `xai/`, `perplexity/`, `cerebras/`, `cohere/`, `bedrock/`, `openrouter/`, `ollama/`. (Azure and Mistral each accept two prefixes.)

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

**Storage:** `semantic_cache` table in MySQL, indexed by `(gateway_id, model, created_at DESC)`.

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

### Sidecar Outage Handling

When a Tier 2 sidecar is unreachable (DNS failure, connection refused, timeout, non-2xx HTTP), the orchestrator classifies the error and handles it uniformly across detectors:

| Classification | Trigger pattern in error message |
|---|---|
| `dns` | "could not be resolved" / "no such host" / "name resolution" |
| `connect_refused` | "connection refused" |
| `timeout` | "timeout" / "timed out" |
| `connection_closed` | "broken pipe" / "closed" |
| `http_<code>` | Non-2xx response |
| `parse` | Malformed JSON body |
| `transport` | Anything else |

A single structured line is written at **`ngx.ERR`** level per outage:

```
[guardrail_unavailable] name=pii-protect type=pii_protector stage=analyzer
error_class=dns url=http://presidio:3000 tenant=<id> gateway=<id>
fail_open=true message=analyzer request: connect: presidio could not be resolved
```

The same information is persisted on the request log:

- `log_fields.guardrail_error` = `{name, type, stage, url, error_class, message}` → surfaces in `request_log.meta.guardrail_error`
- `log_fields.guardrail_degraded = true` → set on the fail_open pass-through path so admins can count degraded requests without tailing nginx
- `log_fields.guardrail_verdict = "error"`

**Client-visible behaviour:**

- `fail_open = true` (default) — response carries header `X-Aig-Guardrail-Warning: <name> unavailable (<error_class>); request processed without this guardrail`. The request is processed upstream as usual.
- `fail_open = false` — the synthetic 200 response body says *"The safety guardrail '<name>' is temporarily unavailable and the request has been rejected because this gateway is configured to fail closed. Please retry in a few moments."* — distinct from a content-policy block so users don't misdiagnose an outage as a policy denial.

CORS note: the `X-Aig-Guardrail-Warning` header is listed in `Access-Control-Expose-Headers` on the `/v1/` location so browsers can read it cross-origin.

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

Server-side agentic web search using the Brave Search API, now implemented entirely inside the `tool_loop` middleware (see §1, §9b).

### Configuration

```json
"web_search": {
  "enabled": true,
  "api_key": "BSA...",
  "max_results": 5,
  "mode": "opt-in"
}
```

Configured per-gateway in the Gateway settings UI (Web Search section: enable toggle, Brave API key field, max results input).

- `mode: "opt-in"` (default) — client must send `X-AIG-Web-Search: 1` to activate
- `mode: "always"` — applied to every request on this gateway
- **Chat UI** — always sends `X-AIG-Web-Search: 1` on every message (no toggle needed; web search activates if the gateway has it configured)

### Flow (via tool_loop / upstream streaming loop)

1. `tool_loop` injects a `web_search` tool definition and sets `ctx.tool_loop_active = true`
2. **Leg 1** — Provider streamed; if model emits `finish_reason: "tool_calls"` for `web_search`, the streaming loop pauses `[DONE]`
3. **Execute** — `execute_web_search()` runs: parallel Brave API call + parallel HTTP fetch for top-2 result URLs
4. Emits status events: `data: {"aig_status":"tool_call","tool":"web_search"}` and `data: {"aig_status":"tool_result",...}`
5. **Leg 2** — Enriched results injected into messages; provider called again; final answer streamed to client
6. `[DONE]` emitted after all legs complete

### Provider Support

Tool-use loop: Anthropic (native), OpenAI, Groq, Mistral, DeepSeek, Cerebras, Together, Fireworks, OpenRouter, xAI, Ollama, **vLLM** (including Qwen3 and other self-hosted models via OpenAI-compatible SSE tool_calls extraction).

Gemini / Vertex: native `googleSearch` grounding (single leg, no tool loop).

### Client-Side Integration

- **Playground UI** — shows a live status badge cycling through `searching → fetching N URLs → searched`; the final query persists in the panel footer.
- **Chat UI** — reads `aig_status: "tool_call"` / `aig_status: "tool_result"` SSE events and displays `🔎 Searching…` / `🔗 Fetching…` in the processing-status area (automatically cleared on first response token).

The `X-Web-Search-Query` response header carries the query string that was searched; logged as `web_search_query`.

### Streaming Clients (Direct-Answer SSE Re-Emit)

Leg 1 is always a buffered (non-streaming) upstream call — it has to complete before the gateway can decide whether to run Leg 2. If the model answers directly (no `web_search` tool call) and the client had sent `stream: true` on a `/compat/` endpoint, the response is still repackaged as SSE so the client sees what it asked for:

- `web_search.lua` sets `ctx.buffered_needs_sse_reemit = true` alongside `ctx.web_search_done = true` when `orig_stream && ctx.is_compat`.
- `send_response.lua` then calls `reemit_as_sse(ctx.response_body)` which parses the buffered OpenAI `chat.completion` JSON and emits it as four `chat.completion.chunk` events (role delta → content delta → usage → stop) followed by `data: [DONE]`.
- The `Content-Type` is overridden from `application/json` back to `text/event-stream`.

Same flow is applied by `url_fetch.lua` and `pii_protector.lua` (which also buffers streaming compat requests so it can restore PII tokens in the response before the client sees them). The `buffered_needs_sse_reemit` flag is the single generic signal that triggers the SSE repackaging; `pii_force_buffered` remains as the "force upstream to non-stream" signal read by `upstream.lua`.

Without this, a streaming client that hits a gateway where any buffering middleware runs would receive a valid 200 response with `Content-Type: application/json` — the SSE parser would skip every line and the stream would close with zero content. Observed as `[stream_truncated] SSE stream body closed without [DONE] token {accumulatedChars: 0, elapsedMs: 0}` in the browser.

---

## 9a. URL Fetch

A two-leg tool-use loop that lets the model ask the gateway to fetch a user-supplied URL. Runs in addition to (and skips if) `web_search`.

### Architecture

Mirrors §9: Leg 1 is a non-streaming buffered call with the `fetch_url` tool injected; if the model emits a `fetch_url` tool call, the gateway performs the HTTP GET server-side via `utils/fetch_url` (with an SSRF guard — private/link-local/loopback ranges blocked), then the enriched context goes to Leg 2 which streams back to the client.

### Configuration

Enabled unconditionally for Anthropic and every OpenAI-format provider in its allow-list (openai, groq, mistral, deepseek, cerebras, together, fireworks, openrouter, xai, ollama, huggingface, sambanova, nvidia, azure, cloudflare, cohere). Gemini and Vertex are skipped (no standard tool-use loop; Gemini uses native grounding instead).

### Tool definitions

- **Anthropic tool name:** `fetch_url`; input schema requires `url` (string) and optional `purpose` (string)
- **OpenAI-format tool:** same shape, emitted as a `function` tool

### Status events

During the fetch phase a custom SSE event is emitted for client UIs to show a status badge: `data: {"aig_status":"fetching_url","count":N}`. The Chat UI maps this to `🔗 Fetching N URL(s)…`.

### Streaming clients

Same `buffered_needs_sse_reemit` pathway as web_search (§9). Leg 1 is always buffered; if the model answers directly (no tool call) the buffered JSON is re-emitted as SSE `chat.completion.chunk` events so a streaming client still gets a valid SSE response.

### Skip conditions

- `ctx.web_search_done` or `ctx.web_search_leg2` being set — web search already did a two-leg loop for this request.
- **URL guard** — Leg 1 is only activated when the *last real user message* contains an `http://` or `https://` URL. The middleware walks backwards through the message list, skipping injected context messages (those starting with `## File:` or `Continue`). This prevents project knowledge files that contain URLs from spuriously triggering a fetch loop.

### SSRF guard

`utils/fetch_url` refuses to fetch URLs that resolve to loopback (127.0.0.0/8, ::1), link-local (169.254.0.0/16, fe80::/10), private ranges (10/8, 172.16/12, 192.168/16, fc00::/7), or the metadata service (169.254.169.254). Non-`http`/`https` schemes rejected. Response size capped.

---

## 9b. Server-Side Tool Loop (`tool_loop` middleware)

A unified server-side tool orchestration layer that replaced the earlier separate `web_search` and `url_fetch` middleware. Implements the same multi-step "runTools / maxSteps" pattern as OpenAI's Assistants API and Vercel AI SDK.

### Architecture

The `tool_loop` middleware runs in the content phase **before** `upstream`. It:

1. Determines which tools to inject based on request context:
   - `read_file` + `write_file` — when `X-Project-Id` header is present (project context)
   - `fetch_url` — when the last user message contains an `http://https://` URL
   - `web_search` — when the gateway has `web_search.enabled: true` and the request activates it (`mode: always` or `X-AIG-Web-Search: 1`)
   - MCP tools — from `X-MCP-Tools` header (JSON array of tool definitions with `connector_id`)
2. Injects tool definitions into `ctx.request_body.tools` (Anthropic format for Anthropic provider; OpenAI function format for all others)
3. Sets `ctx.tool_loop_active = true`

The actual multi-leg execution happens inside `upstream.lua`'s `handle_compat_streaming`:

- **Streaming tool loop** — after Leg 1 streaming ends with `finish_reason: "tool_calls"` and `pending_tool_calls` are accumulated, the loop executes each tool server-side, emits status/result SSE events, injects results into the message history, and makes the next provider call — all on the same HTTP response (no disconnect between legs)
- **Buffered tool loop** — for the PII-force-buffered path (non-streaming), an equivalent multi-leg loop runs sequentially with non-streaming provider calls, then the final response is re-emitted as SSE by `send_response.lua`
- **Max rounds** — 10 (prevents infinite tool loops)

### Supported Tools

| Tool | Activated when | Executor |
|---|---|---|
| `read_file` | `X-Project-Id` present | `storage.get_project_knowledge_text(project_id)` |
| `write_file` | `X-Project-Id` present | `storage.upsert_project_knowledge(...)` |
| `fetch_url` | URL in last user message | `utils/fetch_url` with SSRF guard |
| `web_search` | Gateway configured + header/mode | Brave Search API + parallel URL fetch |
| MCP tools | `X-MCP-Tools` header | Proxy to `/admin/v1/mcp/{id}/call` |

### OpenAI-Format Tool Call Streaming

The `openai.parse_sse_chunk` parser was extended to extract `tool_calls` from streaming `delta.tool_calls` chunks:

- First chunk for a tool call: `function.name` and `tc.id` → `parsed.tool_name` + `parsed.tool_id`
- Subsequent chunks: `function.arguments` fragments → `parsed.tool_input_delta`

This enables the streaming tool loop for all OpenAI-compatible providers including **vLLM**, Groq, Mistral, DeepSeek, and any other provider using the OpenAI streaming format.

### Supported Providers (tool loop)

Anthropic (native `tool_use`), OpenAI, Groq, Mistral, DeepSeek, Cerebras, Together, Fireworks, OpenRouter, xAI, Ollama, HuggingFace, SambaNova, NVIDIA, Azure, Cloudflare, Cohere, **vLLM** (including Qwen3 and other self-hosted models).

### PII + Tool Use

When the PII protector forces buffered mode (`pii_force_buffered = true`), the streaming tool loop is unavailable. A dedicated **buffered tool loop** in `upstream.lua` handles this path:

1. Non-streaming Leg 1 call → parse response for tool calls
2. Execute tools, inject results into message history
3. Non-streaming Leg 2 call → repeat until no tool calls
4. Final response set in `ctx.response_body`; `send_response.lua` re-emits as SSE

This ensures web search, file reads/writes, and URL fetch all work correctly when the PII protector is active.

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
- **Production note:** CBC is unauthenticated. `src/utils/crypto.lua` flags that production deployments should migrate to AES-256-GCM via `luaossl` or to a KMS-backed key service; the CBC implementation is acceptable for dev/test and single-tenant deployments where the MySQL instance is not shared with other applications.

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

### `finish_reason` Normalisation

Anthropic `stop_reason` values are translated to OpenAI `finish_reason` in the compat stream:

| Anthropic `stop_reason` | OpenAI `finish_reason` |
|---|---|
| `end_turn` | `stop` |
| `max_tokens` | `length` |
| `stop_sequence` | `stop` |
| `tool_use` | `tool_calls` |

This ensures clients that branch on `finish_reason: "length"` (to detect truncated responses) behave correctly with Anthropic models.

### Tool-Calls Forwarding

When the Anthropic stream ends with `stop_reason: "tool_use"`, the gateway forwards the tool call(s) to the client in OpenAI `tool_calls` delta format before emitting the finish chunk:

1. During streaming, `content_block_start` events with `content_block.type == "tool_use"` are captured: `tool_id`, `tool_name`, and `input_json_delta` fragments are accumulated
2. On stream end, a single SSE chunk is emitted with `delta.tool_calls` containing all accumulated calls in OpenAI format (`index`, `id`, `type: "function"`, `function.name`, `function.arguments`)
3. The finish chunk is emitted with `finish_reason: "tool_calls"`

This allows the Chat UI to dispatch MCP tool calls, `read_file`, and other native tool uses from Anthropic models using the same `pendingToolCalls` path as OpenAI tool calls.

### Token Count Injection for Local / OpenAI-Compat Providers

For providers that do not return token usage in their streaming responses by default (Ollama, Qwen-via-Together, any OpenAI-compat endpoint that omits usage), the gateway injects `stream_options: {"include_usage": true}` into the outgoing request body. This enables the usage chunk that is otherwise absent, ensuring token counts and costs are always recorded in the request log.

### Tool-Use Activity Events

When Claude (or any Anthropic-native model) begins executing a tool call during streaming, the gateway emits a custom SSE event before the tool output arrives:

```
data: {"aig_tool_call": "web_search"}
```

The `aig_tool_call` value is the tool name from the Anthropic `content_block_start` event (e.g. `web_search`, `computer_use`, `code_execution`). The Chat UI (§21) maps these to human-readable status labels displayed in the processing-status area.

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

### Automated Model Sync

`src/admin/model_sync.lua` runs a daily `ngx.timer` (started from worker 0 at init) that fetches the official model list from each provider's `/v1/models` endpoint and upserts into `model_price` with pricing inferred from a pattern table.

- **Providers polled:** anthropic, openai, mistral, groq, deepseek, xai, together, fireworks, perplexity, openrouter
- **Auth:** each provider uses its own auth scheme (`Authorization: Bearer <key>` for most; Anthropic uses `x-api-key` + `anthropic-version` header). Keys are sourced from the `provider_config` table or env-var fallbacks.
- **Pricing inference:** ~30 ordered pattern tiers per provider — first match wins. Examples: `^claude%-opus%-4%-[56]` → `$0.005/$0.025 per 1k`; `^claude%-sonnet%-4` → `$0.003/$0.015`; `^gpt%-5%-mini` → `$0.00025/$0.002`. Models that don't match any pattern get a conservative default tier.
- **Manual trigger:** `POST /admin/v1/model-prices/sync` runs the sync once on demand (admin only).
- **Outcome:** operators don't have to hand-curate pricing for new models — they appear in the catalog within 24 h of provider release at the correct tier.

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
| Guardrails | `detectors_fired` (array of names), `scrub_applied` (bool), `guardrail_verdict` (`safe` / `unsafe` / `error`), `guardrail_latency_ms` |
| Guardrail outage | `meta.guardrail_error` (`{name, type, stage, url, error_class, message}` — sidecar unreachable), `meta.guardrail_degraded` (fail_open kept the request alive despite outage) |
| Custom | `meta` (all `x-aig-meta-*` headers, plus guardrail outage fields above) |

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
│   ├── User-Gateway Access Matrix
│   ├── Chat Commands (personal slash commands)
│   └── Memories (personalisation facts)
└── Projects
    ├── Project Members (owner / editor / viewer)
    ├── Knowledge Items (text + optional binary blob)
    └── Conversations
        ├── Messages
        └── Attachments
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
| GET | `/users` | List all users (admin only) |
| GET | `/tenants/{id}/users` | List users scoped to a tenant |
| POST | `/tenants/{id}/users` | Create user |
| GET | `/users/{id}` | Get user |
| PATCH | `/users/{id}` | Update user |
| DELETE | `/users/{id}` | Delete user (disables tokens) |
| POST | `/users/{id}/resend-invite` | Re-send invitation email |
| DELETE | `/users/{id}/budget` | Reset all token budgets for a user |
| GET | `/gateways/{id}/tokens` | List gateway tokens |
| POST | `/gateways/{id}/tokens` | Create gateway token |
| DELETE | `/gateways/{id}/tokens/{tid}` | Revoke token |
| GET | `/users/{id}/tokens` | List user tokens |
| POST | `/users/{id}/tokens` | Create user token |
| GET | `/me/tokens` | List caller's own tokens |
| POST | `/me/tokens` | Create a token for the caller |
| DELETE | `/me/tokens/{token_id}` | Revoke one of the caller's tokens |

### Access Control & Keys

| Method | Path | Description |
|---|---|---|
| GET | `/gateways/{id}/keys` | List provider key configs |
| POST | `/gateways/{id}/keys` | Store encrypted provider key |
| DELETE | `/gateways/{id}/keys/{provider}/{alias}` | Delete provider key |

### Gateway Status & Monitoring

| Method | Path | Description |
|---|---|---|
| GET | `/gateways/{id}/circuit-breaker` | Circuit breaker state per provider |
| GET | `/gateways/{id}/guardrail-stats` | Aggregated guardrail hit counts |
| GET | `/gateways/{id}/guardrail-events` | Recent per-request guardrail events |
| GET | `/gateways/{id}/spend` | Current spend for this gateway |
| GET | `/gateways/{id}/traces` | List traces for this gateway |
| GET | `/tenants/{id}/spend` | Current spend for this tenant |
| GET | `/traces/{id}` | Get full trace with steps |
| GET | `/providers` | List all provider configurations |
| GET | `/audit-log` | Query the audit log (admin only) |

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
| POST | `/model-prices/sync` | Trigger a manual model sync from provider `/v1/models` endpoints (see §14) |

### Analytics

| Method | Path | Description |
|---|---|---|
| GET | `/stats` | Aggregated usage statistics (last_min, hour, today, yesterday, last_7d; recent requests) |
| GET | `/stats/timeseries` | Time-bucketed request/cost/blocked counts (params: `bucket` 5m/15m/30m/1h/6h/1d, `n` 1–168, `until` unix seconds, `tenant_id`) |
| GET | `/stats/analytics` | Latency percentiles (p50/p95/p99), top models by volume, and usage by tenant — all scoped to `?since=<unix_ms>` (default: last 24 h) |
| GET | `/tenants/{id}/analytics` | Per-tenant timeseries + top models for the analytics drilldown page |
| GET | `/logs` | Query request logs (filters: `tenant_id`, `gateway_id`, `provider`, `since`, `limit`, `offset`) |
| GET | `/logs/{id}` | Get a single request log entry |

### Playground

| Method | Path | Description |
|---|---|---|
| POST | `/playground/token` | Issue a short-lived (10-min) gateway token for the playground UI |
| GET | `/playground/search?q=` | Web search proxy (Brave Search API) |

### Monitor

Live operational view used by the Monitor page in the admin UI. Exposed at `/monitor` via nginx, backed by `src/admin/monitor.lua`.

| Method | Path | Description |
|---|---|---|
| GET | `/monitor` | Auto-refreshing HTML dashboard — live counters, recent requests and blocks (embedded JS polls the JSON endpoint) |
| GET | `/monitor/stats` | JSON snapshot: live shared-dict counters + historical stats (last_min / hour / today / by_tenant / recent requests / recent blocks) |

### MCP Connectors

Model Context Protocol connectors let an admin configure external MCP servers and proxy JSON-RPC 2.0 calls through the gateway. Backed by `src/admin/mcp.lua`.

| Method | Path | Description |
|---|---|---|
| GET | `/mcp` | List MCP connectors scoped to the caller's tenant |
| POST | `/mcp` | Create connector (`name`, `url`, `auth_type`: `none`/`bearer`/`header`, `auth_value`, `enabled`) |
| GET | `/mcp/{id}` | Get a single connector (including `auth_value`) |
| PATCH | `/mcp/{id}` | Update connector fields |
| DELETE | `/mcp/{id}` | Delete connector |
| POST | `/mcp/{id}/call` | Proxy a JSON-RPC 2.0 request (`tools/list`, `tools/call`, etc.) to the connector URL; auth header is applied server-side so the browser never sees the secret |

### Chat Console

| Method | Path | Description |
|---|---|---|
| GET | `/conversations` | List conversations (`?archived=1` to include archived) |
| POST | `/conversations` | Create conversation (`gateway_id`, `model`, `system_prompt`, `temperature`, `max_tokens`; or `source_share_token` to fork from a share) |
| GET | `/conversations/{id}` | Get conversation with all messages |
| PATCH | `/conversations/{id}` | Update title, model, settings, `starred` (0/1), `archived_at`, `memory_disabled` |
| DELETE | `/conversations/{id}` | Delete conversation and all messages |
| POST | `/conversations/{id}/messages` | Append a message (role, content, tokens, cost, latency) |
| PATCH | `/conversations/{id}/messages/{mid}` | Edit message content |
| DELETE | `/conversations/{id}/messages/{mid}` | Delete a message |
| POST | `/conversations/{id}/attachments` | Upload attachment (base64, stored in DB) |
| GET | `/conversations/{id}/share` | Get share link for a conversation |
| POST | `/conversations/{id}/share` | Create share link; returns `{token, url}` |
| DELETE | `/conversations/{id}/share` | Revoke share link |
| GET | `/conversations/{id}/feedback` | Get session feedback (rating + comment) |
| PUT | `/conversations/{id}/feedback` | Save session feedback (`rating` 1–5, optional `comment`) |
| GET | `/attachments/{aid}` | Fetch attachment data (base64 + metadata) |
| DELETE | `/attachments/{aid}` | Delete attachment |
| GET | `/chat-presets` | List saved chat presets |
| POST | `/chat-presets` | Create preset (name, model, system_prompt, temperature, max_tokens) |
| PATCH | `/chat-presets/{id}` | Update preset |
| DELETE | `/chat-presets/{id}` | Delete preset |
| GET | `/chat-commands` | List personal slash commands |
| POST | `/chat-commands` | Create slash command (`name`, `description`, `template`) |
| PATCH | `/chat-commands/{id}` | Update slash command |
| DELETE | `/chat-commands/{id}` | Delete slash command |
| GET | `/memories` | List user memories (project_id IS NULL) for current user |
| GET | `/memories?project_id={id}` | List project-scoped memories (membership required) |
| POST | `/memories` | Create memory; optional `project_id` field for project scope |
| PATCH | `/memories/{id}` | Update memory content or type |
| DELETE | `/memories/{id}` | Delete memory |
| POST | `/chat/files` | Extract text from uploaded file (PDF, DOCX, PPTX via server-side extraction; image via MinerU/OCR; spreadsheet via Files API) |
| POST | `/chat/export-pdf` | Render conversation markdown as PDF; returns binary `application/pdf` |

### Shared Conversations (public, no auth)

| Method | Path | Description |
|---|---|---|
| GET | `/share/{token}` | View a shared conversation snapshot (title + messages); no authentication required |

### Authentication

| Method | Path | Description |
|---|---|---|
| GET  | `/admin/auth/me` | Return current session user |
| POST | `/admin/auth/otp/request` | Request OTP email for email-code login |
| POST | `/admin/auth/otp/verify` | Verify OTP, issue session cookie |
| POST | `/admin/auth/logout` | Clear session |
| GET  | `/admin/auth/google` | Initiate Google OAuth2 SSO flow |
| GET  | `/admin/auth/google/callback` | Google OAuth2 callback; issues session cookie |

### Projects

| Method | Path | Description |
|---|---|---|
| GET | `/projects` | List projects visible to the requesting user |
| POST | `/projects` | Create project (name, description, instructions, icon, color, gateway_id, model) |
| GET | `/projects/{id}` | Get project with members and knowledge items |
| PATCH | `/projects/{id}` | Update project settings |
| DELETE | `/projects/{id}` | Delete project |
| POST | `/projects/{id}/members` | Add member to project (`user_id`, `role`) |
| PATCH | `/projects/{id}/members/{uid}` | Update member role |
| DELETE | `/projects/{id}/members/{uid}` | Remove member |
| GET | `/projects/{id}/knowledge` | List knowledge items attached to project |
| POST | `/projects/{id}/knowledge` | Upload plain-text knowledge item (JSON with `extracted_text`) |
| POST | `/projects/{id}/knowledge/upload` | Upload binary file (PDF/DOCX/XLSX/PPTX); server-side text extraction; original binary stored |
| PUT | `/projects/{id}/knowledge/{filename}` | Upsert knowledge item by filename |
| GET | `/projects/{id}/knowledge/{kid}` | Get single knowledge item with `extracted_text` |
| GET | `/projects/{id}/knowledge/{kid}/download` | Download original binary; 404 for text-only (`source='text'`) items |
| DELETE | `/projects/{id}/knowledge/{kid}` | Delete knowledge item and blob (CASCADE) |
| GET | `/projects/{id}/knowledge-text` | Get all extracted text concatenated (used for context injection) |
| GET | `/projects/{id}/conversations` | List conversations scoped to this project |

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

## 19a. Other Admin UI Pages

The React admin SPA (`frontend/src/modules/`) exposes one page per area of the Admin REST API. Each page is CRUD-shaped: list view, detail drawer or modal, and optional bulk actions. Every page inherits the shared `Layout.module.scss` primitives (`.page`, `.btn`, `.form-input`, `.table`, `.alert`, `<Modal>`) so colour, spacing and accessibility are consistent.

| Module | Page(s) | What it manages |
|---|---|---|
| `gateways` | Gateways list, Gateway detail | Gateway CRUD; provider key management; routing rules editor; circuit breaker config; rate-limit and budget fields; token issuance; spend dashboard; live guardrail stats |
| `tenants` | Tenants list, Tenant detail | Tenant CRUD; budget + period; SIEM config; chat_presets; slash_commands; tenant admin assignment |
| `users` | Users list, User detail | User CRUD; role assignment (`admin` / `editor` / `viewer`); per-user budget; last-login timestamp |
| `analytics` | Analytics dashboard, Tenant drilldown | Spend timeseries, latency percentiles, top models, usage by tenant |
| `logs` | Request log table, Log detail drawer | Filterable request log (tenant, gateway, provider, date), full prompt/response payload view, `meta` JSON inspector |
| `prices` | Model prices list, Edit modal | Model catalog CRUD; `POST /model-prices/sync` trigger; manual per-model pricing override |
| `guardrails` | Guardrail builder | Per-gateway guardrail array editor; Tier-1/Tier-2 detector selector; per-detector config forms (regex patterns, keyword lists, Presidio entities, Prompt Guard categories); `fail_open` toggle |
| `mcp` | MCP connectors list, connector detail | CRUD on MCP connectors (name, URL, auth type, auth value, enabled); test-connection button |
| `commands` | Slash commands list | Tenant-wide slash command CRUD (`name`, `description`, `template` with `{{placeholder}}`) |
| `monitor` | Live monitor | Live counters (requests/sec, active streams, recent blocks); recent request list; auto-refresh via `/admin/v1/monitor/stats` |
| `projects` | Projects list, Project detail | Project CRUD; instructions editor; knowledge file manager (drag-and-drop upload); member roles drawer |
| `settings` | Settings | Per-user preferences (theme, default tenant, default gateway) and admin-scoped secrets (OAuth, Brave API, SMTP, Slack) |
| `profile` | Profile | User profile: email, avatar, account deletion |

Navigation uses a collapsible sidebar (`common/components/sidebar/Sidebar.tsx`); the active page is highlighted and links honour the user's role (viewers don't see destructive actions).

**Sidebar section order:** MAIN (Chat, Projects, Playground) → OBSERVABILITY (Dashboard + admin-only: Cost Analytics, Live Monitor, Request Logs) → MANAGEMENT (admin-only: Tenants, Gateways, Users) → CONFIG → ACCOUNT. The "Only show runnable models" checkbox in the ModelPicker defaults to enabled.

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
- **Web search always-on** — every Chat message includes `X-AIG-Web-Search: 1`; web search activates automatically when the gateway has it configured (Brave API key + `enabled: true`)
- Export buttons: PDF (server-side WeasyPrint) and Markdown (client-side download)
- Settings gear — opens settings drawer

### Settings Drawer

- System prompt (textarea, multi-line; default includes: date, formatting rules, decision table emoji conventions, enumerated list emoji guidance)
- Temperature slider
- Max tokens input
- **Extended thinking** — toggle for Anthropic models that support it; enabling it injects `x-aig-provider-anthropic-beta: interleaved-thinking-2025-05-14` on the inference request and raises a `thinking_budget` the model can spend on reasoning. Reasoning tokens render as a collapsible *Thought process* panel above the response (see Message Rendering).
- Preset save / load / delete (user-level, shared across conversations)
- **MCP connectors** — the settings drawer surfaces the tenant's MCP connectors (from `GET /admin/v1/mcp`). Each connector can be toggled on per-conversation; when on, the gateway fetches the connector's `tools/list` via `POST /admin/v1/mcp/{id}/call` and makes those tools available to the model in the next turn.

### Message Rendering

- **Markdown** — GitHub Flavoured Markdown via `react-markdown` with:
  - GFM tables, task lists, strikethrough
  - KaTeX math (`$inline$` and `$$display$$`)
  - Code blocks with syntax highlighting (highlight.js, `github-dark-dimmed` theme — `#22272e` background, `#adbac7` text), language label, and per-block Copy button
  - Emoji shortcodes (`:dog:` etc.)
  - `<write_file filename="x">content</write_file>` tags emitted by the model are transformed into fenced code blocks on render, so they pass through the artifact card pipeline without raw XML leaking into the visible text
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

### Guardrail & Stream-Health Banners

Two dismissible banners above the chat thread surface backend problems without breaking the conversation:

- **Guardrail warning (yellow, `data-cy=guardrail-warning`)** — rendered when the inference response carries `X-Aig-Guardrail-Warning`. Shows the detector name and error class (e.g. *"outage-probe unavailable (dns); request processed without this guardrail"*). Non-blocking: the assistant reply still arrives. Dismissible.
- **Hard error (red)** — shown on fetch failure, non-2xx status, or when the SSE stream closes with `accumulatedChars === 0 && continueCount === 0` (empty-stream detection). The empty-stream path raises an explicit error — *"Connection to the AI gateway was interrupted before a response arrived"* — instead of leaving the user staring at an empty thread. When `X-Aig-Guardrail-Warning` is present the message is upgraded to *"Guardrail degraded and no response was received: \<warning\>"*.

### File Attachments

Attached via paperclip button or drag-and-drop. Supported formats:

| Format | Handling |
|---|---|
| Images (JPEG, PNG, GIF, WebP) | Sent as `image_url` blocks for vision-capable models; OCR via MinerU for text-only models |
| PDF | Anthropic native document block (Claude); MinerU text extraction for others |
| Plain text (`.txt`) | Anthropic native document block |
| **Markdown (`.md`)** | Decoded in-browser (base64 → UTF-8); injected as text block `[Document: filename]\n\ncontent`; shown as chip |
| Word (`.docx`) | Server-side text extraction via `/chat/files`; content injected as text block; shown as chip |
| PowerPoint (`.pptx`) | Server-side slide text extraction via `/chat/files` (Python zipfile + XML); content injected as text block; shown as chip |
| CSV / TSV | Server-side file upload via Files API; sent as `document` with file reference |
| Excel (`.xlsx`, `.xlsm`) | Same as CSV |
| OpenDocument (`.ods`) | Same as CSV |

- Attachments shown as chips in the input bar and in the sent user bubble (filename only, no content dump)
- Drop zone overlay with label "Images · PDF · DOCX · PPTX · XLSX · ODS · CSV · TXT · MD"

### Slash Commands

Personal shortcuts that expand into prompt templates. Managed via the admin UI or `GET/POST/PATCH/DELETE /chat-commands`.

- Each command has a `name` (the `/slash-trigger`), an optional `description`, and a `template` string
- Templates support `{{variable}}` placeholders; the frontend shows a fill-in dialog before sending
- Commands are user-scoped — each user's command list is private
- Tenant-level presets can also carry a `slash_commands` array that surfaces to all users on that tenant
- Triggered in the chat input by typing `/` — a picker overlay filters commands as the user types

### Memories

A personalisation layer that persists facts, preferences, and instructions across conversations, with **project-scoped isolation** matching Claude.ai's memory model.

#### Memory schema

- `content` — the memory text
- `type` — `fact` | `preference` | `instruction`
- `source` — `manual` (user-created) or `auto` (model-extracted)
- `project_id` — optional; `NULL` = user pool (per-user, standalone chats); non-null = project pool

#### Scope model

| Chat context | Memory pool used | System prompt section |
|---|---|---|
| Standalone chat | User (per-user, `project_id IS NULL`) | `## What I know about you` |
| Project chat | Project-specific (`project_id = X`) | `## What I know about this project` |

The two pools are strictly isolated: user memories never appear in project chats and vice versa.

#### How it works

- **Auto-extraction** — the model instruction in the system prompt asks the model to emit `<memory type="fact|preference|instruction">…</memory>` tags when it detects durable facts. These tags are stripped from the visible response and saved via `POST /memories` with the appropriate `project_id` (captured at send-time to prevent scope drift if the user navigates away mid-stream).
- **Injection** — on each request, the full memory pool for the current scope is loaded and appended to the system prompt. The model instruction in project context is scoped to project-relevant facts (conventions, tech stack, team preferences).
- **Scope-reactive load** — the frontend reloads the memory pool whenever `projectIdParam` changes; the state is cleared immediately to prevent stale-scope injection during the reload window.
- **Per-conversation opt-out** — `memory_disabled: 1` on the conversation suppresses injection and auto-extraction for that conversation only. The MemoriesPanel toggle label adapts to context ("Don't use project memories in this conversation" vs "Don't use memories in this conversation").
- **Project deletion cascade** — `delete_project()` hard-deletes all `chat_memory` rows for the project.

#### API

- `GET /memories` — user pool (`project_id IS NULL` memories for current user)
- `GET /memories?project_id=X` — project pool (requires project membership; admins bypass)
- `POST /memories` — create memory; optional `project_id` field; validates project existence (404) and membership (403) before inserting
- `PATCH/DELETE /memories/{id}` — update/delete (scoped by `user_id`)

#### MemoriesPanel UI

- Title: "Project Memories" in project context, "Memories" in standalone
- Manual add includes `project_id` from current context
- Type badges: `fact`/`preference` (neutral), `instruction` (warning), `auto` source (success)

### Conversation Sharing

Read-only public share links for individual conversations.

- `POST /conversations/{id}/share` — creates a share link; returns `{ token, url }` where URL is `/shared/{token}`
- `GET /conversations/{id}/share` — retrieve the active share link for a conversation
- `DELETE /conversations/{id}/share` — revoke the share link (public access immediately disabled)
- The public viewer (`GET /share/{token}`) requires no authentication and renders the conversation snapshot (title + messages)
- **Fork from share:** `POST /conversations` with `source_share_token` creates a new editable copy of the shared conversation under the caller's account
- Share snapshots are fixed at creation time — subsequent messages do not appear in the shared view

### Conversation Feedback, Starring, and Archiving

**Feedback:** After each conversation a user can submit a star rating (1–5) and optional comment via `PUT /conversations/{id}/feedback`. The current feedback is retrieved with `GET /conversations/{id}/feedback`.

**Starring:** `PATCH /conversations/{id}` with `starred: 1` marks a conversation as a favourite; `starred: 0` unmarks it. Starred conversations can be filtered in the list.

**Archiving:** `PATCH /conversations/{id}` with `archived_at: <timestamp>` archives the conversation (hidden from the default list). `GET /conversations?archived=1` retrieves archived conversations. Set `archived_at: null` to restore.

### Project Knowledge Base

Each project can hold a library of files that the model reads on demand during conversations.

#### File upload (Knowledge panel)

Files are uploaded via the project detail page (Knowledge tab) or by drag-and-drop:

| Type | Size limit | Handling |
|---|---|---|
| Plain text (`.txt`, `.md`, `.csv`, `.json`, `.xml`, etc.) | 5 MB | Text read client-side; stored as `extracted_text` |
| PDF (`.pdf`) | 20 MB | Server-side extraction via `fitz` (PyMuPDF) fast path; MinerU OCR fallback |
| Word (`.docx`) | 20 MB | Server-side XML extraction (Python zipfile + regex) |
| Excel (`.xlsx`, `.xls`, `.ods`) | 20 MB | Server-side XML → CSV conversion |
| PowerPoint (`.pptx`) | 20 MB | Server-side slide text extraction (Python zipfile + `xml.etree`) |

Binary uploads (`source='upload'`) store the original file in `chat_project_knowledge_blob` (CASCADE-deleted with the row). The download endpoint (`GET /knowledge/:kid/download`) returns the original binary. Text-only items (`source='text'`) return 404 from the download endpoint.

#### On-demand reading and writing during inference

Project knowledge files are **not** injected into the system prompt verbatim. Instead, the system prompt includes a file index and instructions for both reading and writing:

```
## Reading and writing project files

You CAN both read and write files in this project's knowledge base.

**Reading:** To read the full content of a file, emit exactly: <read_file>filename</read_file>

**Writing / updating:** To create or update a file, emit:
<write_file filename="example.html">
file content here
</write_file>

The UI will automatically save the file to the project knowledge base.

When the user asks to update an existing file, ALWAYS read it first with <read_file>,
then output the complete updated file with <write_file>.

## Project Knowledge Files

The following files are available in this project's knowledge base:

- report.pdf
- schema.sql
```

**Reading (`<read_file>`):**
When the model emits a `<read_file>filename</read_file>` tag:
1. The frontend strips the tag from the visible assistant bubble and shows a `📄 Read: filename (N chars)` blockquote
2. Looks up the file in the in-memory `projectKnowledge` array (case-insensitive match)
3. Injects the content as a follow-up user message (`## File: filename\n\n\`\`\`\ncontent\n\`\`\``)
4. Makes a second inference request with the enriched context

The frontend also handles `read_file` responses delivered as Anthropic native `tool_use` (via the `tool_calls` finish reason forwarded by the gateway), using the same injection flow.

A cap of 5 file reads per response (`MAX_FILE_READS`) prevents infinite loops. Missing files inject a `[File not found in project knowledge base. Available files: …]` message listing the available files.

**Writing (`<write_file>`):**
When the model emits `<write_file filename="name.ext">content</write_file>`:
1. While streaming, the raw tag content is hidden from view and a `📝 Writing filename…` status is shown
2. After the stream ends, the tag is replaced with a fenced code block (with correct language tag and filename comment) for the artifact card pipeline to pick up
3. The file content is saved to the project knowledge base via `PUT /projects/{id}/knowledge/{filename}`
4. A `✅ File saved to project: filename` (or `❌ Failed to save`) notice is appended inline

The same transformation is applied in `MessageBubble` on render, so saved messages display consistently.

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
- System prompt instructs the model to produce a title even when the provided excerpt is incomplete (e.g. mid-sentence cutoff from a long streaming context)

### Auto-Continue

If the model returns `finish_reason: "max_tokens"`, the chat automatically continues with `"Continue"` injected as the next user message, up to 10 times. Accumulated content is stitched together into a single assistant message.

### Ghost Mode

A privacy toggle in the Chat UI that makes conversations completely ephemeral:

- Enabled via the 👻 button in the toolbar; state persisted in `localStorage` (`aig-chat-ghost`)
- **No DB writes** — conversation and messages exist only in memory; no row is created in `conversations` or `messages`
- **No request log** — `x-aig-collect-log: false` header sent on every inference request; the gateway skips the log-phase DB write
- **No attachment storage** — file text extraction still works (used for context injection) but no binary is persisted
- **No auto-title generation** — skipped because there is no conversation row to update
- **Export hidden** — export buttons are not shown while ghost mode is active
- **Feedback hidden** — session feedback button suppressed (no conversation to attach it to)
- A prominent banner ("👻 Ghost mode — this conversation is not saved and will not be logged") appears below the config bar while active
- Switching conversations resets in-memory state; switching off ghost mode starts a fresh normal conversation

### Background Streaming

Streaming continues even when the user navigates to a different conversation. A pulsing dot indicator appears next to the conversation title in the sidebar to show that a response is in flight in the background. When the user returns to that conversation, the completed (or in-progress) response is displayed. If the user is viewing a different conversation, `setMessages` updates are gated to prevent cross-conversation message bleed.

### Tool-Use Activity Display

While a model is executing a tool call (web search, computer use, code execution), a live status label is displayed in the processing-status area above the streaming cursor:

| Tool name (from `aig_tool_call`) | Status label |
|---|---|
| `web_search` | 🔎 Searching the web… |
| `fetch_url` | 🔗 Fetching URL… |
| `computer_use` | 🖥️ Using computer… |
| `code_execution` | ⚙️ Running code… |
| *(unknown)* | ⚙️ `<tool_name>`… |

Gateway-level status events are also surfaced:

| Gateway event (`aig_status`) | Status label | Emitted by |
|---|---|---|
| `fetching` | 🔎 Fetching N URL(s)… | web_search.lua before the Brave search-result fetch |
| `fetching_url` | 🔗 Fetching N URL(s)… | url_fetch.lua before the `fetch_url` tool fetch |

All status types are automatically cleared when the first real text token arrives.

### Export

- **Markdown** — full conversation rendered as `# Title\n\n**You**\n\n...\n\n**Claude**\n\n...`; downloaded as `{slug}-{date}.md`
- **PDF** — Markdown sent to `POST /chat/export-pdf` (WeasyPrint, server-side); downloaded as `{slug}-{date}.pdf`

---

## 21b. Memory System

Cross-session personalisation that persists facts, preferences, and instructions across conversations — scoped either to a user globally or to a specific project.

---

### Current implementation

#### Storage

```sql
CREATE TABLE chat_memory (
    id          VARCHAR(36)  PRIMARY KEY,
    user_id     VARCHAR(36)  NOT NULL,  -- always the creator
    project_id  VARCHAR(36)  NULL,       -- NULL = global; non-null = project-scoped
    content     TEXT         NOT NULL,
    type        VARCHAR(16)  NOT NULL DEFAULT 'fact',    -- fact | preference | instruction
    source      VARCHAR(16)  NOT NULL DEFAULT 'manual',  -- manual | auto
    created_at  BIGINT,
    updated_at  BIGINT,
    KEY idx_memory_user    (user_id, created_at),
    KEY idx_memory_project (project_id, created_at),
    FOREIGN KEY (user_id)    REFERENCES user(id)         ON DELETE CASCADE,
    FOREIGN KEY (project_id) REFERENCES chat_project(id)
)
```

`project_id IS NULL` = user memory (per-user pool). `project_id = X` = project-scoped memory (isolated to that project). Project deletion hard-deletes its memories.

#### Scope isolation

| Chat context | Pool queried | System prompt section |
|---|---|---|
| Standalone chat | `WHERE user_id = ? AND project_id IS NULL` | `## What I know about you` |
| Project chat (`?project_id=X`) | `WHERE user_id = ? AND project_id = X` | `## What I know about this project` |

The two pools are strictly isolated — user memories never appear in project chats and vice versa. This matches Claude.ai's memory model.

#### Auto-extraction

The system prompt appended to every inference request includes an instruction asking the model to emit hidden XML tags when it detects a durable fact:

```
When the user states a personal fact, preference, or instruction worth
remembering, emit it exactly as:
<memory type="fact|preference|instruction">concise fact in third-person</memory>
This tag is invisible to the user. Use sparingly — only for durable facts.
```

In project context the instruction is tuned to project-relevant facts (coding conventions, tech-stack decisions, team preferences).

After each streamed response the frontend:
1. Scans the accumulated text with `/<memory(?:\s+type="([^"]+)")?>([\s\S]*?)<\/memory>/g`
2. Strips matched tags from the visible content (users never see the XML)
3. POSTs each extracted fact to `POST /memories` with `source: "auto"` and the `project_id` snapshotted at send-time (prevents scope drift if the user navigates away mid-stream)
4. Shows a brief toast: "Remembered: {content}"

#### Injection into inference requests

On every request, the frontend loads the memory pool for the current scope and appends it to the assembled system prompt:

```
---
## What I know about you        ← or "about this project" in project context
- User prefers concise bullet-point answers
- Works on a TypeScript monorepo with strict mode enabled
- Prefers dark mode
```

The memory pool is loaded reactively: whenever `projectIdParam` changes in the URL, `setMemories([])` clears the state immediately (preventing stale-scope injection during the reload window) and the correct pool is fetched from the API.

#### Memory types

| Type | Meaning | Badge |
|---|---|---|
| `fact` | Objective fact about the user or project | neutral (grey) |
| `preference` | Stylistic or workflow preference | neutral (grey) |
| `instruction` | Standing order that overrides default behaviour | warning (orange) |

`auto` memories (model-extracted) carry an additional green "auto" badge. Manual memories have no extra badge.

#### Per-conversation opt-out

`memory_disabled: 1` on a conversation record suppresses both injection and auto-extraction for that conversation only. Toggled via the MemoriesPanel ("Don't use memories in this conversation" / "Don't use project memories in this conversation"). All other conversations for the user are unaffected.

#### API

| Method | Path | Description |
|---|---|---|
| GET | `/memories` | Global memories (`project_id IS NULL`) for the calling user |
| GET | `/memories?project_id=X` | Project-scoped memories; requires project membership (admins bypass) |
| POST | `/memories` | Create memory; optional `project_id`; validates project existence (404) and membership (403) |
| PATCH | `/memories/{id}` | Update `content` (scoped by `user_id`) |
| DELETE | `/memories/{id}` | Delete (scoped by `user_id`) |

#### MemoriesPanel UI

An accessible drawer opened from the toolbar memory button. Features:
- Title adapts to scope: **"Project Memories"** (project chat) or **"Memories"** (standalone)
- Inline edit — click any memory text to edit in place
- Delete button per row
- Manual add: textarea + type selector (Fact / Preference / Instruction) + Add button
- Per-conversation disable toggle at the bottom (label adapts to scope)
- Empty-state message adapts to scope

---

### Comparison with Claude.ai memory

| Feature | Claude.ai | This product |
|---|---|---|
| Cross-session persistence | ✅ | ✅ |
| Auto-extraction from model output | ✅ | ✅ (`<memory>` tag protocol) |
| Manual add / edit / delete | ✅ | ✅ MemoriesPanel |
| Global pool for standalone chat | ✅ | ✅ |
| Per-project isolated pool | ✅ | ✅ |
| Memory types (fact / preference / instruction) | ❌ flat | ✅ |
| Per-conversation opt-out | ❌ (global toggle only) | ✅ |
| Memory synthesis (auto-summary of past chats) | ✅ (24h background job) | ❌ planned |
| Past-chat RAG search | ✅ (paid plans) | ❌ planned |
| Memory export / import | ✅ | ❌ planned |
| Team / shared project memories | ❌ | ❌ planned |

---

### Planned future features

#### 1. Memory synthesis (cross-conversation summarisation)

A scheduled background job (running every 24 h per user) reads recent conversations and synthesises key facts, decisions, and patterns into new `auto` memories — without any model output containing `<memory>` tags. The synthesis prompt would ask the model to distil the last N conversations into concise, typed memory entries.

Architectural approach:
- Background timer (`ngx.timer.at`) or cron job polls for users with new conversation activity since the last synthesis run
- Fetches the last 24 h of message text per user
- Calls a gateway inference endpoint (model configurable; haiku/flash for cost)
- Parses the response for typed facts and upserts into `chat_memory`
- A `last_synthesised_at` timestamp prevents redundant re-processing

This would cover the Claude.ai "Generate memory from chat history" feature.

#### 2. Past-chat RAG search

Semantic search across conversation history, surfaced as a model tool call (`conversation_search`). The model can invoke it when it needs context from a past session.

Architectural approach:
- Embed conversation messages (or summaries) into a vector store (pgvector, Qdrant, or the existing MySQL semantic-cache table adapted for memory vectors)
- On tool call: embed the query, cosine-similarity search, return top-K excerpts
- The tool result is injected as a user message, then the model continues with enriched context
- Scoped: standalone-chat search covers only global conversations; project-chat search covers only project conversations

This would cover Claude.ai's `conversation_search` and `recent_chats` tool pair (available on paid plans).

#### 3. Memory export / import

A UI button and API endpoint to:
- **Export** — download all memories (user pool + all project pools) as a structured JSON or plain Markdown file
- **Import** — upload a memory file (from Claude.ai, ChatGPT, or a previous export) to seed the memory system

The import flow would parse the file, deduplicate against existing memories, and create new entries with `source: "import"`.

#### 4. Memory consolidation and deduplication

Over time, auto-extracted memories can accumulate near-duplicate or contradictory entries. A periodic consolidation pass would:
- Embed all memories for a user/project
- Cluster by cosine similarity (threshold ~0.92)
- Merge near-duplicates into a single canonical entry (keeping the most recent or most specific wording)
- Flag and resolve contradictions (e.g. "prefers tabs" vs "prefers spaces" for the same project)

#### 5. Relevance-filtered injection

Currently all memories for a scope are injected on every request. With large memory pools this wastes context tokens and may dilute prompt quality. Future improvement:
- Embed the current user message and each memory
- Inject only the top-K most relevant memories (cosine similarity ≥ threshold)
- Fall back to full injection when the pool is small (< 20 entries)

#### 6. Team / shared project memories

Currently all project memories are created by individual users (`user_id = creator`). A shared memory model would:
- Allow any project member to create, edit, or delete project memories (not just the original creator)
- Show which team member created or last edited a memory
- Allow a project owner to "lock" a memory so it can only be modified by owners/admins

This covers the Claude.ai limitation: "Memory is personal — no mechanism for a team to build and share a common AI memory layer."

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
  "webhooks": null,
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

---

## 24. Development Cost Estimation

**Rate: 150 EUR/h** (senior full-stack + DevOps, all-in: design, implementation, unit/integration tests, E2E tests, documentation)

### Methodology

Each feature row is broken into three cost buckets:

- **Dev** — Architecture, implementation, local testing, code review
- **QA** — E2E test authoring, test infrastructure, CI integration, real-inference test runs
- **Docs** — Technical documentation, config reference, inline comments

All figures are in **hours**. The Euro column is `(Dev + QA + Docs) × 150 EUR`.

---

### Backend (OpenResty / Lua)

| Feature | Dev h | QA h | Docs h | Total h | **EUR** |
|---|---|---|---|---|---|
| §1 Request Pipeline (middleware chain, 3-phase Nginx) | 24 | 8 | 4 | 36 | **5 400** |
| §2 Multi-Provider Support (21 providers, compat resolution, LiteLLM prefix stripping, translation layers) | 60 | 16 | 8 | 84 | **12 600** |
| §3 Authentication & Authorization (OTP email, Google OAuth2, roles, token hashing, access matrix) | 20 | 8 | 4 | 32 | **4 800** |
| §4 Dynamic Routing & Fallback (rules engine, load balancing, sticky sessions, circuit breaker) | 28 | 10 | 4 | 42 | **6 300** |
| §5 Caching — exact-match + semantic (embeddings, cosine similarity, async store) | 24 | 8 | 4 | 36 | **5 400** |
| §6 Rate Limiting (sliding-window, per-gateway, per-token) | 8 | 4 | 2 | 14 | **2 100** |
| §7 Budget & Quota Enforcement (3-level hierarchy, micro-dollar accounting, resets) | 12 | 4 | 2 | 18 | **2 700** |
| §7a Webhooks (async delivery, HMAC signing, 3 event types) | 8 | 4 | 2 | 14 | **2 100** |
| §8 Guardrail Pipeline (7 Tier-1 detectors, 3 Tier-2 sidecars, orchestrator, fail-open, CORS header, outage classification) | 48 | 16 | 8 | 72 | **10 800** |
| §9 Web Search (Brave API, 4-step agentic loop, Gemini native grounding, parallel fetch) | 24 | 8 | 4 | 36 | **5 400** |
| §9a URL Fetch (2-leg tool-use, SSRF guard, URL guard for injected context) | 16 | 6 | 3 | 25 | **3 750** |
| §9b Server-Side Tool Loop (unified tool_loop middleware; streaming + buffered multi-leg execution; OpenAI SSE tool_call streaming; vLLM support; PII-path buffered loop; read/write/fetch/search/MCP tools) | 32 | 12 | 5 | 49 | **7 350** |
| §10 Reasoning Model Support (Anthropic extended thinking, DeepSeek-R1 strip, Qwen3/Ollama think) | 16 | 6 | 3 | 25 | **3 750** |
| §11 Provider Key Management / BYOK (AES-256-CBC encrypt, shared-dict cache, alias routing) | 12 | 4 | 2 | 18 | **2 700** |
| §12 IP Allowlist (CIDR matching, per-gateway config) | 4 | 2 | 1 | 7 | **1 050** |
| §13 Response Streaming (SSE normalisation, finish_reason mapping, tool_calls forwarding, token injection) | 24 | 8 | 4 | 36 | **5 400** |
| §14 Cost Attribution & Pricing (model catalog, pricing DB, auto-sync, micro-dollar, cache token accounting) | 16 | 6 | 3 | 25 | **3 750** |
| §15 Observability & Logging (structured JSON log, payload capture, SIEM export, OpenTelemetry tracing) | 20 | 8 | 4 | 32 | **4 800** |
| §16 Prometheus Metrics (counters, histograms, shared-dict scrape) | 8 | 3 | 2 | 13 | **1 950** |
| §17 Multi-Tenancy (data isolation, cross-tenant guard, schema, cascade deletes) | 16 | 6 | 3 | 25 | **3 750** |
| §18 Admin REST API (130+ endpoints across 15 resource groups) | 60 | 20 | 8 | 88 | **13 200** |
| §23 Error Handling (structured JSON errors, consistent codes) | 4 | 2 | 1 | 7 | **1 050** |
| **Backend subtotal** | **484** | **179** | **81** | **744** | **111 600** |

---

### Frontend (React / TypeScript)

| Feature | Dev h | QA h | Docs h | Total h | **EUR** |
|---|---|---|---|---|---|
| §19 Dashboard UI (hero cards, sparklines, timeframe switcher, top models, tenant usage) | 16 | 6 | 2 | 24 | **3 600** |
| §19a Admin UI Pages (13 module pages: gateways, tenants, users, analytics, logs, prices, guardrail builder, MCP, commands, monitor, projects, settings, profile) | 80 | 24 | 8 | 112 | **16 800** |
| §20 Playground UI (multi-panel comparison, streaming, status bar, debug log, error badges, state persistence) | 32 | 10 | 4 | 46 | **6 900** |
| §21 Chat UI — conversation management (sidebar, search, rename, star, archive, create, delete) | 20 | 8 | 3 | 31 | **4 650** |
| §21 Chat UI — configuration bar & presets (tenant/gateway/model selectors, preset mode, always-on web search, export buttons) | 16 | 6 | 2 | 24 | **3 600** |
| §21 Chat UI — settings drawer (system prompt, temperature, max tokens, extended thinking, preset save/load/delete, MCP toggles) | 16 | 6 | 2 | 24 | **3 600** |
| §21 Chat UI — message rendering (GFM, KaTeX, code blocks with dark theme, thinking panels, artifact panel, streaming cursor, metadata, copy/edit/regenerate) | 32 | 10 | 4 | 46 | **6 900** |
| §21 Chat UI — file attachments (8 formats, drag-and-drop, chips, server-side extraction pipeline) | 24 | 8 | 3 | 35 | **5 250** |
| §21 Chat UI — slash commands (picker overlay, template variables, fill modal, tenant merge) | 16 | 6 | 2 | 24 | **3 600** |
| §21 Chat UI — memories (project-scoped pools; auto-write with scope capture; manual CRUD; system prompt injection; scope-reactive load; per-conversation opt-out; panel title by context) | 20 | 8 | 3 | 31 | **4 650** |
| §21 Chat UI — conversation sharing (share link CRUD, public viewer, fork-from-share) | 12 | 5 | 2 | 19 | **2 850** |
| §21 Chat UI — feedback, starring, archiving | 8 | 4 | 1 | 13 | **1 950** |
| §21 Chat UI — project knowledge base (file upload panel, on-demand read, `<read_file>` injection, `<write_file>` auto-save, streaming hide, render transform) | 32 | 12 | 4 | 48 | **7 200** |
| §21 Chat UI — input box (auto-grow textarea, focus management, Enter/Shift+Enter) | 6 | 3 | 1 | 10 | **1 500** |
| §21 Chat UI — auto-title generation (background request, Qwen3 `/no_think`, strip `<think>`) | 8 | 4 | 1 | 13 | **1 950** |
| §21 Chat UI — auto-continue (max_tokens loop, content stitching, 10× cap) | 8 | 4 | 1 | 13 | **1 950** |
| §21 Chat UI — ghost mode (ephemeral conversations, no log header, export/feedback hidden) | 8 | 4 | 1 | 13 | **1 950** |
| §21 Chat UI — background streaming (cross-conversation in-flight, sidebar indicator, cross-conversation gate) | 10 | 4 | 1 | 15 | **2 250** |
| §21 Chat UI — tool-use activity display (status badge mapping, gateway aig_status events) | 6 | 3 | 1 | 10 | **1 500** |
| §21 Chat UI — guardrail & stream-health banners (yellow warn, red hard error, empty-stream detection) | 8 | 4 | 1 | 13 | **1 950** |
| §21 Chat UI — export (Markdown client-side, PDF server-side WeasyPrint) | 8 | 4 | 2 | 14 | **2 100** |
| **Frontend subtotal** | **386** | **144** | **48** | **578** | **86 700** |

---

### QA Infrastructure & Test Suite

| Area | Dev h | QA h | Docs h | Total h | **EUR** |
|---|---|---|---|---|---|
| Playwright config (docker vs local, sequential isolation, auth setup, MySQL OTP flow) | 8 | 4 | 2 | 14 | **2 100** |
| 60 spec files / ~740 test cases — backend API tests (CRUD, auth, RBAC, guardrails, routing, budget, rate limit) | 20 | 60 | 8 | 88 | **13 200** |
| 60 spec files / ~740 test cases — frontend E2E UI tests (chat flows, file uploads, presets, commands, memory, sharing, projects, ghost mode) | 24 | 80 | 10 | 114 | **17 100** |
| Real-inference regression tests (sonnet format, qwen3 format, write_file, project read, code rendering, docx, PDF, web search, URL fetch, export) | 12 | 40 | 6 | 58 | **8 700** |
| CI integration & test infra (auth.setup.ts, docker test environment, screenshot baseline) | 12 | 8 | 3 | 23 | **3 450** |
| **QA subtotal** | **76** | **192** | **29** | **297** | **44 550** |

---

### Technical Documentation Site

The published documentation is a standalone deliverable separate from inline code comments. It comprises **81 Markdown source files**, **~74,640 words**, **75 annotated screenshots**, and a full MkDocs site with PDF export (`gen_pdf.py`, WeasyPrint). This maps to **~300 printed pages** at ~250 words/page.

| Work item | Detail | Hours |
|---|---|---|
| Content writing — 81 pages of technical reference | ~2.5 h/page avg (getting-started, concepts, API reference, config, guardrails ×10, admin-ui ×11, providers ×8, routing ×5, observability ×6, security ×6, integrations, troubleshooting, changelog) | 202 |
| Screenshots — 75 annotated PNG captures | Setup, capture, highlight/callout annotations, embedding, alt text | 38 |
| MkDocs infrastructure | mkdocs.yml nav, custom theme, PDF generation script, CI hook, CSS overrides | 20 |
| Revision cycles | 3 complete refresh rounds visible in git (`9539788`, `6553f9f`, `0c6b42c`) — content updates, screenshot re-takes, structural reorganisation | 80 |
| German-language prompt guide (`prompts-de.md`) | Localised variant of the prompts chapter | 10 |
| **Documentation subtotal** | | **350** |

350 h × 150 EUR = **52 500 EUR**

---

### Revision & Iteration Overhead

The git history (~85 commits) shows substantial revision work on top of the initial feature build. The following categories are **not** captured in the per-feature rows above:

| Revision category | Evidence in git log | Dev h | QA h | Docs h | Total h | **EUR** |
|---|---|---|---|---|---|---|
| Storage migration: SQLite → MySQL/MariaDB | `d8dc7c3`, `54063e9`, `6ec5ca8`, `458e4cf`, `7a89617` | 20 | 8 | 2 | 30 | **4 500** |
| Guardrails pipeline rewrite (DLP middleware → detector pipeline) | `93ef4cd`, `80916ab`, `d93b5d5`, `a550333` | 32 | 12 | 4 | 48 | **7 200** |
| Bug fixes: streaming, compat, BYOK, providers, timestamps (~12 fix commits) | `27d5230`, `9ede118`, `5917cb7`, `fix/*` | 24 | 8 | 0 | 32 | **4 800** |
| Infrastructure & DevOps (Docker, nginx, build scripts, presidio sidecar, vLLM services) | `d8dc7c3`, `2ca9cfa`, `5503fc3`, `bbbae16` | 16 | 4 | 2 | 22 | **3 300** |
| Documentation refresh cycles (architecture rewrite, screenshots ×3, competitive analysis) | `afcde7e`, `9539788`, `6553f9f`, `9cabffa`, `b04a6f2` | 0 | 0 | 32 | 32 | **4 800** |
| E2E test suite expansion rounds (3 separate rounds of new specs + infrastructure) | `824ec0a`, `9af4a2b`, `7a89617`, `f884946` | 8 | 40 | 4 | 52 | **7 800** |
| **Revision subtotal** | | **100** | **72** | **44** | **216** | **32 400** |

---

### Summary

| Category | Dev h | QA h | Docs h | Total h | **EUR** |
|---|---|---|---|---|---|
| Backend | 484 | 179 | 81 | 744 | **111 600** |
| Frontend | 386 | 144 | 48 | 578 | **86 700** |
| QA infrastructure & test suite | 76 | 192 | 29 | 297 | **44 550** |
| Revision & iteration overhead | 100 | 72 | 44 | 216 | **32 400** |
| Technical documentation site (300+ pages, 75 screenshots, 3 refresh cycles) | 0 | 0 | 350 | 350 | **52 500** |
| **Total** | **1 046** | **587** | **552** | **2 185** | **327 750** |

**Total estimated investment: ~2 185 hours / ~327 750 EUR** at 150 EUR/h.

> The "Docs h" column in the per-feature rows covers inline documentation (code comments, config examples, FEATURES.md entries). The documentation site row covers the separately deliverable 300-page MkDocs site as a distinct writing and production effort.
>
> These figures represent estimated hours for a single senior engineer working end-to-end (design → implementation → tests → documentation), including the actual iteration and refactoring cycles visible in the git history. A team of 2–3 engineers working in parallel would reduce calendar time but not total hours. Estimates assume familiarity with OpenResty/LuaJIT, React, and Playwright; onboarding a less experienced engineer would add 20–30% to the Dev bucket.
