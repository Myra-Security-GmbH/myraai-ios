# Budget & Quota Enforcement

The gateway tracks cumulative spend per gateway and per token and blocks requests once a configured budget is exhausted. Budgets are useful for hard cost caps on individual clients or on entire gateways.

## Budget hierarchy

Two budget levels exist and are evaluated independently:

1. **Per-token budget** (`auth_token.budget_usd`) — tracks spend for one specific token. Takes precedence in the sense that it is checked first; if the token budget is exhausted the request is blocked regardless of the gateway budget.
2. **Per-gateway budget** (`gateway.budget_usd`) — tracks aggregate spend across all tokens on that gateway. Acts as a hard cap for the gateway as a whole.

Either level can be set independently. A gateway with no `budget_usd` set (`null`) has no gateway-level cap. A token with no `budget_usd` has no token-level cap.

## Cost calculation

Cost is computed from the token usage returned in the provider response (prompt tokens + completion tokens) combined with per-model pricing data maintained by the gateway. The result is stored internally as **micro-dollars** (USD × 10⁶) for integer precision.

Spend is incremented atomically after each successful inference response. Streaming responses increment spend when the final `[DONE]` chunk is processed and usage data is available.

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

This applies whether the token budget or the gateway budget triggered the block.

## Resetting budgets

### Reset gateway budget

Clears the accumulated spend counter for a gateway, allowing requests to flow again up to the configured `budget_usd`.

```bash
curl -X DELETE https://your-gateway-host/admin/v1/gateways/{id}/budget \
  -H "x-aig-token: <admin-token>"
```

### Reset user token budgets

Clears the accumulated spend for all tokens belonging to a user.

```bash
curl -X DELETE https://your-gateway-host/admin/v1/users/{user_id}/budget \
  -H "x-aig-token: <admin-token>"
```

!!! warning
    Budget resets are immediate and irreversible. There is no confirmation step. Automate resets with care — for example, a monthly cron job that resets at the start of each billing period.

## Setting budgets

### Gateway-level budget

```bash
curl -X PATCH https://your-gateway-host/admin/v1/gateways/{id} \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "budget_usd": 500.00
    }
  }'
```

### Per-token budget

Set when creating a token:

```bash
curl -X POST https://your-gateway-host/admin/v1/gateways/{id}/tokens \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "label": "client-a",
    "user_id": "user_123",
    "scopes": ["inference"],
    "budget_usd": 20.00
  }'
```

## Best practices

| Scenario | Recommendation |
|---|---|
| Absolute cost cap for the gateway | Set `gateway.budget_usd`; reset monthly. |
| Per-client spend limit | Set `budget_usd` on each client's token. |
| Development / internal use | Leave budget `null`; rely on rate limiting instead. |
| Multi-tenant with shared cap | Use gateway budget as the shared ceiling; per-token for individual client limits. |

!!! note
    The gateway budget and per-token budget are not linked. Exhausting the gateway budget blocks all requests even if individual token budgets have remaining balance.

## See also

- [Rate Limiting](rate-limiting.md)
- [Gateway Configuration](gateway-config.md)
- [Authentication & Tokens](../security/authentication.md)
- [API Reference: Users & Tokens](../api-reference/users-tokens.md)
