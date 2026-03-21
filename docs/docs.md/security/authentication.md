# Authentication & Tokens

The gateway uses opaque bearer tokens for inference authentication. Tokens are short-lived or long-lived strings issued by the admin API. The gateway stores only the SHA-256 hash of each token — the plaintext is returned once at creation time and never stored again.

## Token acceptance order

The gateway looks for an auth token in the following header order. The first matching header is used:

1. `x-aig-token: <token>`
2. `Authorization: Bearer <token>`
3. `x-api-key: <token>`

This order lets you use the gateway as a drop-in replacement for OpenAI-compatible clients that send `Authorization: Bearer` or `x-api-key` without reconfiguration.

## Token security model

- Tokens are hashed with **SHA-256** before storage
- The plaintext token is returned **once** in the creation response — copy it immediately
- If a token is lost, delete it and create a new one; there is no recovery path
- The hash stored in the database cannot be reversed to recover the plaintext

## Token fields

| Field | Type | Description |
|---|---|---|
| `label` | string | Human-readable name for the token. |
| `user_id` | string | Associates the token with a user identity for audit logs and budget tracking. |
| `scopes` | array of strings | Permissions granted by this token (e.g. `["inference"]`). |
| `expires_at` | string \| null | ISO-8601 expiration timestamp. `null` = no expiry. |
| `rate_limit` | object \| null | Per-token rate limit: `{"requests": N, "window_sec": S}`. |
| `budget_usd` | number \| null | Per-token spend cap in USD. `null` = no cap. |

## Role-based access control

Each token's `user_id` maps to a user record which has a `role` field:

| Role | Inference access | Admin API access |
|---|---|---|
| `admin` | All gateways | Full |
| `member` | Assigned gateways only | None |
| `viewer` | 403 on all inference | None |

!!! warning
    The `viewer` role is intended for users who need read access to the admin UI only. Sending an inference request with a viewer-role token always returns `403 Forbidden`.

## Disabling authentication

For development or internal networks, authentication can be disabled per gateway:

```bash
curl -X PATCH https://your-gateway-host/admin/v1/gateways/{id} \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"config": {"auth_required": false}}'
```

!!! warning
    Never set `auth_required: false` in production. Any caller with network access to the gateway endpoint can make inference requests and incur costs.

## Creating tokens

```bash
curl -X POST https://your-gateway-host/admin/v1/gateways/{id}/tokens \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "label": "production-client",
    "user_id": "user_42",
    "scopes": ["inference"],
    "expires_at": "2026-12-31T23:59:59Z",
    "rate_limit": {
      "requests": 100,
      "window_sec": 60
    },
    "budget_usd": 50.00
  }'
```

The response includes the plaintext token in a `token` field. Store it securely — it is not retrievable after this response.

```json
{
  "id": "tok_abc123",
  "token": "aig_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "label": "production-client",
  "user_id": "user_42",
  "scopes": ["inference"],
  "expires_at": "2026-12-31T23:59:59Z",
  "created_at": "2026-03-21T10:00:00Z"
}
```

## Listing and revoking tokens

**List tokens for a gateway:**

```bash
curl https://your-gateway-host/admin/v1/gateways/{id}/tokens \
  -H "x-aig-token: <admin-token>"
```

**Revoke a token:**

```bash
curl -X DELETE https://your-gateway-host/admin/v1/gateways/{id}/tokens/{token_id} \
  -H "x-aig-token: <admin-token>"
```

Revocation is immediate. In-flight requests that have already passed the auth phase will complete normally.

## See also

- [Rate Limiting](../configuration/rate-limiting.md)
- [Budget & Quota Enforcement](../configuration/budgets.md)
- [Gateway Configuration](../configuration/gateway-config.md)
- [API Reference: Users & Tokens](../api-reference/users-tokens.md)
