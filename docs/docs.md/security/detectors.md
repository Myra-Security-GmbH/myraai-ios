# Detector Pipeline Overview

AI Gateway by Myra Security evaluates every request and response through a configurable **detector pipeline**. Each detector inspects message content and returns a verdict — `block`, `scrub`, or `flag` — that controls how the gateway handles the traffic.

---

## Detector Tiers

Detectors are grouped into two tiers based on where they execute and how fast they run.

| Tier | Detectors | Execution | Latency |
|---|---|---|---|
| Tier 1 | `regex`, `keyword` | In-process | Sub-millisecond |
| Tier 2 | `presidio`, `llm_guard`, `pii_protector` | Sidecar HTTP call | Milliseconds |

All Tier 1 detectors run before any Tier 2 detector. Within the same tier, detectors run in the order they appear in the `detectors` array of the gateway configuration.

---

## Execution Order and Verdicts

The pipeline processes detectors sequentially according to the following rules.

**Verdict behavior:**

| Verdict | Effect on pipeline |
|---|---|
| `block` | Request is denied immediately. No further detectors run. |
| `scrub` | Matched content is replaced in the body. Pipeline continues. |
| `flag` | Match is recorded in the log entry. Pipeline continues. |

A `block` verdict from any single detector stops the entire pipeline. `scrub` and `flag` verdicts are non-terminal — the remaining detectors still run after the match is recorded or the content is redacted.

---

## Targets

Each detector declares which traffic direction it inspects.

| Target | Description |
|---|---|
| `request` | Inspect the outbound request body (default) |
| `response` | Inspect the inbound model response body |
| `both` | Inspect both the request and the response |

---

## Actions

### `block`

The request is denied. The caller receives a synthetic HTTP 200 response containing an assistant-role message that describes the reason for blocking. No upstream model call is made.

Example block message:

```
Request blocked by content policy (block-pci): cc – Credit/Debit Card Number
```

For streaming requests, the synthetic block message is delivered as SSE events using the same format the model would use, so streaming clients do not need special handling.

### `scrub`

Matched content is replaced with a placeholder string before the body is forwarded. The default placeholder is `[REDACTED]`; the regex detector allows a custom value via `scrub_placeholder`.

!!! warning "Scrub support by detector type"
    The `keyword` and `llm_guard` detectors do not support `scrub`. If `action: "scrub"` is configured on those detectors, the action is treated as `flag`.

### `flag`

The match is recorded in the gateway log entry for the request. The body is not modified and the request is not blocked.

---

## Tier 2 Availability: `fail_open`

Tier 2 detectors make an HTTP call to an external sidecar service. If that service is unavailable, the `fail_open` setting controls what happens.

| `fail_open` | Sidecar unavailable |
|---|---|
| `true` (default) | Request passes through as if no match occurred |
| `false` | Request is blocked |

!!! warning
    Set `fail_open: false` when the sidecar is a hard dependency for your security policy. With the default `fail_open: true`, a sidecar outage allows all traffic through uninspected.

---

## Configuration

Detectors are configured in the gateway's `config.detectors` array. The gateway configuration is managed through the Admin API.

```bash
curl -X PATCH "https://<your-gateway-host>/admin/v1/gateways/{id}" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "detectors": [
        {
          "type": "regex",
          "name": "block-pci",
          "action": "block",
          "target": "request",
          "patterns": ["pci_pan"]
        },
        {
          "type": "presidio",
          "name": "scrub-pii",
          "action": "scrub",
          "target": "both",
          "fail_open": true
        }
      ]
    }
  }'
```

In this example, the `regex` detector (Tier 1) runs first. If a PCI pattern is found, the request is blocked and the `presidio` detector never runs. If no match is found, the `presidio` detector (Tier 2) runs and scrubs any PII from both the request and the response.

---

## Log Fields

Every detector that runs produces structured output. The following fields are set on the gateway log entry for the request.

| Field | Type | Description |
|---|---|---|
| `blocked` | boolean | `true` if any detector blocked the request |
| `blocked_by` | string | Name of the detector that issued the block verdict |
| `block_reason` | string | Pattern name or category code that triggered the block |
| `detector_results` | object | Map of detector name to result for every detector that ran |

---

## See Also

- [Regex Detector](detectors/regex.md)
- [Keyword Detector](detectors/keyword.md)
- [Presidio Detector](detectors/presidio.md)
- [LLM Guard Detector](detectors/llm-guard.md)
- [PII Protector Detector](detectors/pii-protector.md)