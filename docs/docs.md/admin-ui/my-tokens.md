---
title: My tokens
description: How to create and revoke personal inference tokens in the AI Gateway admin panel.
---

# My tokens

## View: My tokens

![View: My tokens](../assets/screenshots/my-tokens.png)
*View: My tokens*

The **My tokens** view lets any eligible user create and manage their own inference tokens without administrator assistance. It is accessible from the **My tokens** entry at the bottom of the sidebar, under **Account**.

The view lists all tokens belonging to the currently logged-in user. Each row shows the label of the token, the gateway it is scoped to, the expiry date, the spend budget, the rate limit, and a **Revoke** button.

| Role | Can create tokens | Can revoke own tokens |
|---|---|---|
| `admin` | Yes | Yes |
| `tenant_admin` | Yes | Yes |
| `member` | Yes | Yes |
| `viewer` | No | — |

`member` users do not have access to the **Users** view. The **My tokens** view is therefore the only way for a `member` to create their own inference credentials.

---

## Creating a token

► Proceed as follows to create an inference token:

1. Click the **+ New Token** button.
   - A creation form appears.
2. Select the gateway you want the token to access from the **Gateway** drop-down list. Gateways are listed as `tenant/gateway-slug`.
3. If required, enter a descriptive name in the **Label** text field.
4. If required, set an expiry date in the **Expiry date** field.
5. If required, enter a maximum spend in USD in the **Spend budget** text field.
6. If required, set a request rate limit in the **Rate limit** field.
7. Click the **Create Token** button.
   - The token value appears on screen.
8. Copy the token value immediately.

> ⚠️ **Caution:** The token is shown once only and cannot be retrieved again. Store it securely before closing the dialog.

→ The new token appears in the list of tokens.

---

## Using a token

Tokens created in the **My tokens** view are standard inference tokens. Use them with the `Authorization: Bearer` header on any provider endpoint:

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

► Proceed as follows to revoke a token:

1. Locate the token you want to revoke in the token table.
2. Click the **Revoke** button on that row.

→ The token is invalidated immediately. Any request that uses the revoked token is rejected. You can only revoke tokens that belong to your own account.
