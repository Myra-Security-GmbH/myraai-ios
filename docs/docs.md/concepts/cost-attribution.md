# Cost Attribution

AI Gateway computes and records the cost of every inference request, accumulates spend against configurable budget caps, and exposes aggregated cost data through the Stats API and admin UI.

---

## Cost calculation formula

```
cost_usd = (input_tokens  / 1000) × input_per_1k
         + (output_tokens / 1000) × output_per_1k
```

For Anthropic requests that use prompt caching, two additional terms are included:

```
cost_usd += (cache_write_tokens / 1000) × cache_write_per_1k
          + (cache_read_tokens  / 1000) × cache_read_per_1k
```

Token counts are extracted from the provider response at step 16 of the [request pipeline](request-pipeline.md). For streaming requests, tokens are accumulated from SSE chunks on the fly.

!!! note "Costs stored as micro-dollars"
    To avoid floating-point precision loss on small amounts, costs are stored in the database as integer micro-dollars (`cost_usd × 1,000,000`). They are converted back to USD when returned by the API and displayed in the admin UI.

---

## Anthropic prompt caching fields

Anthropic's prompt caching feature writes frequently-used content (system prompts, document context) to a cache and bills cache reads at a steep discount. AI Gateway tracks and reports these fields separately:

| Field | Typical price relative to input |
|-------|-------------------------------|
| `cache_write_tokens` | 1.25× input price |
| `cache_read_tokens` | 0.10× input price |

Both fields appear in request logs and are included in the usage chunk emitted for streaming compat endpoint responses.

---

## Pricing sources

The gateway resolves model prices using a two-tier lookup:

**Tier 1 — `model_price` database table**

Runtime-configurable via the admin API. Takes precedence over hardcoded defaults. This allows updating prices for new model versions without redeploying.

```bash
# Upsert a model price
curl -X PUT https://<your-gateway-host>/admin/v1/model-prices \
  -H 'Content-Type: application/json' \
  -d '{
    "provider": "openai",
    "model": "gpt-4o",
    "input_per_1k": 0.0025,
    "output_per_1k": 0.010,
    "cache_write_per_1k": null,
    "cache_read_per_1k": null
  }'
```

**Tier 2 — The gateway's internal pricing table**

Used when no matching row exists in the database. These cover the most common models across all supported providers.

---

## Pre-loaded model prices (hardcoded fallbacks)

The following models have hardcoded fallback prices. All prices are USD per 1,000 tokens.

### OpenAI

| Model | Input/1K | Output/1K |
|-------|---------|----------|
| gpt-4o | $0.0025 | $0.010 |
| gpt-4o-mini | $0.00015 | $0.0006 |
| gpt-4-turbo | $0.010 | $0.030 |
| gpt-3.5-turbo | $0.0005 | $0.0015 |

### Anthropic

| Model | Input/1K | Output/1K | Cache write/1K | Cache read/1K |
|-------|---------|----------|---------------|--------------|
| claude-opus-4-6 | $0.015 | $0.075 | $0.01875 | $0.0015 |
| claude-sonnet-4-6 | $0.003 | $0.015 | $0.00375 | $0.0003 |
| claude-haiku-4-5-20251001 | $0.0008 | $0.004 | $0.001 | $0.00008 |
| claude-3-5-sonnet-20241022 | $0.003 | $0.015 | $0.00375 | $0.0003 |
| claude-3-opus-20240229 | $0.015 | $0.075 | $0.01875 | $0.0015 |

### Gemini / Vertex AI

| Model | Input/1K | Output/1K |
|-------|---------|----------|
| gemini-1.5-pro | $0.00125 | $0.005 |
| gemini-1.5-flash | $0.000075 | $0.0003 |
| gemini-2.0-flash | $0.0001 | $0.0004 |

### Mistral

| Model | Input/1K | Output/1K |
|-------|---------|----------|
| mistral-large-latest | $0.002 | $0.006 |
| mistral-small-latest | $0.0002 | $0.0006 |
| codestral-latest | $0.0003 | $0.0009 |

### Groq

| Model | Input/1K | Output/1K |
|-------|---------|----------|
| llama-3.3-70b-versatile | $0.00059 | $0.00079 |
| llama-3.1-8b-instant | $0.00005 | $0.00008 |

### xAI

| Model | Input/1K | Output/1K |
|-------|---------|----------|
| grok-3 | $0.003 | $0.015 |
| grok-3-mini | $0.0003 | $0.0005 |

### DeepSeek

| Model | Input/1K | Output/1K |
|-------|---------|----------|
| deepseek-chat | $0.00027 | $0.0011 |
| deepseek-reasoner | $0.00055 | $0.00219 |

Model pricing data is maintained by Myra Security and updated automatically. You can view and override individual model prices via the [Models & Pricing API](../api-reference/models.md).

---

## Budget enforcement

Cost attribution feeds directly into the budget enforcement system:

- **Per-gateway budget** — set `budget_usd` in the gateway config; returns `429 QUOTA_EXCEEDED` once the accumulated spend reaches the cap
- **Per-token budget** — set `budget_usd` on an auth token; takes precedence over the gateway budget
- **Reset** — `DELETE /admin/v1/gateways/{id}/budget` resets the gateway counter; `DELETE /admin/v1/users/{id}/budget` resets all token budgets for a user

---

## See also

- [Request Pipeline](request-pipeline.md) — step 16 (cost) in the middleware chain
- [Budgets and Quotas](../configuration/budgets.md) — configuring and resetting spend caps
- [Response Caching](caching.md) — `saved_cost_usd` logged on cache hits
- [Models API](../api-reference/models.md) — managing model prices at runtime
