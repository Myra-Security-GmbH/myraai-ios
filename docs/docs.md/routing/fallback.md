# Fallback & Retry

## Why use fallbacks?

AI providers occasionally go down, rate-limit your account, or return errors during high-traffic periods. Without a fallback, your application returns an error to the user. With a fallback chain, the gateway silently retries against another provider (e.g. fall back from OpenAI to Anthropic) and the user gets a response.

Fallbacks are defined per routing rule and are transparent to the caller — the response format is the same regardless of which provider in the chain ultimately handled the request.

---

The gateway automatically retries failed requests against the primary provider and can fall over to alternative providers if the primary is unavailable or exhausted.

## How the fallback chain works

A request follows this sequence:

1. **Primary provider** — attempted up to `retry_count` times on server errors (HTTP 5xx). Default: 2 attempts total (1 retry).
2. **Fallback providers** — each fallback is attempted **once** in order. Fallbacks are defined in the routing rule that matched the request.
3. If all providers are exhausted, the gateway returns `502 ALL_PROVIDERS_FAILED`.

```mermaid
flowchart LR
    Start([Request]) --> P1

    subgraph Primary ["Primary provider"]
        P1[Attempt 1] -- 5xx --> P2[Attempt 2]
    end

    P1 -- 4xx --> Bail(["Return 4xx immediately<br/>no retry or fallback"])
    P2 -- 5xx --> F1[Fallback 1]
    F1 -- 5xx --> F2[Fallback 2]
    F2 -- 5xx --> E([502 ALL_PROVIDERS_FAILED])
```

## Client errors are not retried

A client error response from a provider (HTTP 4xx — e.g. bad request, unauthorized, not found) is treated as a definitive failure — the request is **not retried** and fallbacks are **not attempted**. The error is returned to the caller immediately.

!!! note
    This prevents pointless retries: if your request is malformed or your API key is invalid, retrying against another provider won't help.

## retry_count

Controls the total number of attempts against the primary provider (not the number of retries). Set in gateway config:

```bash
curl -X PATCH https://your-gateway-host/admin/v1/gateways/{id} \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"config": {"retry_count": 3}}'
```

| `retry_count` | Primary attempts | Retries |
|---|---|---|
| `1` | 1 | 0 |
| `2` | 2 | 1 |
| `3` | 3 | 2 |

## Fallback config in routing rules

Fallbacks are defined in the `actions` object of a routing rule:

```json
{
  "priority": 10,
  "conditions": [
    {"field": "model", "op": "prefix", "value": "gpt-"}
  ],
  "actions": {
    "provider": "openai",
    "model": "gpt-4o",
    "fallbacks": [
      {"provider": "anthropic", "model": "claude-sonnet-4-6"},
      {"provider": "gemini", "model": "gemini-2.0-flash"}
    ]
  },
  "enabled": true
}
```

Each entry in `fallbacks` is attempted once, in array order.

```bash
curl -X POST https://your-gateway-host/admin/v1/gateways/{id}/rules \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "priority": 10,
    "conditions": [{"field": "model", "op": "prefix", "value": "gpt-"}],
    "actions": {
      "provider": "openai",
      "model": "gpt-4o",
      "fallbacks": [
        {"provider": "anthropic", "model": "claude-sonnet-4-6"},
        {"provider": "gemini", "model": "gemini-2.0-flash"}
      ]
    },
    "enabled": true
  }'
```

## BYOK key swap on provider change

When a fallback triggers a provider change, the gateway automatically selects the BYOK key for the new provider. The `x-aig-byok-alias` header is honored for the fallback provider if a key with that alias exists; otherwise the `"default"` alias is used.

This means you must have a BYOK key stored for each provider in the fallback chain. If no key is found for a fallback provider, that fallback attempt will fail with an authentication error.

!!! warning
    Ensure BYOK keys are stored for every provider in your fallback chains. A missing key for a fallback provider causes that fallback to fail with a `4xx`, which halts the chain immediately.

## 502 ALL_PROVIDERS_FAILED

When every provider in the chain (primary + all fallbacks) has been tried and none succeeded:

```json
{
  "error": {
    "code": "ALL_PROVIDERS_FAILED",
    "message": "All providers failed to process the request"
  }
}
```

HTTP status code is `502`.

## Logged fields

For every request that uses a fallback, the gateway logs the final provider used:

| Log field | Description |
|---|---|
| `fallback_provider` | Name of the provider that ultimately served the request, if different from the primary. |
| `fallback_model` | Model name used by the fallback provider. |

These fields are visible in the request log table and in the admin UI log viewer.

## See also

- [Routing Rules](routing-rules.md)
- [OpenAI-Compatible Endpoint](compat-endpoint.md)
- [Provider Key Management (BYOK)](../security/byok.md)
- [Gateway Configuration](../configuration/gateway-config.md)
