# Request Pipeline

Every request to the gateway passes through an ordered middleware chain split across three processing phases. Each step either short-circuits (returns to the client immediately) or enriches a per-request context object (`ctx`) that is passed to the next step.

---

## Phase diagram

```
[Consumer]
    │
    ▼  ── Access processing phase ──────────────────────────────────
    │
    ├─ 1. request_id     Generate or forward X-Request-Id (UUID)
    ├─ 2. tenant         Resolve {tenant_slug}/{gateway_slug} → UUIDs; load gateway config
    ├─ 3. auth           Validate token (x-aig-token / Bearer / x-api-key)
    │                    Enforce role (viewer → 403); load per-token rate/budget overrides
    ├─ 4. rate_limit     Sliding-window check
    ├─ 5. ip_allowlist   CIDR match against gateway config allowlist
    │
    ▼  ── Content processing phase ─────────────────────────────────
    │
    ├─ 6.  cache_check      SHA-256(provider:model:canonical_body) → serve if HIT
    ├─ 7.  detectors        Tier 1 (regex, keyword) → Tier 2 (presidio, llm_guard, pii_protector)
    ├─ 8.  transform        Parse + normalize body; collect x-aig-meta-* headers
    ├─ 9.  routing          Evaluate ordered routing rules → provider, model, fallbacks
    ├─ 10. byok             Decrypt provider API key (cached for 60 seconds)
    ├─ 11. upstream         HTTP call to provider; retry on 5xx; walk fallback chain
    │                       [streaming: emit usage chunk + [DONE] after stream]
    ├─ 12. detectors_resp   Response-phase detector pipeline
    ├─ 13. cost             Count tokens; compute cost_usd; increment budget counter
    ├─ 14. cache_store      Persist response to cache (non-streaming, status 200)
    │
    ▼  ── Log phase (best-effort, after response sent) ─────────────
    │
    ├─ 15. logger           Write structured JSON to request log store
    └─ 16. metrics          Increment Prometheus counters in metrics store

[Consumer Response]
```

---

## Access phase

The access processing phase runs before the request body is read. Short-circuiting here avoids unnecessary I/O.

### Step 1 — request_id

Generates a UUID v4 `X-Request-Id` if the client did not supply one, and stores it in `ctx.request_id`. All subsequent log entries and upstream requests carry this ID.

### Step 2 — tenant resolution

Parses `{tenant_slug}` and `{gateway_slug}` from the URL path, looks up the corresponding UUIDs in the config database (or the credential cache), and loads the full gateway config JSON. Results are cached for `config_cache_ttl` seconds (default: 30 s) to avoid per-request database reads.

Returns `404 TENANT_NOT_FOUND` if either slug is unknown.

### Step 3 — authentication

Accepts a token from (in priority order):

1. `x-aig-token` header
2. `Authorization: Bearer <token>`
3. `x-api-key` header (Anthropic SDK compatibility)

The SHA-256 hash of the supplied token is compared against the `auth_tokens` table. Tokens are scoped to a single gateway; cross-gateway use returns `401`.

- `viewer` role → `403 FORBIDDEN` immediately
- Per-token `rate_limit` and `budget_usd` overrides are loaded into `ctx.auth_token` here

Skipped entirely when the gateway's `auth_required` is `false`.

### Step 4 — rate limiting

Sliding-window approximation using two time buckets:

```
effective_count = prev_bucket × (1 − elapsed/window_sec) + cur_bucket
```

Returns `429 RATE_LIMITED` with `X-RateLimit-Limit`, `X-RateLimit-Remaining`, and `X-RateLimit-Reset` headers if the count exceeds the limit. Per-token overrides take precedence over gateway-level config.

### Step 5 — IP allowlist

Checks the client IP against the gateway's `ip_allowlist` CIDR list using 32-bit integer masking. An empty list allows all traffic. Returns `403 FORBIDDEN` with `blocked_by="ip_allowlist"` on mismatch.

---

## Content phase

The content processing phase has access to the full request body. Middleware in this phase is responsible for security checks, routing decisions, and the upstream call.

### Step 6 — cache check

Computes `SHA-256(provider:model:canonical_json_body)`. The `stream`, `user`, and `metadata` fields are excluded from the hash key to ensure semantic correctness. On a cache hit, returns `200` immediately with the stored body and `X-AIG-Cache: HIT`. Logs `saved_cost_usd` and `saved_latency_ms`.

Returns immediately — steps 7–14 are skipped on a cache hit.

### Step 7 — detectors (request phase)

Two-tier detector pipeline:

- **Tier 1** (in-process, microseconds): regex and keyword detectors run against the request body
- **Tier 2** (HTTP sidecar, milliseconds): Presidio (NER-based PII) and LLM Guard, only if Tier 1 passes

The most restrictive action wins when multiple detectors fire: `block` > `scrub` > `flag`. Blocked requests return a synthetic response shaped to match the request wire format (OpenAI JSON, OpenAI SSE, or Anthropic).

### Step 8 — transform

Parses the request JSON body, normalizes it into the internal `ctx.body` representation, and collects all `x-aig-meta-*` headers into `ctx.meta`. Custom metadata is then available to routing rules and appears in request logs.

### Step 9 — routing

Evaluates the ordered routing rules loaded from the `routing_rules` table (cached for 30 s). The first matching rule wins and can override `ctx.provider`, `ctx.model`, and set a `ctx.fallbacks` chain. If no rule matches, the provider and model from the original request URL are used.

### Step 10 — BYOK

Decrypts the provider API key for the resolved `(gateway_id, provider, alias)` tuple. The plaintext key is cached for 60 seconds in the credential cache. BYOK keys are re-fetched each time the active provider changes during the fallback walk.

### Step 11 — upstream

Makes the HTTP call to the provider. On a 5xx response, retries up to `retry_count` times (default: 2). If all retries fail, walks the fallback chain. Returns `502 ALL_PROVIDERS_FAILED` if every option is exhausted.

4xx responses from the provider are returned to the client immediately with no retry.

For streaming requests (`"stream": true`), SSE chunks are flushed to the client as they arrive. The compat endpoint re-encodes provider-native SSE into OpenAI `chat.completion.chunk` format. A usage chunk with token counts is emitted just before `data: [DONE]`.

### Step 12 — detectors (response phase)

Runs the full detector pipeline (Tier 1 + Tier 2) against the provider response body before it is forwarded to the client. Blocked responses are never sent to the client.

### Step 13 — cost

Extracts token counts from the provider response (`input_tokens`, `output_tokens`, and for Anthropic: `cache_creation_tokens`, `cache_read_tokens`). Looks up the model price from the `model_price` DB table (falling back to the gateway's internal pricing table). Computes:

```
cost_usd = (input_tokens  / 1000) × input_per_1k
         + (output_tokens / 1000) × output_per_1k
```

Stores as micro-dollars to avoid floating-point precision loss, then increments the budget counter atomically.

### Step 14 — cache store

Persists the response body and cost to the cache if: the status was 200, the request was not streaming, and `cache_ttl > 0`. The key is the same SHA-256 hash computed at step 6.

---

## Log phase

The log phase runs after the response has been sent to the client. Failures here do not affect the client.

### Step 15 — logger

Writes a structured JSON row to the request log store containing all fields from `ctx`: identity, routing, status, cache, tokens, cost, timing, payload (if `log_payloads` is enabled), detector results, and custom metadata.

Payload logging can be suppressed globally (`log_payloads: false` in gateway config) or per-request (`x-aig-collect-log-payload: false` header). The log can be skipped entirely with `x-aig-collect-log: false`.

### Step 16 — metrics

Increments four Prometheus counters in the metrics store using the `provider`, `tenant_id`, `status`, and `cached` label set.

---

## See also

- [Multi-Tenancy](multi-tenancy.md) — how tenant and gateway resolution works
- [Response Caching](caching.md) — cache key construction and TTL configuration
- [Routing Rules](../routing/routing-rules.md) — rule engine conditions and actions
- [Cost Attribution](cost-attribution.md) — token counting and pricing lookup
