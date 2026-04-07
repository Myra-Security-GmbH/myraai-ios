# Admin API authentication

Admin API access is controlled at the network level. The admin interface is bound to your provisioned endpoint and protected by your Myra Security account credentials. Inference endpoints use a bearer-token model described below.

---

## Admin API

### Security posture

All endpoints under `/admin/v1/` are accessible to authenticated operators via your Myra Security account. The admin API is intended to be called by the admin UI or from automation scripts on your management network.

> 💡 **Note:** For on-premise deployments, bind the admin listener to an internal network interface and restrict access to trusted hosts. Do not expose the admin API directly on a public interface without network-level controls in place.

---

## Inference API authentication

Inference endpoints (`/v1/{tenant}/{gateway}/{provider}/...`) use an opaque bearer token issued by the admin API.

### Token acceptance order

The gateway checks request headers in this order; the first matching header wins:

| **Priority** | **Header** | **Example** |
|---|---|---|
| 1 | `x-aig-token` | `x-aig-token: myra_xxxx` |
| 2 | `Authorization: Bearer` | `Authorization: Bearer myra_xxxx` |
| 3 | `x-api-key` | `x-api-key: myra_xxxx` |

This ordering lets you drop the gateway in as a replacement for the OpenAI API without modifying existing clients that send `Authorization: Bearer` or `x-api-key`.

### Token security model

- Tokens are hashed with **SHA-256** before storage. The plaintext is never persisted.
- The plaintext token is returned **once** in the creation response — copy it immediately.
- If a token is lost, delete it and create a new one; there is no recovery path.
- Tokens are scoped to a single gateway. Using a token on a different gateway returns `401 UNAUTHORIZED`.

### Disabling authentication

For development or fully-internal networks, authentication can be disabled per gateway:

```bash
curl -X PATCH https://<your-gateway-host>/admin/v1/gateways/{id} \
  -H "Content-Type: application/json" \
  -d '{"config": {"auth_required": false}}'
```

> ⚠️ **Caution:** Never set `auth_required: false` in production. Any caller with network access to the gateway endpoint can make inference requests and incur provider costs.

---

## Creating a token

Before you begin, ensure the following conditions are met:

- ☑ You have admin access to the gateway.
- ☑ You have the gateway ID available.

► Proceed as follows to create a token:

1. Send a `POST` request to `/admin/v1/gateways/{gateway_id}/tokens` with the token configuration in the request body.
   - The API creates the token and returns the plaintext value once.

```bash
curl -X POST https://<your-gateway-host>/admin/v1/gateways/{gateway_id}/tokens \
  -H "Content-Type: application/json" \
  -d '{
    "label": "my-service",
    "scopes": ["inference"],
    "expires_at": "2027-01-01T00:00:00Z",
    "rate_limit": {"requests": 100, "window_sec": 60},
    "budget_usd": 50.00
  }'
```

**Response:**

```json
{
  "id": "tok_abc123",
  "token": "myra_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "gateway_id": "gw_xyz789"
}
```

> ⚠️ **Caution:** The `token` field in this response is the only time the plaintext value is available. Store it in your secrets manager immediately.

→ The new token is ready for use in inference requests.

### Using the token

► Proceed as follows to authenticate an inference request:

1. Include one of the supported authentication headers in the request.
   - The gateway validates the token against the stored hash.

```bash
# x-aig-token header (preferred)
curl -X POST "https://<your-gateway-host>/v1/myapp/production/openai/chat/completions" \
  -H "x-aig-token: myra_xxxx" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Hello"}]}'

# Authorization: Bearer (OpenAI SDK compatible)
curl -X POST "https://<your-gateway-host>/v1/myapp/production/openai/chat/completions" \
  -H "Authorization: Bearer myra_xxxx" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Hello"}]}'

# x-api-key (Anthropic SDK compatible)
curl -X POST "https://<your-gateway-host>/v1/myapp/production/anthropic/chat/completions" \
  -H "x-api-key: myra_xxxx" \
  -H "Content-Type: application/json" \
  -d '{"model":"claude-opus-4-6","messages":[{"role":"user","content":"Hello"}]}'
```

→ The API returns the requested inference response.

---

## Role-based access control

Tokens are linked to a user record via `user_id`. The `role` of the user determines what the token can do:

| **Role** | **Inference** | **Admin API** |
|---|---|---|
| `admin` | All gateways | Full access |
| `member` | Assigned gateways only | No access |
| `viewer` | `403` on all requests | No access |

> 💡 **Note:** The `viewer` role is intended for operators who need read access to the admin UI dashboard only. Any inference request from a viewer-role token is rejected with `403 FORBIDDEN`.

---

## See also

- [Users & Tokens API](users-tokens.md)
- [Gateway Configuration Reference](../reference/config-reference.md)
- [Rate Limiting](../configuration/rate-limiting.md)
- [Budget & Quota Enforcement](../configuration/budgets.md)
- [Error Codes](error-codes.md)
