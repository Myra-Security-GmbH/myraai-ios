# Response Caching

AI Gateway implements an exact-match response cache that short-circuits the entire upstream call when a matching request is found. Cache hits return the stored response immediately, saving both cost and latency.

---

## When to enable caching

Enable caching when your workload includes repeated identical prompts — for example, a support chatbot that frequently receives the same questions, or a pipeline that runs the same classification prompt over many inputs.

**Not useful for:** conversational flows where each message is unique, or prompts that vary by temperature or other parameters (any change to the request produces a different cache key and a cache miss).

!!! note "Exact match only"
    The cache is purely exact-match. Two requests with identical prompts but different `temperature` or `max_tokens` values will not share a cache entry. Only byte-for-byte identical requests hit the cache.

??? info "How the cache key is constructed"
    The cache key is computed from the provider name, model name, and the request body. The `stream`, `user`, and `metadata` fields are excluded before hashing — these are delivery preferences that don't affect the model's response. All other fields (messages, temperature, max_tokens, system, tools, etc.) are included. Field order within the JSON object does not matter.

---

## TTL configuration

Cache TTL is configured per gateway in the gateway config JSON:

```json
{
  "cache_ttl": 300
}
```

| Value | Behavior |
|-------|---------|
| `0` (default) | Caching disabled |
| `> 0` | Cache entries live for this many seconds |

There is no way to set a different TTL per model or per token — the TTL applies to all cache entries for the gateway.

---

## Cache hit behavior

On a cache hit:

1. The stored response body is returned immediately with HTTP 200
2. The `X-AIG-Cache: HIT` response header is set
3. The provider is not called
4. The log entry records `cached = true`, `saved_cost_usd`, and `saved_latency_ms`

```bash
# Verify a cache hit
curl -i -X POST https://<your-gateway-host>/v1/myapp/prod/openai/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"What is 2+2?"}]}'

# Second identical request
HTTP/1.1 200 OK
X-AIG-Cache: HIT
```

---

## Savings tracking

For every cache hit, the gateway logs:

| Field | Description |
|-------|-------------|
| `saved_cost_usd` | The `cost_usd` value stored when the entry was written (the cost that would have been incurred) |
| `saved_latency_ms` | Estimated upstream latency saved, based on the average upstream latency for the provider/model |

These fields are visible in the request logs and aggregated in the Stats API response under the `today`, `hour`, and other period windows.

---

## What is NOT cached

The following responses are never written to the cache:

- **Streaming responses** — `"stream": true` requests are passed through as SSE and cannot be buffered for caching
- **Non-200 responses** — provider errors, gateway blocks, and rate limit responses are not cached
- **Requests when `cache_ttl` is 0** — the default; caching must be explicitly enabled per gateway

---

## Disabling cache per request

There is no per-request cache bypass header. To force a cache miss you must either:

- Change a field that is included in the cache key (e.g., add a unique value to the messages)
- Temporarily set `cache_ttl: 0` on the gateway config

---

## See also

- [Request Pipeline](request-pipeline.md) — where cache check and cache store fit in the middleware chain
- [Cost Attribution](cost-attribution.md) — how `cost_usd` is computed and stored with cache entries
- [Gateway Config Reference](../configuration/gateway-config.md) — `cache_ttl` and other gateway settings
