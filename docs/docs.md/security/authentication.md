# Authentication & Tokens

The gateway uses access tokens for inference authentication. Tokens are issued via the admin UI or API and can be configured with expiry dates, rate limits, and spend caps. The gateway stores only a one-way hash of each token — the plaintext is returned once at creation time and cannot be recovered afterwards.

## Token acceptance order

The gateway looks for an auth token in the following header order. The first matching header is used:

1. `x-aig-token: <token>`
2. `Authorization: Bearer <token>`
3. `x-api-key: <token>`

This order lets you use the gateway as a drop-in replacement for OpenAI-compatible clients that send `Authorization: Bearer` or `x-api-key` without reconfiguration.

## Token security model

- Tokens are stored as a one-way hash — the original value cannot be recovered from the database
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

| Role | Inference access | Admin panel access |
|---|---|---|
| `admin` | All gateways (platform-wide) | Full access, all organizations |
| `member` | All gateways in their organization | Own organization |
| `viewer` | 403 on all inference requests | Own organization (read-only) |

!!! warning
    The `viewer` role is intended for users who need read access to the admin UI only. Sending an inference request with a viewer-role token always returns `403 Forbidden`.

## Two token flows

There are two places in the admin UI where tokens can be created, and they serve different purposes:

| | Gateway token | User token |
|---|---|---|
| **Where** | Gateways → [gateway] → Tokens tab | Users → [user] → New Token |
| **Fields** | Expiration only | Label, gateway, expiry, budget, rate limit, scopes |
| **Associated with** | No user identity | A specific user record |
| **Budget tracking** | None | Per-user spend tracked |
| **Use case** | Quick service-to-service token | Named credential tied to an identity |

Use **gateway tokens** when you need a simple credential for a service or integration and don't need spend tracking per caller.

Use **user tokens** when you need to attribute usage, enforce per-user budgets, or manage access for individual people or teams.

## Token scopes

When creating a user token, you select one or more scopes:

| Scope | Description |
|---|---|
| `inference` | Grants access to inference endpoints. Select this for any token that will make model requests. |
| `read` | Reserved for future use. |
| `admin` | Reserved for future use. |

Select `inference` for standard API access.

## Using the admin UI

### Create a user

1. Open **Users** in the left sidebar.
2. Click **New User**.
3. Select the organization, enter an email and optional name, and choose a role:
   - **member** — full access to all gateways in the organization
   - **viewer** — read-only admin UI access; cannot make inference requests
4. Click **Save**.

Platform `admin` users can also create other `admin` accounts.

### Create a token

1. Open **Users** and select the user.
2. Click **New Token**.
3. Select the gateway, set a label, configure optional expiry, budget, rate limit, and scopes.
4. Click **Create**. The plaintext token is shown once — copy it now.

### Revoke a token

1. Open **Users** and select the user.
2. Find the token in the token list and click the delete icon.

Revocation is immediate. In-flight requests that have already passed the auth phase complete normally.

## Disabling authentication

For development or internal networks, authentication can be disabled per gateway via the **Config** tab:

1. Open **Gateways** and click the gateway.
2. Open the **Config** tab.
3. Set **Auth Required** to off and save.

!!! warning
    Never disable authentication in production. Any caller with network access to the gateway endpoint can make inference requests and incur costs.

## API

Token and user management is also available via the Admin API. See [Users & Tokens API](../api-reference/users-tokens.md) for endpoint reference and request/response examples.

## See also

- [Rate Limiting](../configuration/rate-limiting.md)
- [Budget & Quota Enforcement](../configuration/budgets.md)
- [Gateway Configuration](../configuration/gateway-config.md)
- [API Reference: Users & Tokens](../api-reference/users-tokens.md)
