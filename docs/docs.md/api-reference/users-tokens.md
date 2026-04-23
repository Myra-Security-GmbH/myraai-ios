# Users & tokens API

Users are identity records within a tenant. Each user has a role and can hold multiple auth tokens. Tokens are the credentials used to authenticate inference requests.

**Base URL:** `https://<your-gateway-host>/admin/v1`

---

## Endpoints

### Users

| **Method** | **Path** | **Description** |
|---|---|---|
| `GET` | `/tenants/{id}/users` | List users for a tenant |
| `POST` | `/tenants/{id}/users` | Create a user |
| `PATCH` | `/users/{id}` | Update a user |
| `DELETE` | `/users/{id}` | Delete a user (disables all their tokens) |
| `DELETE` | `/users/{id}/budget` | Reset all token spend counters for a user |

### Tokens

| **Method** | **Path** | **Description** |
|---|---|---|
| `GET` | `/gateways/{id}/tokens` | List all tokens for a gateway |
| `POST` | `/gateways/{id}/tokens` | Create a gateway-scoped token |
| `DELETE` | `/gateways/{id}/tokens/{tid}` | Revoke a token |
| `GET` | `/users/{id}/tokens` | List tokens belonging to a user |
| `POST` | `/users/{id}/tokens` | Create a user-scoped token |

### Self-service (my tokens)

| **Method** | **Path** | **Description** |
|---|---|---|
| `GET` | `/me/tokens` | List the caller's own tokens |
| `POST` | `/me/tokens` | Create a token for the caller |
| `DELETE` | `/me/tokens/{tid}` | Revoke one of the caller's own tokens |

---

## Users

### Listing users

```bash
curl https://<your-gateway-host>/admin/v1/tenants/{tenant_id}/users
```

**Response:**

```json
[
  {
    "id": "usr_abc123",
    "tenant_id": "ten_xyz",
    "email": "alice@example.com",
    "name": "Alice",
    "role": "member",
    "created_at": 1742551200
  }
]
```

### Creating a user

```bash
curl -X POST https://<your-gateway-host>/admin/v1/tenants/{tenant_id}/users \
  -H "Content-Type: application/json" \
  -d '{
    "email": "alice@example.com",
    "name": "Alice",
    "role": "member"
  }'
```

| **Field** | **Type** | **Required** | **Description** |
|---|---|---|---|
| `email` | string | Yes | Email address of the user. Must be globally unique. |
| `name` | string | No | Display name. |
| `role` | string | No | One of `tenant_admin`, `member`, or `viewer`. Defaults to `member`. Only platform `admin` users can create other `admin` accounts. |

**Response:** `{ "id": "usr_abc123", "email": "alice@example.com" }`

### Updating a user

```bash
curl -X PATCH https://<your-gateway-host>/admin/v1/users/{id} \
  -H "Content-Type: application/json" \
  -d '{"role": "viewer"}'
```

### Deleting a user

Deletes the user record and immediately disables all tokens associated with that user. In-flight requests that have already passed the auth phase complete normally.

```bash
curl -X DELETE https://<your-gateway-host>/admin/v1/users/{id}
```

### Resetting user token budgets

Clears the accumulated spend for every token belonging to the user.

```bash
curl -X DELETE https://<your-gateway-host>/admin/v1/users/{id}/budget
```

---

## Tokens

### Token fields

| **Field** | **Type** | **Default** | **Description** |
|---|---|---|---|
| `label` | string | — | Human-readable name shown in the admin UI and logs. |
| `user_id` | string \| null | `null` | Associates the token with a user for audit trail and per-user budget tracking. |
| `scopes` | array | `[]` | Permission scopes. `["inference"]` grants inference access. Reserved for future use. |
| `expires_at` | integer \| null | `null` | Unix expiry timestamp (seconds since epoch). `null` means the token never expires. |
| `rate_limit` | object \| null | `null` | Per-token sliding-window limit: `{"requests": N, "window_sec": S}`. Applied independently of the gateway-level rate limit — a request can be blocked by either. |
| `budget_usd` | number \| null | `null` | Per-token spend cap in USD. `null` means no cap. |

> 💡 **Note:** Tokens are hashed with SHA-256 before storage. The plaintext `token` value is returned once in the creation response and cannot be retrieved later. If a token is lost, revoke it and create a new one. The list endpoint returns `token_hash`, not the plaintext value.

### Listing gateway tokens

```bash
curl https://<your-gateway-host>/admin/v1/gateways/{gateway_id}/tokens
```

### Creating a gateway token

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
  "token": "myra_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "gateway_id": "gw_xyz789"
}
```

### Creating a gateway token with rate limit and budget

```bash
curl -X POST https://<your-gateway-host>/admin/v1/gateways/{gateway_id}/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "label": "production-client",
    "user_id": "usr_abc123",
    "scopes": ["inference"],
    "expires_at": 1798761600,
    "rate_limit": {"requests": 60, "window_sec": 60},
    "budget_usd": 100.00
  }'
```

### Creating a user token

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

### Revoking a token

Revocation is immediate. Any subsequent inference request using the revoked token returns `401 UNAUTHORIZED`.

```bash
curl -X DELETE https://<your-gateway-host>/admin/v1/gateways/{gateway_id}/tokens/{token_id}
```

---

## Self-service tokens (`/me/tokens`)

These endpoints are available to **any authenticated user** regardless of role (except `viewer`). They let `member` and `tenant_admin` users create and manage tokens for themselves without needing an admin to act on their behalf.

> 💡 **Note:** `viewer` users can call these endpoints but cannot create tokens with the `inference` scope because they have no inference access. Creating a token via `/me/tokens` automatically sets `scopes: ["inference"]`.

### Listing own tokens

```bash
curl https://<your-gateway-host>/admin/v1/me/tokens \
  -H "Cookie: aig_admin=<session>"
```

**Response:** array of [token objects](#token-fields).

### Creating own token

```bash
curl -X POST https://<your-gateway-host>/admin/v1/me/tokens \
  -H "Cookie: aig_admin=<session>" \
  -H "Content-Type: application/json" \
  -d '{
    "gateway_id": "gw_xyz789",
    "label": "my laptop",
    "expires_at": null,
    "budget_usd": null,
    "rate_limit": null
  }'
```

| **Field** | **Type** | **Required** | **Description** |
|---|---|---|---|
| `gateway_id` | string | Yes | Gateway the token grants access to. Must be accessible to the tenant of the caller. |
| `label` | string | No | Human-readable name. |
| `expires_at` | integer \| null | No | Unix expiry timestamp (seconds since epoch). `null` = never. |
| `budget_usd` | number \| null | No | Per-token spend cap in USD. |
| `rate_limit` | object \| null | No | `{"requests": N, "window_sec": S}` |

**Response:**

```json
{
  "id": "tok_abc123",
  "token": "myra_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "gateway_id": "gw_xyz789"
}
```

### Revoking own token

```bash
curl -X DELETE https://<your-gateway-host>/admin/v1/me/tokens/{token_id} \
  -H "Cookie: aig_admin=<session>"
```

Returns `403` if the token does not belong to the caller. Revocation is immediate.

---

## See also

- [Authentication](authentication.md)
- [Tenants & Gateways API](tenants-gateways.md)
- [Rate Limiting](../configuration/rate-limiting.md)
- [Budget & Quota Enforcement](../configuration/budgets.md)
- [Error Codes](error-codes.md)
