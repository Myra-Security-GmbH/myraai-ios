# Circuit Breaker

The circuit breaker automatically stops routing traffic to a provider that is consistently failing, then probes it after a cooldown period to detect recovery. This prevents cascading failures where a broken provider repeatedly burns retries on every request.

---

## State Machine

```
            failures >= threshold
CLOSED ──────────────────────────────────▶ OPEN
  ▲                                           │
  │                                    cooldown elapsed
  │                                           │
  │   probe succeeds                          ▼
  └────────────────────────────────── HALF_OPEN
                                             │
                               probe fails   │
                           ─────────────────▶ OPEN (restart cooldown)
```

| State | Behaviour |
|---|---|
| **Closed** (healthy) | All requests route normally |
| **Open** | Requests skip this provider entirely; next target in fallback chain is tried |
| **Half-open** | One probe request is allowed through to test recovery |

The default state is **closed**. No state is stored until the first failure is recorded.

---

## Configuration

Add `circuit_breaker` to the gateway config:

```json
{
  "circuit_breaker": {
    "enabled": true,
    "failure_threshold": 5,
    "window_sec": 60,
    "cooldown_ms": 30000,
    "failure_status_codes": [500, 502, 503, 504]
  }
}
```

### Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `enabled` | boolean | `false` | Must be `true` to activate the breaker |
| `failure_threshold` | integer | `5` | Number of failures within `window_sec` before the breaker opens |
| `window_sec` | integer | `60` | Sliding window in seconds over which failures are counted |
| `cooldown_ms` | integer | `30000` | Milliseconds to wait in the Open state before allowing a probe |
| `failure_status_codes` | array | `[500,502,503,504]` | HTTP status codes that count as failures. Connection/timeout errors always count regardless of this list. |

---

## What Counts as a Failure

- **HTTP 5xx from the provider** — only codes listed in `failure_status_codes` count (default: 500, 502, 503, 504)
- **Connection errors** — DNS failure, connection refused, TLS error — always counted regardless of `failure_status_codes`
- **Timeouts** — treated as connection errors

**Not counted:** 4xx responses from the provider (bad request, auth failure, etc.) — these are treated as client errors, not provider failures.

---

## Interaction with Retries and Fallbacks

The circuit breaker check runs **before** each upstream attempt in `upstream.lua`. The sequence for a request with `retry_count: 2` and one fallback, with OpenAI's breaker open:

1. Check OpenAI breaker → **OPEN** → skip OpenAI entirely
2. Check Anthropic breaker → closed → attempt Anthropic
3. Anthropic succeeds → record success → return response

Without a circuit breaker, the gateway would waste two retry attempts on a failing OpenAI before trying Anthropic.

---

## State Storage

State is stored in `ngx.shared` dicts — no database writes:

| Key | Dict | Content |
|---|---|---|
| `cb:state:{gw_id}:{provider}` | `aig_config` | `"open"` or `"half_open"` (absent = closed) |
| `cb:opened:{gw_id}:{provider}` | `aig_config` | Unix timestamp when breaker opened (string) |
| `cb:fail:{gw_id}:{provider}` | `aig_ratelimit` | Failure counter (auto-expires after `window_sec * 2`) |

State is per worker in single-node `shared_dict` mode. In Redis mode, the same keys live in Redis and are consistent across workers and instances.

---

## Status API

Check the current breaker state for all providers on a gateway:

```
GET /admin/v1/gateways/{id}/circuit-breaker
```

Response:

```json
{
  "openai": {
    "state": "open",
    "failures": 7,
    "opened_at": 1748123456
  },
  "anthropic": {
    "state": "closed",
    "failures": 0
  }
}
```

Only providers that have recorded at least one failure appear in the response. A missing provider entry means the breaker is closed with zero recorded failures.

The Dashboard UI shows this status in a live table on the gateway detail page when the circuit breaker is enabled.

---

## Example Config

### Conservative — trip only on sustained outage

```json
{
  "circuit_breaker": {
    "enabled": true,
    "failure_threshold": 10,
    "window_sec": 120,
    "cooldown_ms": 60000
  }
}
```

Opens after 10 failures in 2 minutes. Probes after 1 minute. Appropriate when providers have occasional transient errors.

### Aggressive — trip fast, recover fast

```json
{
  "circuit_breaker": {
    "enabled": true,
    "failure_threshold": 3,
    "window_sec": 30,
    "cooldown_ms": 10000
  }
}
```

Opens after 3 failures in 30 seconds. Probes after 10 seconds. Appropriate when you have multiple healthy fallbacks and want to shed load immediately.

---

## See Also

- [Dynamic Routing & Fallback](fallback.md)
- [Load Balancing](load-balancing.md)
- [Gateway Configuration Reference](../reference/gateway-config.md)
