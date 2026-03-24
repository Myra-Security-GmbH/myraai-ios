# Rate limiting

The gateway enforces rate limits using a sliding-window dual-bucket algorithm. Limits can be set at the gateway level (applied to all traffic) and per token (applied to an individual caller).

Rate limiting is enforced before any upstream call is made, so blocked requests never reach the AI provider.

??? info "How the algorithm works"
    The gateway uses a sliding-window dual-bucket algorithm. It maintains two time buckets: the current window and the previous window. On each request the effective request count is calculated as:

    ```
    effective_count = prev_bucket * (1 - elapsed / window_sec) + cur_bucket
    ```

    Where `elapsed` is the number of seconds into the current window. This smooths out burst spikes at window boundaries without storing a full log of request timestamps.

## Configuration

### Gateway-level rate limit

The gateway-level rate limit applies to the aggregate of all requests through the gateway.

1. Click on **Gateways** in the left sidebar.
   ↳ The **Gateways** view opens.
2. Click on the gateway.
   ↳ The gateway detail view opens.
3. Open the **Config** tab.
   ↳ The configuration form opens.
4. Enter the maximum number of requests in the **Requests** text field.
5. Enter the window duration in seconds in the **Window** text field.
6. To save the rate limit, click on the **Save** button.
   ↳ The rate limit is applied to all requests through the gateway.

To remove the gateway-level limit, clear the **Rate limit** fields and click on **Save**.

| Field | Type | Description |
|---|---|---|
| `requests` | integer | Maximum number of requests allowed in the window. |
| `window_sec` | integer | Length of the sliding window in seconds. |

### Per-token rate limit

A rate limit can be attached to an individual auth token. This limit applies only to requests authenticated with that specific token.

1. Click on **Users** in the left sidebar.
   ↳ The **Users** view opens.
2. Click on the user.
   ↳ The user detail view opens.
3. Click on the **New Token** button.
   ↳ The **New Token** dialog opens.
4. Enter the maximum number of requests in the **Requests** text field.
5. Enter the window duration in seconds in the **Window** text field.
6. To save the token, click on the **Save** button.
   ↳ The new token appears in the token list with the configured rate limit.

!!! note
    Per-token limits are evaluated independently from the gateway-level limit. A request can be blocked by the gateway-level limit even if the token's own limit has not been reached, and vice versa.

## Response headers

When a request is rate limited, the gateway returns `HTTP 429` with the following headers:

| Header | Description |
|---|---|
| `X-RateLimit-Limit` | The configured request limit for the window. |
| `X-RateLimit-Remaining` | Estimated requests remaining in the current window (0 when blocked). |
| `Retry-After` | The window duration in seconds — the minimum time before retrying. |

Example 429 response body:

```json
{
  "error": {
    "code": "RATE_LIMITED",
    "message": "Rate limit exceeded"
  }
}
```

!!! warning
    Clients must implement backoff and retry logic. The `Retry-After` header gives the window duration in seconds — waiting at least this long before retrying is sufficient.

## API

Rate limits are part of the gateway config object and the token creation request. See [Tenants & Gateways API](../api-reference/tenants-gateways.md) and [Users & Tokens API](../api-reference/users-tokens.md) for examples.

## See also

- [Gateway Configuration](gateway-config.md)
- [Budget & Quota Enforcement](budgets.md)
- [Authentication & Tokens](../security/authentication.md)
