---
title: Load balancing
description: How to distribute traffic across multiple provider and model targets using weighted random selection, round-robin, and sticky sessions.
---

# Load balancing

Load balancing distributes traffic across multiple provider/model targets within a single routing rule. The `load_balance` action type on a routing rule supports two selection strategies — `weighted_random` and `round_robin` — and optional sticky sessions.

## Strategies

### weighted_random

Selects a target with probability proportional to its weight. A target with `weight: 7` receives approximately 70% of traffic when the total weight across all targets is 10.

```json
"targets": [
  { "provider": "openai",    "model": "gpt-4o-mini",              "weight": 9 },
  { "provider": "anthropic", "model": "claude-haiku-4-5-20251001", "weight": 1 }
]
```

This routes 90% of traffic to the cheaper model and 10% to Haiku — useful for cost-optimised deployments with occasional quality spot-checks.

### round_robin

Rotates through active targets in sequence using an atomic shared-dict counter. Each target receives approximately equal traffic over time. Weight values are ignored in this mode.

## Configuration fields

| Field | Type | Default | Description |
|---|---|---|---|
| `strategy` | string | `"weighted_random"` | Target selection algorithm: `weighted_random` or `round_robin` |
| `targets` | array | — | List of provider/model targets with weights |
| `targets[].provider` | string | — | Provider name (e.g. `"openai"`) |
| `targets[].model` | string | — | Model name (e.g. `"gpt-4o"`) |
| `targets[].weight` | integer | `1` | Relative traffic weight. `0` disables the target without removing it from the config. |
| `sticky` | object | `null` | Optional sticky session configuration |
| `sticky.field` | string | — | Request field to hash for stickiness. Supports `meta.<key>` notation (e.g. `"meta.user_id"`) |
| `sticky.ttl` | integer | `3600` | Seconds to cache the target assignment per sticky value |

## Sticky sessions

Sticky sessions guarantee that requests sharing the same field value are always routed to the same target for the duration of the time-to-live (TTL).

The sticky value is hashed (CRC32) and the resulting target index is stored in the config shared dict with the configured TTL. On first encounter (or after TTL expiry), a target is selected by the configured strategy and then cached.

The `meta.<key>` syntax reads from the `x-aig-meta-<key>` request header. For example, `"meta.user_id"` reads `x-aig-meta-user-id`.

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

## Disabling targets

Set `weight: 0` to disable a target without removing it from the config. This is useful for temporarily removing a provider during maintenance without losing the configuration.

```json
"targets": [
  { "provider": "openai",    "model": "gpt-4o",            "weight": 1 },
  { "provider": "anthropic", "model": "claude-sonnet-4-6", "weight": 0 }
]
```

Disabled targets are skipped during selection. If all targets are disabled, the rule falls through to the next matching rule.

## Fallback behaviour

The selected target is the primary provider for the request. All other active targets (those with `weight` greater than 0) that were not selected are automatically made available as fallbacks — the gateway tries them in order if the primary fails. Load balancing and automatic failover work together with no additional configuration.

## Configuring load balancing

Proceed as follows to configure load balancing on a routing rule:

![Screenshot: Routing rule editor with load balance action type selected](../assets/screenshots/routing-rule-load-balance.png)
*The load balancing configuration in the routing rule editor.*

1. Open **Gateways** in the left sidebar.
   - The gateway list opens.
2. Click on the gateway you want to configure.
   - The gateway detail page opens.
3. Click on the **Routing** tab.
   - The rule list opens.
4. Click on the **Add Rule** button, or click on an existing rule to edit it.
   - The rule editor opens.
5. Select **Load balance** from the **Action type** drop-down list.
   - The load balancing configuration section appears.
6. Select the strategy from the **Strategy** drop-down list (`weighted_random` or `round_robin`).
   - The strategy is set.
7. Click on the **Add Target** button.
   - A target row appears.
8. Select the provider from the **Provider** drop-down list.
   - The provider is set.
9. Enter the model name in the **Model** text field.
   - The model is set.
10. Enter a weight value in the **Weight** text field.
    - The weight is set.
11. Repeat steps 7–10 for each additional target.
    - Each target is added to the list.
12. If required, enter a field name in the **Sticky field** text field and a TTL value in the **Sticky TTL** text field to enable sticky sessions.
    - Sticky session configuration is set.
13. Click on the **Save** button.
    - -> The routing rule is saved with the load balancing configuration.

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
        { "provider": "openai", "model": "gpt-4o",              "weight": 19 },
        { "provider": "openai", "model": "gpt-4o-2024-11-20",   "weight": 1 }
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

## See also

- [Fallback and retry](fallback.md)
- [Circuit breaker](circuit-breaker.md) — automatically removes unhealthy targets
- [Gateway configuration reference](../reference/config-reference.md)
