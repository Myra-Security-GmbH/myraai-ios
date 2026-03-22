# Load Balancing

Load balancing distributes traffic across multiple provider/model targets within a single routing rule. It is configured as the `load_balance` action type on a routing rule and supports weighted random selection, round-robin, and optional sticky sessions.

---

## Configuration

```json
{
  "priority": 10,
  "conditions": [],
  "enabled": true,
  "actions": {
    "load_balance": {
      "strategy": "weighted_random",
      "targets": [
        { "provider": "openai",    "model": "gpt-4o",              "weight": 7 },
        { "provider": "anthropic", "model": "claude-sonnet-4-6",   "weight": 3 }
      ]
    }
  }
}
```

### Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `strategy` | string | `"weighted_random"` | Target selection algorithm: `weighted_random` or `round_robin` |
| `targets` | array | — | List of provider/model targets with weights |
| `targets[].provider` | string | — | Provider name (e.g. `"openai"`) |
| `targets[].model` | string | — | Model name (e.g. `"gpt-4o"`) |
| `targets[].weight` | integer | `1` | Relative traffic weight. `0` disables the target without removing it from config. |
| `sticky` | object | `null` | Optional sticky session config |
| `sticky.field` | string | — | Request field to hash for stickiness. Supports `meta.<key>` notation (e.g. `"meta.user_id"`) |
| `sticky.ttl` | integer | `3600` | Seconds to cache the target assignment per sticky value |

---

## Strategies

### `weighted_random`

Selects a target with probability proportional to its weight. A target with `weight: 7` receives approximately 70% of traffic when the total is 10.

```json
"targets": [
  { "provider": "openai",    "model": "gpt-4o-mini",         "weight": 9 },
  { "provider": "anthropic", "model": "claude-haiku-4-5-20251001", "weight": 1 }
]
```

This routes 90% of traffic to the cheaper model and 10% to Haiku — useful for cost-optimised deployments with occasional quality spot-checks.

### `round_robin`

Rotates through active targets in sequence using an atomic shared-dict counter. Each target receives approximately equal traffic over time regardless of weight values (weights are ignored in this mode).

---

## Sticky Sessions

Sticky sessions guarantee that requests sharing the same field value are always routed to the same target for the duration of the TTL.

```json
"load_balance": {
  "strategy": "weighted_random",
  "sticky": { "field": "meta.user_id", "ttl": 3600 },
  "targets": [
    { "provider": "openai",    "model": "gpt-4o",            "weight": 1 },
    { "provider": "anthropic", "model": "claude-sonnet-4-6", "weight": 1 }
  ]
}
```

The sticky value is hashed (CRC32) and the resulting target index is stored in the config shared dict with the configured TTL. On first encounter (or after TTL expiry), a target is selected by the configured strategy and then cached.

The `meta.<key>` syntax reads from `x-aig-meta-<key>` request headers. For example, `"meta.user_id"` reads `x-aig-meta-user-id`.

---

## Disabling Targets

Set `weight: 0` to disable a target without removing it from the config. This is useful for temporarily removing a provider (e.g. during maintenance) without losing the configuration.

```json
"targets": [
  { "provider": "openai",    "model": "gpt-4o",            "weight": 1 },
  { "provider": "anthropic", "model": "claude-sonnet-4-6", "weight": 0 }
]
```

Disabled targets are skipped during selection. If all targets are disabled, the rule falls through to the next matching rule.

---

## Fallback Behaviour

The selected target is the primary provider for the request. All other **active** (weight > 0) targets that were not selected are automatically made available as fallbacks — the gateway will try them in order if the primary fails. This means load balancing and automatic failover work together with no additional configuration.

---

## Examples

### 70/30 split across OpenAI and Anthropic

```json
{
  "priority": 10,
  "conditions": [],
  "enabled": true,
  "actions": {
    "load_balance": {
      "strategy": "weighted_random",
      "targets": [
        { "provider": "openai",    "model": "gpt-4o",            "weight": 7 },
        { "provider": "anthropic", "model": "claude-sonnet-4-6", "weight": 3 }
      ]
    }
  }
}
```

### Canary: 5% traffic to a new model

```json
{
  "priority": 20,
  "conditions": [],
  "enabled": true,
  "actions": {
    "load_balance": {
      "strategy": "weighted_random",
      "targets": [
        { "provider": "openai", "model": "gpt-4o",      "weight": 19 },
        { "provider": "openai", "model": "gpt-4o-2024-11-20", "weight": 1 }
      ]
    }
  }
}
```

### Consistent routing per user (sticky sessions)

```json
{
  "priority": 10,
  "conditions": [],
  "enabled": true,
  "actions": {
    "load_balance": {
      "strategy": "weighted_random",
      "sticky": { "field": "meta.user_id", "ttl": 86400 },
      "targets": [
        { "provider": "openai",    "model": "gpt-4o",            "weight": 1 },
        { "provider": "anthropic", "model": "claude-sonnet-4-6", "weight": 1 }
      ]
    }
  }
}
```

### Spread API key rate limits across three keys (same provider)

```json
{
  "priority": 5,
  "conditions": [{ "field": "model", "op": "prefix", "value": "gpt-" }],
  "enabled": true,
  "actions": {
    "load_balance": {
      "strategy": "round_robin",
      "targets": [
        { "provider": "openai", "model": "gpt-4o", "weight": 1 },
        { "provider": "openai", "model": "gpt-4o", "weight": 1 },
        { "provider": "openai", "model": "gpt-4o", "weight": 1 }
      ]
    }
  }
}
```

!!! note
    To use different API keys on the same provider, store them under different BYOK aliases and use `x-aig-byok-alias` per target. Multi-key round-robin via aliases is planned but not yet supported as a first-class config option.

---

## See Also

- [Dynamic Routing & Fallback](fallback.md)
- [Circuit Breaker](circuit-breaker.md) — automatically removes unhealthy targets
- [Gateway Configuration Reference](../reference/config-reference.md)
