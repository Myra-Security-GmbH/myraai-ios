# Response Caching

AI Gateway implements an exact-match response cache that short-circuits the entire upstream call when a matching request is found. Cache hits return the stored response immediately, saving both cost and latency.

---

## Cache key construction

The cache key is a SHA-256 hash computed from:

```
SHA-256( provider + ":" + model + ":" + canonical_json_body )
```

**Canonical JSON body** is the request body with the following fields excluded before hashing:

| Excluded field | Reason |
|---------------|--------|
| `stream` | Streaming vs. non-streaming is a delivery preference, not a semantic difference |
| `user` | User identifier is not part of the prompt semantics |
| `metadata` | Client-side metadata should not affect cache lookup |

All other fields (messages, temperature, max_tokens, system, tools, etc.) are included. The body is serialized with keys in sorted order to ensure identical prompts produce identical keys regardless of field ordering.

!!! note "Exact match only"
    The cache is purely exact-match. Two requests with identical prompts but different temperature values will produce different cache keys and will not share a cache entry. Semantic caching (vector similarity) is planned but not yet implemented.

---

## Storage backends

| Backend | Config | Notes |
|---------|--------|-------|
| In-process | Default (single-server) | Cached in-process for fast retrieval. |
| Distributed | Contact Myra Security for cache backend configuration | Required for multi-node deployments; keys namespaced per tenant/gateway |

The stored format is `{body, cost_usd}` — the original response body and the cost that was computed when the entry was written.

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

When a cache hit is found at step 6 of the [request pipeline](request-pipeline.md):

1. The stored response body is returned immediately with HTTP 200
2. The `X-AIG-Cache: HIT` response header is set
3. Steps 7–17 (detectors, routing, BYOK, upstream, cost, cache-store) are skipped
4. The log phase still runs; `cached = true`, `saved_cost_usd`, and `saved_latency_ms` are recorded

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
