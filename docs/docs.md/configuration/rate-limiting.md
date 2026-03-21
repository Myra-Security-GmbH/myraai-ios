# Rate Limiting

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

**In the admin UI:**

1. Open **Gateways** and click the gateway.
2. Open the **Config** tab.
3. Set the **Rate Limit** fields: requests per window and window duration in seconds.
4. Click **Save**.

To remove the gateway-level limit, clear the Rate Limit field and save.

| Field | Type | Description |
|---|---|---|
| `requests` | integer | Maximum number of requests allowed in the window. |
| `window_sec` | integer | Length of the sliding window in seconds. |

### Per-token rate limit

A rate limit can be attached to an individual auth token. This limit applies only to requests authenticated with that specific token.

**In the admin UI:**

1. Open **Users** and select the user.
2. Click **New Token** (or edit an existing token if your UI supports it).
3. Fill in the **Rate Limit** fields for that token.

!!! note
    Per-token limits are evaluated independently from the gateway-level limit. A request can be blocked by the gateway-level limit even if the token's own limit has not been reached, and vice versa.

## Response headers

When a request is rate limited, the gateway returns `HTTP 429` with the following headers:

| Header | Description |
|---|---|
| `X-RateLimit-Limit` | The configured request limit for the window. |
| `X-RateLimit-Remaining` | Estimated requests remaining in the current window. |
| `X-RateLimit-Reset` | Unix timestamp (seconds) at which the window resets. |

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
    Clients must implement backoff and retry logic. The `X-RateLimit-Reset` header gives the earliest time at which retrying will succeed.

## API

Rate limits are part of the gateway config object and the token creation request. See [Tenants & Gateways API](../api-reference/tenants-gateways.md) and [Users & Tokens API](../api-reference/users-tokens.md) for examples.

## See also

- [Gateway Configuration](gateway-config.md)
- [Budget & Quota Enforcement](budgets.md)
- [Authentication & Tokens](../security/authentication.md)
