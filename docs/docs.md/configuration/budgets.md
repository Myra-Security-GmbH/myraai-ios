# Budget & Quota Enforcement

The gateway tracks cumulative spend per token, per tenant, and per gateway, and blocks requests once a configured budget is exhausted. Budgets are useful for hard cost caps on individual clients, tenants, or entire gateways.

## Budget hierarchy

Three budget levels exist and are evaluated in order: per-token → per-tenant → per-gateway.

1. **Per-token budget** — tracks spend for one specific auth token. If the token budget is exhausted the request is blocked regardless of the other budget levels.
2. **Per-tenant budget** — tracks aggregate spend for all requests across a tenant (all gateways belonging to that tenant). Set via the `tenant_budget_usd` field in the gateway config. Blocks requests for the entire tenant when exhausted.
3. **Per-gateway budget** — tracks aggregate spend across all tokens on one gateway. Acts as a hard cap for that gateway as a whole.

All three levels are independent. A request must pass all applicable checks before reaching the provider. Setting any level to `null` disables that level's budget enforcement.

## Budget periods

Each budget level has a configurable **period** — the window over which spend is accumulated. At the start of each new period, spend resets automatically with no manual action required.

| Config field | Scope | Default | Options |
|---|---|---|---|
| `budget_period` | Gateway | `monthly` | `daily`, `weekly`, `monthly` |
| `tenant_budget_period` | Tenant | `monthly` | `daily`, `weekly`, `monthly` |
| `token_budget_period` | Token (auth_token) | `monthly` | `daily`, `weekly`, `monthly` |

!!! note
    Automatic period reset is distinct from a manual budget reset (which clears accumulated spend immediately). Manual resets are still available for one-off corrections.

## Cost calculation

Cost is computed from the token usage returned in the provider response (prompt tokens + completion tokens) combined with per-model pricing data maintained by the gateway.

Spend is incremented after each successful inference response. Streaming responses increment spend when the final chunk is processed and usage data is available.

!!! note
    Cost data depends on the gateway's internal model pricing table. If a model's pricing is not known, spend may not be tracked for that model. Check the model list endpoint to confirm pricing coverage.

## QUOTA_EXCEEDED response

When a budget is exhausted, the gateway returns `HTTP 429`:

```json
{
  "error": {
    "code": "QUOTA_EXCEEDED",
    "message": "Budget limit reached"
  }
}
```

This applies whether the per-token, per-tenant, or per-gateway budget triggered the block.

## Using the admin UI

### Set a gateway budget

1. Open **Gateways** and click the gateway.
2. Open the **Config** tab.
3. Set the **Budget (USD)** field to your desired monthly cap.
4. Click **Save**.

### Set a per-token budget

Set the budget when creating or editing a token in the **Users** module — enter the spend cap in the **Budget (USD)** field.

### Reset a budget

To clear accumulated spend so requests can flow again, use the **Reset Budget** action:

- **Gateway budget**: In the **Config** tab, use the **Reset Budget** button.
- **User token budgets**: In the **Users** module, use the **Reset Budget** action on the user.

!!! warning
    Budget resets are immediate and irreversible. There is no confirmation step. Automate resets with care — for example, a monthly scheduled task that resets at the start of each billing period.

## Best practices

| Scenario | Recommendation |
|---|---|
| Absolute cost cap for the gateway | Set `gateway.budget_usd`; reset monthly. |
| Per-client spend limit | Set `budget_usd` on each client's token. |
| Development / internal use | Leave budget `null`; rely on rate limiting instead. |
| Multi-tenant with shared cap | Use gateway budget as the shared ceiling; per-token for individual client limits. |

!!! note
    The gateway budget and per-token budget are not linked. Exhausting the gateway budget blocks all requests even if individual token budgets have remaining balance.

## API

Budget fields and reset endpoints are part of the gateway and user APIs. See [Tenants & Gateways API](../api-reference/tenants-gateways.md) and [Users & Tokens API](../api-reference/users-tokens.md) for examples.

## See also

- [Rate Limiting](rate-limiting.md)
- [Gateway Configuration](gateway-config.md)
- [Authentication & Tokens](../security/authentication.md)
- [API Reference: Users & Tokens](../api-reference/users-tokens.md)
