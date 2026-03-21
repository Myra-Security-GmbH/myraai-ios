# Rate Limiting

The gateway enforces rate limits using a sliding-window dual-bucket algorithm. Limits can be set at the gateway level (applied to all traffic) and per token (applied to an individual caller).

## Algorithm

The gateway maintains two time buckets: the current window and the previous window. On each request, the effective request count is calculated as:

```
effective_count = prev_bucket * (1 - elapsed / window_sec) + cur_bucket
```

Where `elapsed` is the number of seconds that have passed since the current window started.

This approximation smooths out burst spikes at window boundaries without requiring a full sliding log of timestamps, keeping memory usage constant regardless of traffic volume.

Rate limiting is enforced at the **access phase**, before any upstream call is made.

## Configuration

### Gateway-level rate limit

Set in the gateway `config` object. Applies to the aggregate of all requests through this gateway.

```bash
curl -X PATCH https://your-gateway-host/admin/v1/gateways/{id} \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "rate_limit": {
        "requests": 200,
        "window_sec": 60
      }
    }
  }'
```

| Field | Type | Description |
|---|---|---|
| `requests` | integer | Maximum number of requests allowed in the window. |
| `window_sec` | integer | Length of the sliding window in seconds. |

Set `rate_limit` to `null` to remove the gateway-level limit entirely.

### Per-token rate limit

A rate limit can be attached to an individual auth token when it is created. This overrides the gateway-level limit for requests authenticated with that token.

```bash
curl -X POST https://your-gateway-host/admin/v1/gateways/{id}/tokens \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "label": "client-app",
    "user_id": "user_123",
    "scopes": ["inference"],
    "rate_limit": {
      "requests": 50,
      "window_sec": 60
    }
  }'
```

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

## See also

- [Gateway Configuration](gateway-config.md)
- [Budget & Quota Enforcement](budgets.md)
- [Authentication & Tokens](../security/authentication.md)
