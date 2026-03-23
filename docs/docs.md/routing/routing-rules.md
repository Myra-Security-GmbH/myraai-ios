# Routing Rules

Routing rules let you redirect requests to different providers and models based on attributes of the incoming request. Rules are evaluated in ascending priority order and the first matching rule wins.

## Rules engine overview

- Rules are evaluated in **ascending priority order** (lower number = higher priority)
- **First match wins** — evaluation stops at the first rule whose all conditions match
- All conditions within a rule must match (logical AND)
- If no rule matches, the gateway uses the provider and model from the original request

## Using the admin UI

1. Open **Gateways** in the left sidebar and click the gateway.
2. Open the **Routing** tab. The rule list shows all rules in priority order.
3. Click **Add Rule**.
4. Set the **Priority** (lower = higher priority; use increments of 10 to leave room for insertions).
5. Add one or more **Conditions** — each condition picks a field, an operator, and a value.
6. Set the **Actions**: choose a target provider, optionally rewrite the model name, and add fallback providers.
7. Toggle **Enabled** on and click **Save**.

![Routing rule editor](../assets/screenshots/routing-rule-editor.png)

To reorder rules, edit their priority values. To temporarily disable a rule without deleting it, toggle **Enabled** off.

## Condition fields and operators

### Fields

| Field | Matches against |
|---|---|
| `model` | The `model` field in the request body |
| `provider` | The provider name resolved for this gateway |
| `tenant_id` | The tenant identifier in the request URL |
| `header:{name}` | The value of HTTP header `{name}` (e.g. `header:x-customer-tier`) |
| `meta:{key}` | The value of `x-aig-meta-{key}` header (e.g. `meta:region`) |

### Operators

| Operator | Description |
|---|---|
| `eq` | Exact equality match |
| `neq` | Not equal |
| `prefix` | Value starts with the specified string |
| `contains` | Value contains the specified string |
| `regex` | Value matches the specified regular expression |

## Actions

| Field | Type | Description |
|---|---|---|
| `provider` | string | Route the request to this provider. |
| `model` | string | Replace the model name with this value when forwarding. |
| `fallbacks` | array | Ordered list of `{provider, model}` objects to try if the primary fails. |

## Common patterns

### Route by model prefix

Send all `gpt-*` requests to OpenAI and all `claude-*` requests to Anthropic:

```json
[
  {
    "priority": 10,
    "conditions": [{"field": "model", "op": "prefix", "value": "gpt-"}],
    "actions": {"provider": "openai", "model": "gpt-4o"},
    "enabled": true
  },
  {
    "priority": 20,
    "conditions": [{"field": "model", "op": "prefix", "value": "claude-"}],
    "actions": {"provider": "anthropic", "model": "claude-sonnet-4-6"},
    "enabled": true
  }
]
```

### Route by tenant

Send a specific tenant's traffic to a dedicated provider account:

```json
{
  "priority": 5,
  "conditions": [{"field": "tenant_id", "op": "eq", "value": "enterprise-corp"}],
  "actions": {
    "provider": "openai",
    "model": "gpt-4o"
  },
  "enabled": true
}
```

### Route by custom header

Use a customer tier header to select a model:

```json
{
  "priority": 15,
  "conditions": [
    {"field": "header:x-customer-tier", "op": "eq", "value": "premium"}
  ],
  "actions": {
    "provider": "openai",
    "model": "gpt-4o"
  },
  "enabled": true
}
```

### Route by metadata

Route requests tagged with a region metadata header:

```json
{
  "priority": 20,
  "conditions": [
    {"field": "meta:region", "op": "eq", "value": "eu"}
  ],
  "actions": {
    "provider": "azure",
    "model": "gpt-4o"
  },
  "enabled": true
}
```

Attach the metadata with `x-aig-meta-region: eu` on the inference request.

!!! note
    Priority values do not need to be contiguous. Using increments of 10 (10, 20, 30 ...) leaves room to insert rules between existing ones without renumbering.

## API

Routing rules are also fully manageable via the Admin API. See [Routing Rules API](../api-reference/routing-rules.md) for endpoint reference and request/response examples.

## See also

- [OpenAI-Compatible Endpoint](compat-endpoint.md)
- [Fallback & Retry](fallback.md)
- [Gateway Configuration](../configuration/gateway-config.md)
- [API Reference: Routing Rules](../api-reference/routing-rules.md)
