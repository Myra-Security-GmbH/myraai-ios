# Users & Tokens API

Users are identity records within a tenant. Each user has a role and can hold multiple auth tokens. Tokens are the credentials used to authenticate inference requests. Gateway access grants control which gateways a user's tokens are valid for.

**Base URL:** `https://<your-gateway-host>/admin/v1`

---

## Endpoints

### Users

| Method | Path | Description |
|---|---|---|
| `GET` | `/tenants/{id}/users` | List users for a tenant |
| `POST` | `/tenants/{id}/users` | Create a user |
| `PATCH` | `/users/{id}` | Update a user |
| `DELETE` | `/users/{id}` | Delete a user (disables all their tokens) |
| `DELETE` | `/users/{id}/budget` | Reset all token spend counters for a user |

### Tokens

| Method | Path | Description |
|---|---|---|
| `GET` | `/gateways/{id}/tokens` | List all tokens for a gateway |
| `POST` | `/gateways/{id}/tokens` | Create a gateway-scoped token |
| `DELETE` | `/gateways/{id}/tokens/{tid}` | Revoke a token |
| `GET` | `/users/{id}/tokens` | List tokens belonging to a user |
| `POST` | `/users/{id}/tokens` | Create a user-scoped token |

### Access control

| Method | Path | Description |
|---|---|---|
| `GET` | `/users/{id}/gateways` | List gateways the user can access |
| `POST` | `/users/{id}/gateways/{gw_id}` | Grant a user access to a gateway |
| `DELETE` | `/users/{id}/gateways/{gw_id}` | Revoke a user's access to a gateway |

---

## Users

### List users

```bash
curl https://<your-gateway-host>/admin/v1/tenants/{tenant_id}/users
```

**Response:**

```json
{
  "users": [
    {
      "id": "usr_abc123",
      "tenant_id": "ten_xyz",
      "email": "alice@example.com",
      "name": "Alice",
      "role": "member",
      "created_at": "2025-03-21T10:00:00Z"
    }
  ]
}
```

### Create a user

```bash
curl -X POST https://<your-gateway-host>/admin/v1/tenants/{tenant_id}/users \
  -H "Content-Type: application/json" \
  -d '{
    "email": "alice@example.com",
    "name": "Alice",
    "role": "member"
  }'
```

| Field | Type | Required | Description |
|---|---|---|---|
| `email` | string | Yes | User's email address. Must be unique within the tenant. |
| `name` | string | No | Display name. |
| `role` | string | Yes | One of `admin`, `member`, or `viewer`. |

**Response:** `{ "id": "usr_abc123", "email": "alice@example.com" }`

### Update a user

```bash
curl -X PATCH https://<your-gateway-host>/admin/v1/users/{id} \
  -H "Content-Type: application/json" \
  -d '{"role": "admin"}'
```

### Delete a user

Deletes the user record and immediately disables all tokens associated with that user. In-flight requests that have already passed the auth phase complete normally.

```bash
curl -X DELETE https://<your-gateway-host>/admin/v1/users/{id}
```

### Reset user token budgets

Clears the accumulated spend for every token belonging to the user.

```bash
curl -X DELETE https://<your-gateway-host>/admin/v1/users/{id}/budget
```

---

## Tokens

### Token fields

| Field | Type | Default | Description |
|---|---|---|---|
| `label` | string | — | Human-readable name shown in the admin UI and logs. |
| `user_id` | string \| null | `null` | Associates the token with a user for audit trail and per-user budget tracking. |
| `scopes` | array | `[]` | Permission scopes. `["inference"]` grants inference access. Reserved for future use. |
| `expires_at` | string \| null | `null` | ISO-8601 expiry timestamp. `null` means the token never expires. |
| `rate_limit` | object \| null | `null` | Per-token sliding-window limit: `{"requests": N, "window_sec": S}`. Applied independently of the gateway-level rate limit — a request can be blocked by either. |
| `budget_usd` | number \| null | `null` | Per-token spend cap in USD. `null` means no cap. |

!!! note
    Tokens are hashed with SHA-256 before storage. The plaintext `token` value is returned once in the creation response and cannot be retrieved later. If a token is lost, revoke it and create a new one. The list endpoint returns `token_hash`, not the plaintext value.

### List gateway tokens

```bash
curl https://<your-gateway-host>/admin/v1/gateways/{gateway_id}/tokens
```

### Create a gateway token

```bash
curl -X POST https://<your-gateway-host>/admin/v1/gateways/{gateway_id}/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "label": "CI bot",
    "scopes": ["inference"],
    "expires_at": null,
    "rate_limit": null,
    "budget_usd": null
  }'
```

**Response:**

```json
{
  "id": "tok_def456",
  "token": "aig_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "gateway_id": "gw_xyz789"
}
```

### Create a gateway token with rate limit and budget

```bash
curl -X POST https://<your-gateway-host>/admin/v1/gateways/{gateway_id}/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "label": "production-client",
    "user_id": "usr_abc123",
    "scopes": ["inference"],
    "expires_at": "2027-01-01T00:00:00Z",
    "rate_limit": {"requests": 60, "window_sec": 60},
    "budget_usd": 100.00
  }'
```

### Create a user token

User tokens work identically to gateway tokens but are listed under the user and can be managed via the user endpoint. `gateway_id` is required — it specifies which gateway the token grants access to.

```bash
curl -X POST https://<your-gateway-host>/admin/v1/users/{user_id}/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "gateway_id": "gw_xyz789",
    "label": "personal dev token",
    "scopes": ["inference"],
    "budget_usd": 10.00
  }'
```

### Revoke a token

Revocation is immediate. Any subsequent inference request using the revoked token returns `401 UNAUTHORIZED`.

```bash
curl -X DELETE https://<your-gateway-host>/admin/v1/gateways/{gateway_id}/tokens/{token_id}
```

---

## Access control

Gateway access grants control which gateways a `member`-role user's tokens are valid on. Tokens belonging to `admin`-role users are valid on all gateways.

### List gateway access for a user

```bash
curl https://<your-gateway-host>/admin/v1/users/{user_id}/gateways
```

**Response:**

```json
{
  "gateways": [
    {"id": "gw_xyz789", "slug": "production", "tenant_id": "ten_abc123"}
  ]
}
```

### Grant gateway access

```bash
curl -X POST https://<your-gateway-host>/admin/v1/users/{user_id}/gateways/{gateway_id}
```

### Revoke gateway access

```bash
curl -X DELETE https://<your-gateway-host>/admin/v1/users/{user_id}/gateways/{gateway_id}
```

!!! note
    Revoking gateway access does not automatically revoke the user's tokens. Existing tokens become unusable on that gateway but are not deleted. Re-granting access restores their validity.

---

## See also

- [Authentication](authentication.md)
- [Tenants & Gateways API](tenants-gateways.md)
- [Rate Limiting](../configuration/rate-limiting.md)
- [Budget & Quota Enforcement](../configuration/budgets.md)
- [Error Codes](error-codes.md)
