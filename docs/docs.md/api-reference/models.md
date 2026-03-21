# Models & Pricing API

The Models API exposes the gateway's model catalog. The Pricing API lets you read and manage per-model cost data used for spend tracking and budget enforcement.

**Base URL:** `https://<your-gateway-host>/admin/v1`

---

## Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/models` | List the model catalog |
| `GET` | `/model-prices` | List all stored model prices |
| `PUT` | `/model-prices` | Upsert a model price |
| `DELETE` | `/model-prices/{provider}/{model}` | Delete a model price |

---

## GET /models

Returns the known model catalog. This list is used for model picker dropdowns in the admin UI.

```bash
curl https://<your-gateway-host>/admin/v1/models
```

Filter by provider:

```bash
curl "https://<your-gateway-host>/admin/v1/models?provider=anthropic"
```

**Response:**

```json
{
  "models": [
    {
      "provider": "openai",
      "model": "gpt-4o",
      "context_window": 128000,
      "requires_key": true
    },
    {
      "provider": "anthropic",
      "model": "claude-opus-4-6",
      "context_window": 200000,
      "requires_key": true
    },
    {
      "provider": "ollama",
      "model": "llama3.2",
      "context_window": null,
      "requires_key": false
    }
  ]
}
```

---

## GET /model-prices

Returns all stored model pricing records. Used internally for cost calculation on every inference request.

```bash
curl https://<your-gateway-host>/admin/v1/model-prices
```

**Response:**

```json
{
  "prices": [
    {
      "provider": "openai",
      "model": "gpt-4o",
      "input_per_1k": 0.005,
      "output_per_1k": 0.015,
      "cache_write_per_1k": null,
      "cache_read_per_1k": null
    },
    {
      "provider": "anthropic",
      "model": "claude-opus-4-6",
      "input_per_1k": 0.015,
      "output_per_1k": 0.075,
      "cache_write_per_1k": 0.01875,
      "cache_read_per_1k": 0.00015
    }
  ]
}
```

### ModelPrice fields

| Field | Type | Description |
|---|---|---|
| `provider` | string | Provider identifier (e.g. `openai`, `anthropic`). |
| `model` | string | Exact model name as used in requests. |
| `input_per_1k` | number | Cost in USD per 1,000 input (prompt) tokens. |
| `output_per_1k` | number | Cost in USD per 1,000 output (completion) tokens. |
| `cache_write_per_1k` | number \| null | Cost per 1,000 tokens written to provider prompt cache (Anthropic). `null` if not applicable. |
| `cache_read_per_1k` | number \| null | Cost per 1,000 tokens read from provider prompt cache (Anthropic). `null` if not applicable. |

---

## PUT /model-prices

Create or update a price for a model. The `(provider, model)` pair is the unique key. If a record already exists it is replaced.

```bash
curl -X PUT https://<your-gateway-host>/admin/v1/model-prices \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "openai",
    "model": "gpt-4o",
    "input_per_1k": 0.005,
    "output_per_1k": 0.015
  }'
```

With prompt cache pricing (Anthropic):

```bash
curl -X PUT https://<your-gateway-host>/admin/v1/model-prices \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "anthropic",
    "model": "claude-opus-4-6",
    "input_per_1k": 0.015,
    "output_per_1k": 0.075,
    "cache_write_per_1k": 0.01875,
    "cache_read_per_1k": 0.00015
  }'
```

Custom internal model (e.g. a fine-tuned model on Azure):

```bash
curl -X PUT https://<your-gateway-host>/admin/v1/model-prices \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "azure",
    "model": "my-ft-gpt4o-deployment",
    "input_per_1k": 0.008,
    "output_per_1k": 0.020
  }'
```

---

## DELETE /model-prices/{provider}/{model}

Remove a pricing record. Subsequent requests for this model will fall back to the gateway's hardcoded cost table defaults, or report zero cost if the model is not in the defaults.

```bash
curl -X DELETE "https://<your-gateway-host>/admin/v1/model-prices/openai/gpt-4o"
```

!!! note
    URL-encode the model name if it contains slashes. For example, `accounts/fireworks/models/llama-v3-70b` becomes `accounts%2Ffireworks%2Fmodels%2Fllama-v3-70b`.

Model pricing data is maintained by Myra Security. Use the API below to view pricing and override individual entries.

---

## See also

- [Stats API](stats.md)
- [Tenants & Gateways API](tenants-gateways.md)
- [Budget & Quota Enforcement](../configuration/budgets.md)
- [Request Pipeline](../concepts/request-pipeline.md)
