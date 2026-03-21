# Routing Rules API

Routing rules let you rewrite the provider and model for any request without changing the caller. Rules are evaluated in priority order — the first matching rule wins. Each rule can override the provider, rewrite the model name, and attach a fallback chain that is walked when the primary fails.

**Base URL:** `https://<your-gateway-host>/admin/v1`

---

## Endpoints

| Method | Path | Description |
|---|---|---|
| `GET` | `/gateways/{id}/rules` | List rules for a gateway |
| `POST` | `/gateways/{id}/rules` | Create a rule |
| `PATCH` | `/gateways/{id}/rules/{rule_id}` | Update a rule |
| `DELETE` | `/gateways/{id}/rules/{rule_id}` | Delete a rule |

---

## Rule structure

```json
{
  "id": "rule_abc123",
  "priority": 10,
  "conditions": [
    {"field": "model", "op": "prefix", "value": "gpt-"}
  ],
  "actions": {
    "provider": "openai",
    "model": "gpt-4o",
    "fallbacks": [
      {"provider": "anthropic", "model": "claude-sonnet-4-6"}
    ]
  },
  "enabled": true
}
```

### Rule fields

| Field | Type | Description |
|---|---|---|
| `priority` | integer | Evaluation order. Lower numbers run first. Rules with equal priority are evaluated in creation order. |
| `conditions` | array | List of condition objects. All conditions must match (logical AND). An empty array matches every request. |
| `actions` | object | What to do when the rule matches. At minimum, specify `provider`. |
| `enabled` | boolean | `false` disables the rule without deleting it. Default: `true`. |

---

## Conditions

Each condition object specifies a `field`, an `op` (operator), and a `value` to compare against.

### Condition fields

| Field | Description |
|---|---|
| `model` | The model name from the request body. |
| `provider` | The provider from the request URL path (e.g. `openai`, `compat`). |
| `tenant` | The tenant slug from the URL. |
| `gateway` | The gateway slug from the URL. |
| `meta.*` | Any custom metadata field attached via `x-aig-meta-{key}` request header. For example, `meta.env` matches the value of `x-aig-meta-env`. |

### Condition operators

| Operator | Behavior |
|---|---|
| `eq` | Exact string match. Case-sensitive. |
| `prefix` | Value starts with the given string. |
| `suffix` | Value ends with the given string. |
| `contains` | Value contains the given substring. |
| `regex` | Value matches the given regular expression (POSIX ERE). |
| `exists` | Field is present and non-empty (no `value` needed). |
| `neq` | Exact string non-match. |

### Examples

Match all requests for models starting with `gpt-`:

```json
{"field": "model", "op": "prefix", "value": "gpt-"}
```

Match a specific model:

```json
{"field": "model", "op": "eq", "value": "claude-opus-4-6"}
```

Match requests tagged with a custom header (`x-aig-meta-env: production`):

```json
{"field": "meta.env", "op": "eq", "value": "production"}
```

Match all requests (catch-all rule, empty conditions):

```json
[]
```

---

## Actions

| Field | Type | Description |
|---|---|---|
| `provider` | string | Override the inference provider (e.g. `openai`, `anthropic`, `gemini`). |
| `model` | string | Rewrite the model name sent to the provider. If omitted, the original model name is used. |
| `fallbacks` | array | Ordered fallback chain. Each entry is `{"provider": "...", "model": "..."}`. Used when the primary fails after all retries. |

!!! note
    Fallbacks are walked in order. Each fallback in the chain is attempted once. Only the primary provider uses `retry_count`. If all fallbacks fail, the gateway returns `502 ALL_PROVIDERS_FAILED`.

---

## Examples

### List rules

```bash
curl https://<your-gateway-host>/admin/v1/gateways/{gateway_id}/rules
```

**Response:**

```json
{
  "rules": [
    {
      "id": "rule_abc123",
      "priority": 10,
      "conditions": [{"field": "model", "op": "prefix", "value": "gpt-"}],
      "actions": {
        "provider": "openai",
        "model": "gpt-4o",
        "fallbacks": [{"provider": "anthropic", "model": "claude-sonnet-4-6"}]
      },
      "enabled": true
    }
  ]
}
```

### Create a rule — redirect GPT requests to OpenAI with Anthropic fallback

```bash
curl -X POST https://<your-gateway-host>/admin/v1/gateways/{gateway_id}/rules \
  -H "Content-Type: application/json" \
  -d '{
    "priority": 10,
    "conditions": [
      {"field": "model", "op": "prefix", "value": "gpt-"}
    ],
    "actions": {
      "provider": "openai",
      "model": "gpt-4o",
      "fallbacks": [
        {"provider": "anthropic", "model": "claude-sonnet-4-6"}
      ]
    },
    "enabled": true
  }'
```

### Create a rule — route production traffic to a specific model

```bash
curl -X POST https://<your-gateway-host>/admin/v1/gateways/{gateway_id}/rules \
  -H "Content-Type: application/json" \
  -d '{
    "priority": 5,
    "conditions": [
      {"field": "meta.env", "op": "eq", "value": "production"},
      {"field": "model", "op": "contains", "value": "claude"}
    ],
    "actions": {
      "provider": "anthropic",
      "model": "claude-opus-4-6"
    },
    "enabled": true
  }'
```

### Create a catch-all rule — default provider for all unmatched requests

```bash
curl -X POST https://<your-gateway-host>/admin/v1/gateways/{gateway_id}/rules \
  -H "Content-Type: application/json" \
  -d '{
    "priority": 999,
    "conditions": [],
    "actions": {
      "provider": "openrouter",
      "fallbacks": []
    },
    "enabled": true
  }'
```

### Update a rule — disable without deleting

```bash
curl -X PATCH https://<your-gateway-host>/admin/v1/gateways/{gateway_id}/rules/{rule_id} \
  -H "Content-Type: application/json" \
  -d '{"enabled": false}'
```

### Update a rule — change priority

```bash
curl -X PATCH https://<your-gateway-host>/admin/v1/gateways/{gateway_id}/rules/{rule_id} \
  -H "Content-Type: application/json" \
  -d '{"priority": 20}'
```

### Delete a rule

```bash
curl -X DELETE https://<your-gateway-host>/admin/v1/gateways/{gateway_id}/rules/{rule_id}
```

---

## Evaluation order

Rules are evaluated in ascending priority order. The **first matching rule wins** — subsequent rules are not evaluated.

If no rule matches the request, the provider and model from the original request URL or body are used as-is.

!!! note
    Rules are cached for 30 seconds in in-process shared memory. Changes take effect within one cache TTL cycle. In a multi-worker deployment, each worker refreshes independently.

---

## See also

- [Gateway Configuration Reference](../reference/config-reference.md)
- [Tenants & Gateways API](tenants-gateways.md)
- [Error Codes](error-codes.md)
- [Request Pipeline](../concepts/request-pipeline.md)
