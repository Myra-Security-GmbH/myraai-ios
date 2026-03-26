# Model Prices

The **Model Prices** page lets administrators view and maintain the per-model pricing table that the gateway uses for cost attribution. Pricing data is used to convert token counts into USD spend values shown throughout the dashboard, analytics, and budget enforcement.

Navigate to **Model Prices** in the left sidebar (visible to `admin` users only).

---

## Price table

The table lists all models that have pricing configured:

| Column | Description |
|--------|-------------|
| Provider | Provider slug (e.g. `openai`, `anthropic`) |
| Model | Model name as used in inference requests |
| Input / 1K | Cost in USD per 1,000 input (prompt) tokens |
| Output / 1K | Cost in USD per 1,000 output (completion) tokens |
| Cache Write / 1K | Cost per 1,000 tokens written to provider-side prompt cache (optional) |
| Cache Read / 1K | Cost per 1,000 tokens read from provider-side prompt cache (optional) |
| Updated | Timestamp of the last price update |

Click any row to edit its prices. Entries can be deleted by selecting a row and using the delete action.

---

## Adding a model price

Click **+ New Price**.

| Field | Required | Description |
|-------|----------|-------------|
| Provider | Yes | One of the supported provider slugs |
| Model | Yes | Model name exactly as sent in inference requests |
| Input / 1K | Yes | USD price per 1,000 input tokens |
| Output / 1K | Yes | USD price per 1,000 output tokens |
| Cache Write / 1K | No | USD price per 1,000 prompt-cache write tokens |
| Cache Read / 1K | No | USD price per 1,000 prompt-cache read tokens |

Click **Save** to apply the new price.

---

## Editing a model price

Click the row for the model you want to update, change the prices, then click **Save**.

!!! note
    Provider and model name cannot be changed on edit — delete the entry and recreate it if you need to correct the model name.

---

## Effect on cost attribution

The gateway looks up model prices at log-write time for every inference response. If a model has no entry in this table, the gateway falls back to built-in default prices (where available). Requests to models with no matching price and no built-in fallback are logged with `cost_usd = 0` and do not count against budgets.

See [Cost Attribution](../concepts/cost-attribution.md) for details on how token counts and prices combine to produce the final cost value.

---

## API

Model prices can also be managed via the Admin API:

```bash
# List all model prices
curl "https://<your-gateway-host>/admin/v1/model-prices" \
  -H "x-aig-token: <admin-token>"

# Set or update a price (upsert)
curl -X PUT "https://<your-gateway-host>/admin/v1/model-prices" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "openai",
    "model": "gpt-4o",
    "input_per_1k": 0.0025,
    "output_per_1k": 0.01
  }'

# Delete a price entry
curl -X DELETE "https://<your-gateway-host>/admin/v1/model-prices/openai/gpt-4o" \
  -H "x-aig-token: <admin-token>"
```

See [Models API](../api-reference/models.md) for the full endpoint reference.

---

## See also

- [Cost Attribution](../concepts/cost-attribution.md)
- [Budget & Quota Enforcement](budgets.md)
- [Models API](../api-reference/models.md)
