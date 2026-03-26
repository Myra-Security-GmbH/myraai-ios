# My Tokens

**My Tokens** is a self-service page in the admin panel that lets any user create and manage their own inference tokens without admin assistance.

Navigate to **My Tokens** in the sidebar (bottom of the navigation, under **Account**).

![My Tokens page](../assets/screenshots/my-tokens.png)

---

## Who can use this

| Role | Can create tokens | Can revoke own tokens |
|---|---|---|
| `admin` | Yes | Yes |
| `tenant_admin` | Yes | Yes |
| `member` | Yes | Yes |
| `viewer` | No | — |

`member` and `viewer` roles do not have access to the **Users** page, so **My Tokens** is the only way for a `member` to create their own inference credentials.

---

## Creating a token

1. Click **+ New Token**.
2. Select the **gateway** you want to access. Gateways are listed as `tenant/gateway-slug`.
3. Optionally set a **label**, **expiry date**, **spend budget** (USD), and **rate limit**.
4. Click **Create Token**.
5. Copy the token immediately — it is shown once and cannot be retrieved later.

---

## Using a token

Tokens created here are standard inference tokens. Use them with the `Authorization: Bearer` header on any provider endpoint:

```bash
curl -X POST https://<gateway-host>/v1/<tenant>/<gateway>/compat/chat/completions \
  -H "Authorization: Bearer myra_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gpt-4o-mini",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

See [Endpoint URL formats](../routing/compat-endpoint.md) for provider-specific paths.

---

## Revoking a token

Click **Revoke** next to any token in the table. Revocation is immediate — the token is rejected on the next request. You can only revoke tokens that belong to your own account.

---

## API

The underlying endpoints are available for programmatic use:

| Method | Path | Description |
|---|---|---|
| `GET` | `/admin/v1/me/tokens` | List own tokens |
| `POST` | `/admin/v1/me/tokens` | Create a token |
| `DELETE` | `/admin/v1/me/tokens/{id}` | Revoke a token |

See [Users & Tokens API](../api-reference/users-tokens.md#self-service-tokens-metokens) for full request/response details.
