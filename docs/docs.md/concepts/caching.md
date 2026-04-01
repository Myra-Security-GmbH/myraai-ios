---
title: Response caching
description: How AI Gateway exact-match and semantic caching work, cache key construction, TTL configuration, and savings tracking.
---

# Response caching

AI Gateway by Myra Security implements an exact-match response cache that short-circuits the entire upstream call when a matching request is found. Cache hits return the stored response immediately, saving both cost and latency.

---

## When to enable caching

Enable caching when your workload includes repeated identical prompts — for example, a support chatbot that frequently receives the same questions, or a pipeline that runs the same classification prompt over many inputs.

**Not useful for:** conversational flows where each message is unique, or prompts that vary by temperature or other parameters (any change to the request produces a different cache key and a cache miss).

> 💡 **Note:** The cache is purely exact-match. Two requests with identical prompts but different `temperature` or `max_tokens` values do not share a cache entry. Only byte-for-byte identical requests hit the cache.

> ⭐ **Example:** How the cache key is constructed — The cache key is computed from the provider name, model name, and the request body. The `stream`, `user`, and `metadata` fields are excluded before hashing — these are delivery preferences that do not affect the response of the model. All other fields (messages, temperature, max_tokens, system, tools, etc.) are included. Field order within the JSON object does not matter.

---

## TTL configuration

Cache TTL (time to live) is configured per gateway in the gateway config JSON:

```json
{
  "cache_ttl": 300
}
```

| **Value** | **Behaviour** |
|-----------|--------------|
| `0` (default) | Caching disabled |
| `> 0` | Cache entries live for this many seconds |

> 💡 **Note:** There is no way to set a different TTL per model or per token — the TTL applies to all cache entries for the gateway.

---

## Cache hit behaviour

On a cache hit:

1. The stored response body is returned immediately with HTTP 200.
2. The `X-AIG-Cache: HIT` response header is set.
3. The provider is not called.
4. The log entry records `cached = true`, `saved_cost_usd`, and `saved_latency_ms`.

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

For every cache hit, the gateway logs the following fields:

| **Field** | **Description** |
|-----------|-----------------|
| `saved_cost_usd` | The `cost_usd` value stored when the entry was written (the cost that would have been incurred) |
| `saved_latency_ms` | Estimated upstream latency saved, based on the average upstream latency for the provider/model |

These fields are visible in the request logs and aggregated in the Stats API response under the `today`, `hour`, and other period windows.

---

## What is not cached

The following responses are never written to the cache:

- **Streaming responses** — `"stream": true` requests are passed through as SSE and cannot be buffered for caching.
- **Non-200 responses** — provider errors, gateway blocks, and rate limit responses are not cached.
- **Requests when `cache_ttl` is 0** — the default; caching must be explicitly enabled per gateway.

---

## Disabling cache per request

There is no per-request cache bypass header. To force a cache miss:

- Change a field that is included in the cache key (e.g. add a unique value to the messages).
- Temporarily set `cache_ttl: 0` on the gateway config.

---

## Semantic caching

Exact-match caching only helps when two requests are byte-for-byte identical. **Semantic caching** catches near-identical prompts that differ in phrasing — for example, "What is the capital of France?" and "Tell me the capital city of France?" map to essentially the same response.

When enabled, the gateway computes an embedding vector for each incoming prompt and compares it against stored embeddings using cosine similarity. If the best match exceeds the configured threshold, the stored response is returned immediately without calling the provider.

### When to use semantic caching

Semantic caching is most effective for:

- **FAQ / support bots** — users rephrase the same small set of questions in slightly different ways.
- **Classification pipelines** — similar inputs map to identical labels.
- **Content generation with stable topics** — "Write a short bio for Einstein" vs "Give me a brief biography of Albert Einstein".

Not recommended for:

- Conversational flows where context changes with every message.
- Prompts where small phrasing differences meaningfully change the correct answer.
- Low-latency requirements (the embedding call adds ~50 ms per miss; see note below).

### Configuration

```json
{
  "semantic_cache": {
    "enabled": true,
    "threshold": 0.95,
    "embedding_url": "https://api.openai.com/v1/embeddings",
    "embedding_api_key": "sk-...",
    "embedding_model": "text-embedding-3-small",
    "max_candidates": 100,
    "ttl": 86400
  }
}
```

| **Field** | **Type** | **Default** | **Description** |
|-----------|----------|-------------|-----------------|
| `enabled` | boolean | `false` | Activates semantic caching |
| `threshold` | number | `0.95` | Cosine similarity cutoff. Hits require similarity ≥ threshold. |
| `embedding_url` | string | — | OpenAI-compatible embeddings endpoint |
| `embedding_api_key` | string | — | Bearer token for the embedding endpoint |
| `embedding_model` | string | `text-embedding-3-small` | Embedding model name |
| `max_candidates` | integer | `100` | Maximum stored embeddings to compare per query |
| `ttl` | integer | `86400` | Seconds before a stored embedding expires |

### Threshold guidance

| **Threshold** | **Behaviour** |
|---------------|--------------|
| `0.97–1.00` | Very strict — only near-identical rephrasing hits |
| `0.95` (default) | Balanced — catches common reformulations, avoids false positives |
| `0.92–0.94` | Loose — higher hit rate; risk of semantically adjacent but distinct prompts sharing a cached response |

### Embedding model choice

Any OpenAI-compatible embeddings endpoint works:

- **`text-embedding-3-small`** (OpenAI) — recommended; small, fast, 1536 dimensions
- **`text-embedding-3-large`** (OpenAI) — higher quality; 3072 dimensions, more storage
- **Ollama** (`http://ollama:11434/api/embeddings`) — fully on-premise; set `embedding_api_key` to empty string

### How a semantic hit is served

On a semantic cache hit:

1. The stored response body is returned immediately with HTTP 200.
2. The `X-AIG-Cache: SEMANTIC_HIT` response header is set.
3. The `X-AIG-Similarity: 0.97` header indicates the cosine similarity score.
4. The provider is not called.

### Latency note

The embedding call adds approximately 50 ms on a cache **miss**. LLM inference calls typically take between 500 ms and 3 s, so the overhead is small relative to the savings on hits. The embedding storage step on writes is fully asynchronous and never adds latency to the response path.

> 💡 **Note:** Requests with `"stream": true` are not stored in or served from the semantic cache. Exact-match caching also does not apply to streaming requests.

---

## See also

- [Request pipeline](request-pipeline.md) — where cache check and cache store fit in the middleware chain
- [Cost attribution](cost-attribution.md) — how `cost_usd` is computed and stored with cache entries
- [Gateway config reference](../configuration/gateway-config.md) — `cache_ttl` and other gateway settings
