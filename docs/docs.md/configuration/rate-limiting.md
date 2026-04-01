---
title: Rate limiting
description: Configure gateway-level and per-token rate limits in AI Gateway by Myra Security. Sliding-window algorithm, response headers, and 429 error handling.
---

# Rate limiting

Rate limiting controls how many requests a gateway or an individual auth token accepts within a time window. The gateway enforces rate limits before any upstream call is made, so blocked requests never reach the AI provider.

## How rate limiting works

The gateway uses a sliding-window dual-bucket algorithm. It maintains two time buckets: the current window and the previous window. On each request, the effective request count is calculated as:

```
effective_count = prev_bucket * (1 - elapsed / window_sec) + cur_bucket
```

Where `elapsed` is the number of seconds into the current window. This smooths out burst spikes at window boundaries without storing a full log of request timestamps.

Two independent limit levels exist:

- **Gateway-level rate limit** — applies to the aggregate of all requests through the gateway.
- **Per-token rate limit** — applies only to requests authenticated with a specific auth token.

Both levels are evaluated independently. A request can be blocked by the gateway-level limit even if the limit of the token has not been reached, and vice versa.

### Rate limit configuration fields

| **Field** | **Type** | **Description** |
|---|---|---|
| `requests` | integer | Maximum number of requests allowed in the window. |
| `window_sec` | integer | Length of the sliding window in seconds. |

### Response headers

When a request is rate limited, the gateway returns `HTTP 429` with the following headers:

| **Header** | **Description** |
|---|---|
| `X-RateLimit-Limit` | The configured request limit for the window. |
| `X-RateLimit-Remaining` | Estimated requests remaining in the current window (`0` when blocked). |
| `Retry-After` | The window duration in seconds — the minimum time before retrying. |

> ⭐ **Example:** `429` response body:

```json
{
  "error": {
    "code": "RATE_LIMITED",
    "message": "Rate limit exceeded"
  }
}
```

> ⚠️ **Caution:** Clients must implement backoff and retry logic. The `Retry-After` header gives the window duration in seconds — waiting at least this long before retrying is sufficient.

---

## Configuring a gateway-level rate limit

The gateway-level rate limit applies to the aggregate of all requests through the gateway.

Before you begin, ensure the following conditions are met:

- ☑ You are logged in as a user with the `admin` role.

![Screenshot: Gateway Config tab showing rate limit fields](../assets/screenshots/gateway-rate-limit.png)
*The rate limit fields in the gateway **Config** tab.*

► Proceed as follows to configure a gateway-level rate limit:

1. Click on **Gateways** in the left sidebar.
   ⇒ The **Gateways** list opens.
2. Click on the gateway.
   ⇒ The gateway detail view opens.
3. Click on the **Config** tab.
   ⇒ The configuration form opens.
4. Enter the maximum number of requests in the **Requests** text field.
5. Enter the window duration in seconds in the **Window** text field.
6. Click on the **Save** button.
   ⇒ The rate limit is applied to all requests through the gateway.

→ The gateway enforces the new rate limit for all subsequent requests.

> 💡 **Note:** To remove the gateway-level limit, clear the **Rate limit** fields and click on **Save**.

---

## Configuring a per-token rate limit

A per-token rate limit applies only to requests authenticated with a specific auth token. Attach it to a token at creation time.

Before you begin, ensure the following conditions are met:

- ☑ You are logged in as a user with the `admin` role.

![Screenshot: New Token dialog with rate limit fields](../assets/screenshots/token-rate-limit.png)
*The rate limit fields in the **New Token** dialog.*

► Proceed as follows to configure a per-token rate limit:

1. Click on **Users** in the left sidebar.
   ⇒ The **Users** list opens.
2. Click on the user.
   ⇒ The user detail view opens.
3. Click on the **New Token** button.
   ⇒ The **New Token** dialog opens.
4. Enter the maximum number of requests in the **Requests** text field.
5. Enter the window duration in seconds in the **Window** text field.
6. Click on the **Save** button.
   ⇒ The new token appears in the token list with the configured rate limit.

→ The token rate limit is active for all requests authenticated with that token.

---

## API

Rate limits are part of the gateway config object and the token creation request. See [Tenants & Gateways API](../api-reference/tenants-gateways.md) and [Users & Tokens API](../api-reference/users-tokens.md) for examples.

## See also

- [Gateway Configuration](gateway-config.md)
- [Budget & Quota Enforcement](budgets.md)
- [Authentication & Tokens](../security/authentication.md)
