# Guardrail Pipeline Overview

AI Gateway evaluates every request and response through a configurable **guardrail pipeline**. Each guardrail inspects message content and returns a verdict — `block`, `scrub`, or `flag` — that controls how the gateway handles the traffic.

---

![Guardrails builder](../assets/screenshots/guardrails-builder.png)

## Guardrail Tiers

Guardrails are grouped into two tiers based on where they execute and how fast they run.

| Tier | Guardrails | Execution | Latency |
|---|---|---|---|
| Tier 1 | `regex`, `keyword`, `jailbreak` | In-process | Sub-millisecond |
| Tier 2 | `presidio`, `prompt_guard`, `pii_protector` | Sidecar HTTP call | Milliseconds |

All Tier 1 guardrails run before any Tier 2 guardrail. Within the same tier, guardrails run in the order they appear in the `guardrails` array of the gateway configuration.

---

## Execution Order and Verdicts

The pipeline processes guardrails sequentially according to the following rules.

**Verdict behavior:**

| Verdict | Effect on pipeline |
|---|---|
| `block` | Request is denied immediately. No further guardrails run. |
| `scrub` | Matched content is replaced in the body. Pipeline continues. |
| `flag` | Match is recorded in the log entry. Pipeline continues. |

A `block` verdict from any single guardrail stops the entire pipeline. `scrub` and `flag` verdicts are non-terminal — the remaining guardrails still run after the match is recorded or the content is redacted.

---

## Targets

Each guardrail declares which traffic direction it inspects.

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

Matched content is replaced with a placeholder string before the body is forwarded. The default placeholder is `[REDACTED]`; the regex guardrail allows a custom value via `scrub_placeholder`.

!!! warning "Scrub support by guardrail type"
    The `keyword`, `jailbreak`, and `prompt_guard` guardrails do not support `scrub`. If `action: "scrub"` is configured on those guardrails, the action is treated as `flag`.

### `flag`

The match is recorded in the gateway log entry for the request. The body is not modified and the request is not blocked.

---

## Tier 2 Availability: `fail_open`

Tier 2 guardrails make an HTTP call to a locally hosted sidecar service running within Myra's certified infrastructure. Prompt content never leaves the Myra perimeter. If the sidecar is unavailable, the `fail_open` setting controls what happens.

| `fail_open` | Sidecar unavailable |
|---|---|
| `true` (default) | Request passes through as if no match occurred |
| `false` | Request is blocked |

!!! warning
    Set `fail_open: false` when the sidecar is a hard dependency for your security policy. With the default `fail_open: true`, a sidecar outage allows all traffic through uninspected.

---

## Configuration

### Using the admin UI

Guardrails are configured using the visual **Guardrail Builder**, which appears in two places:

- **Existing gateway** — open the gateway detail page (click **Open →** on the gateway row), then scroll down to the **Guardrails** card.
- **New gateway** — the Guardrail Builder is embedded at the bottom of the **New Gateway** modal.

**To add a guardrail:**

Click the type button for the guardrail you want to add — there is one button per type:

- `+ Regex / Pattern` — named pattern library and custom regex
- `+ Keyword` — exact string matching
- `+ Jailbreak` — zero-config detector pre-loaded with 18 known attack phrases
- `+ Presidio (NLP)` — NLP-based PII detection
- `+ Prompt Guard` — semantic safety classification (Llama Guard 3, locally hosted)
- `+ PII Protector` — reversible PII tokenization

After clicking, a collapsed guardrail card appears at the bottom of the list. Click the card to expand it and configure:

- **Name** — human-readable label for this guardrail instance
- **Action** — what happens on a match: `block`, `scrub` (not available on Keyword, Jailbreak, or Prompt Guard), or `flag`
- **Target** — which direction to inspect: `request` (default), `response`, or `both`
- Type-specific fields (patterns, keywords, entities, etc.)

**To save:**

- On the detail page: click **Save Guardrails** in the Guardrails card header.
- In the New Gateway modal: complete the rest of the form and click **Create Gateway**.

**To reorder guardrails:**

Use the **▲▼** arrows on the left side of each guardrail card. Order matters within a tier — Tier 1 always runs before Tier 2, but within the same tier execution follows list order.

**To view the execution plan:**

The **Execution plan** table appears automatically below the guardrail list whenever one or more guardrails are configured. It shows Tier, Name, Phase (→ request / ← response / ⇄ both), and Mode for each guardrail in execution order.

**To remove a guardrail:**

Click the **×** button on the right side of the guardrail card header.

### API

Guardrails are configurable via the Admin API as the `guardrails` array in the gateway config. See [Tenants & Gateways API](../api-reference/tenants-gateways.md) for the PATCH endpoint.

Two read-only endpoints expose guardrail activity for a gateway.

**`GET /admin/v1/gateways/{id}/guardrail-stats`** — Returns a summary of guardrail activity over the last 24 hours.

```bash
curl "https://<your-gateway-host>/admin/v1/gateways/gw_xyz789/guardrail-stats"
```

Response:

| Field | Type | Description |
|---|---|---|
| `blocked` | integer | Requests blocked by a guardrail in the last 24h. |
| `scrubbed` | integer | Requests where content was scrubbed (not blocked) in the last 24h. |
| `flagged` | integer | Requests where a guardrail fired but neither blocked nor scrubbed in the last 24h. |
| `avg_guardrail_ms` | number | Average guardrail processing time across all guardrail calls in the last 24h. |

Example response:

```json
{
  "blocked": 14,
  "scrubbed": 8,
  "flagged": 3,
  "avg_guardrail_ms": 42
}
```

**`GET /admin/v1/gateways/{id}/guardrail-events`** — Returns individual request events where a guardrail fired (blocked, scrubbed, or flagged), ordered newest-first.

```bash
curl "https://<your-gateway-host>/admin/v1/gateways/gw_xyz789/guardrail-events?limit=50"
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `limit` | integer | `50` | Maximum events to return. Range: 1–200. |

Each event includes: `ts`, `blocked`, `scrub_applied`, `detectors_fired`, `blocked_by`, `block_reason`, `guardrail_verdict`, `guardrail_latency_ms`, `provider`, `model`, `latency_ms`.

Example config:

```json
{
  "guardrails": [
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
```

In this example, the `regex` guardrail (Tier 1) runs first. If a PCI pattern is found, the request is blocked and the `presidio` guardrail never runs. If no match is found, the `presidio` guardrail (Tier 2) runs and scrubs any PII from both the request and the response.

---

## Log Fields

Every guardrail that runs produces structured output. The following fields are set on the gateway log entry for the request.

| Field | Type | Description |
|---|---|---|
| `blocked` | boolean | `true` if any guardrail blocked the request |
| `blocked_by` | string | Name of the guardrail that issued the block verdict |
| `block_reason` | string | Pattern name or category code that triggered the block |
| `detectors_fired` | array | Names of all guardrails that produced a non-pass verdict |

---

## Guardrail Types

| Type | Tier | Description |
|---|---|---|
| [`regex`](guardrails/regex.md) | 1 | In-process regex and named pattern matching |
| [`keyword`](guardrails/keyword.md) | 1 | In-process exact keyword matching |
| [`jailbreak`](guardrails/jailbreak.md) | 1 | Pre-configured jailbreak and prompt-injection detector — zero configuration required |
| [`presidio`](guardrails/presidio.md) | 2 | NLP-based PII detection — locally hosted within Myra's certified infrastructure |
| [`prompt_guard`](guardrails/prompt-guard.md) | 2 | Safety classification via Llama Guard 3 — locally hosted within Myra's certified infrastructure |
| [`pii_protector`](guardrails/pii-protector.md) | 2 | Reversible PII tokenization — real values restored in response |

---

## Jailbreak and Prompt-Injection Detection

AI Gateway ships a dedicated `jailbreak` guardrail type that works with zero configuration — add a single JSON object and detection begins immediately using 18 built-in attack phrases. See the **[Jailbreak Guardrail](guardrails/jailbreak.md)** page for full configuration reference, the complete phrase list, and layering guidance.

---

## See Also

- [Regex Guardrail](guardrails/regex.md)
- [Keyword Guardrail](guardrails/keyword.md)
- [Jailbreak Guardrail](guardrails/jailbreak.md)
- [NLP PII Detector](guardrails/presidio.md)
- [Prompt Guard](guardrails/prompt-guard.md)
- [PII Protector](guardrails/pii-protector.md)
- [Logs API](../api-reference/logs.md) — `blocked_by`, `block_reason`, `guardrail_verdict` fields
- [Gateway Configuration Reference](../reference/config-reference.md) — `guardrails` array
