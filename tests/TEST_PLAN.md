# AI Gateway — Test Plan

## How to run

```bash
# Unit tests (no nginx required, uses busted)
busted tests/unit/

# Integration tests (nginx must be running on 127.0.0.1:8081)
busted tests/integration/

# Seed test data first
AIG_CONFIG=config/gateway.lua resty -I src/ tests/fixtures/seed.lua
```

---

## Unit tests (already written)

| File | Covers |
|---|---|
| `test_cache_key.lua` | SHA-256 key construction, stream exclusion, field exclusion |
| `test_dlp.lua` | block / scrub / flag actions, pattern matching |
| `test_ip_allowlist.lua` | CIDR matching, exact IP, multi-CIDR |
| `test_routing_engine.lua` | Rule evaluation, prefix/eq/regex ops, fallback chain, no-match |
| `test_provider_openai.lua` | URL building, header construction, response parsing, SSE chunk parsing |

---

## Unit tests to write

### `tests/unit/test_provider_anthropic.lua`
- `build_request` separates system message correctly
- `build_request` maps OpenAI stop → stop_sequences array
- `parse_response` extracts text blocks and token counts
- `parse_sse_chunk` accumulates input tokens from `message_start`, output from `message_delta`
- `parse_sse_chunk` returns `done=true` on `message_stop`

### `tests/unit/test_provider_gemini.lua`
- `base_url` appends `streamGenerateContent?alt=sse` when `stream=true`
- `build_request` converts system message to `system_instruction`
- `build_request` maps assistant role → `model`
- `parse_response` extracts candidate text and `usageMetadata` token counts

### `tests/unit/test_provider_compat.lua`
- `infer_provider("gpt-4o")` → `"openai"`
- `infer_provider("claude-3-opus")` → `"anthropic"`
- `infer_provider("gemini-1.5-pro")` → `"gemini"`
- `infer_provider("unknown-model")` → `nil`
- `provider_path("/compat/chat/completions")` → `"/v1/chat/completions"`

### `tests/unit/test_cost.lua`
- Cost calculation for known models (input + output tokens)
- Zero cost when pricing not found
- Budget counter incremented in micro-dollars
- `cost_table.calculate` returns 0 for unknown provider/model (no error)

### `tests/unit/test_rate_limit.lua`
- First N requests within limit are allowed
- Request N+1 is denied
- Counter resets after window expires (time-travel via mock `ngx.now`)
- Different gateway IDs don't share counters

### `tests/unit/test_crypto.lua`
- `encrypt` then `decrypt` round-trips correctly
- Different passphrases produce different ciphertext
- Corrupt ciphertext returns error (not panic)
- `sha256_hex` produces 64-char lowercase hex
- `random_bytes(n)` returns exactly n bytes

### `tests/unit/test_auth_byok.lua`
- `store_key` + `get_key` round-trips the plaintext API key
- Cached key is returned on second call (no DB hit)
- Wrong passphrase (different master key) fails to decrypt
- `get_key` with unknown alias returns nil + error string

### `tests/unit/test_tenant_middleware.lua`
- `/v1/acme/main/openai/v1/chat/completions` → correct slug/provider/path
- `/v1/acme/main/compat/chat/completions` → `is_compat=true`, provider=`compat`
- Unknown provider returns 400
- Missing gateway segment returns 400
- Path with extra slashes parses correctly

### `tests/unit/test_guardrails.lua`
- Clean prompt passes through
- Prompt matching `self_harm` pattern blocked with 400
- Guardrails disabled (`enabled=false`) → always passes
- Empty `block_categories` → always passes

### `tests/unit/test_pipeline.lua`
- Middlewares run in order (use a list of recorders)
- A middleware that calls `errors.send()` stops the chain
- A middleware that errors unexpectedly returns 500
- Module load failure returns 500

---

## Integration tests to write

These require nginx running on `127.0.0.1:8081` with seeded test data.

### `tests/integration/test_healthz.lua`
```
GET /healthz → 200 "ok"
```

### `tests/integration/test_auth.lua`
- Request with valid `x-aig-token` → upstream attempted (not 401)
- Request with wrong token → 401
- Request with expired token → 401
- Gateway with `auth_required=false` → passes without token
- `Authorization: Bearer {token}` header also accepted

### `tests/integration/test_routing.lua`
- Request to `/v1/{tenant}/{gateway}/openai/v1/chat/completions` reaches OpenAI adapter
- Routing rule overrides model in request body
- Compat endpoint `/compat/chat/completions` with `gpt-4o` routes to OpenAI
- Compat endpoint with `claude-*` routes to Anthropic
- Unknown model on compat endpoint → 400

### `tests/integration/test_caching.lua`
- First identical request → `X-AIG-Cache: MISS`
- Second identical request within TTL → `X-AIG-Cache: HIT`, same body
- Different model → cache miss (different key)
- `stream=true` request is never cached
- Cache TTL=0 (disabled) → always MISS
- Response after TTL expiry → MISS again

### `tests/integration/test_rate_limiting.lua`
- 100 requests succeed (limit = 100/min)
- 101st request → 429 with `Retry-After` header
- Rate limit counter is per-gateway (two gateways don't interfere)
- `X-RateLimit-Remaining` decrements correctly

### `tests/integration/test_dlp_integration.lua`
- Request with email in prompt + `action=block` → 400 DLP_BLOCKED
- Request with email in prompt + `action=scrub` → upstream called with `[REDACTED]`
- Scrubbed body does not reach the log payload

### `tests/integration/test_streaming.lua`
- Request with `stream=true` → response is `text/event-stream`
- Chunks arrive incrementally (chunked transfer)
- After stream ends, request log row exists in logs.db with token counts
- Streaming responses are not written to cache

### `tests/integration/test_metrics.lua`
- `GET /metrics` → 200, `text/plain`
- After one request: `aig_requests_total` counter > 0
- Cache hit increments `cached=1` label counter
- Error response increments the error status label

### `tests/integration/test_quota.lua`
- Set `budget_usd=0.0001` on gateway; make enough calls to exceed it
- First request succeeds; subsequent requests → 429 QUOTA_EXCEEDED
- Resetting the counter (admin API) allows requests again

### `tests/integration/test_fallback.lua`
- Primary provider key is invalid → gateway retries, then tries fallback provider
- All providers fail → 502 ALL_PROVIDERS_FAILED
- Fallback provider success is logged with the fallback provider name

### `tests/integration/test_logs.lua`
- After a request, a row exists in `logs.db` with correct tenant/gateway/model
- `x-aig-collect-log: false` → no row inserted
- `x-aig-collect-log-payload: false` → row exists but `prompt`/`response` are NULL
- `x-aig-meta-session: abc` → `meta.session = "abc"` in log row

---

## Mock provider server

For integration tests that must not hit real LLMs, add a mock provider:

```
tests/
  mock_provider/
    server.lua    ← resty HTTP server that returns canned OpenAI responses
    responses/
      chat.json
      error_500.json
      streaming.txt   ← SSE chunks
```

The mock listens on `127.0.0.1:19000`. Integration tests point the gateway at it
by setting the provider base URL via a gateway config override:

```lua
-- In test setup:
storage.upsert_gateway(tenant_id, "mock", {
    auth_required = false,
    provider_overrides = { openai = { base_url = "http://127.0.0.1:19000" } }
})
```
