# Prompt Guard

The Prompt Guard guardrail is a **Tier 2** (sidecar HTTP call, milliseconds) guardrail that uses Meta's Llama Guard 3 model to classify request and response content against 14 safety categories. It is designed to detect harmful, illegal, or policy-violating content that rule-based guardrails cannot cover.

---

## Configuration Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | string | — | Must be `"prompt_guard"` |
| `name` | string | — | Human-readable label for this guardrail instance |
| `action` | string | `"block"` | What to do on a safety violation: `block` or `flag` |
| `target` | string | `"request"` | Which phase to classify: `request`, `response`, or `both` |
| `timeout_ms` | integer | `2000` | Timeout for the sidecar call in milliseconds |
| `fail_open` | boolean | `true` | If `true`, sidecar errors allow the request to pass through; if `false`, they block it |
| `categories` | array \| null | `null` | Safety categories to enforce; `null` enforces all 14 categories |

---

## Safety Categories

| Code | Category |
|---|---|
| `S1` | Violent Crimes |
| `S2` | Non-Violent Crimes |
| `S3` | Sex-Related Crimes |
| `S4` | Child Sexual Exploitation |
| `S5` | Defamation |
| `S6` | Specialized Advice (medical, legal, or financial) |
| `S7` | Privacy Violations |
| `S8` | Intellectual Property Infringement |
| `S9` | Weapons of Mass Destruction (CBRN) |
| `S10` | Hate Speech |
| `S11` | Suicide and Self-Harm |
| `S12` | Explicit Sexual Content |
| `S13` | Elections Integrity |
| `S14` | Code Interpreter Abuse |

---

## Category Filtering

When `categories` is set to an array, the guardrail only blocks or flags violations within the listed categories. Content classified as unsafe for a category not in your list is treated as safe.

When `categories` is `null` or omitted, all 14 categories are enforced.

---

## Actions

| Action | Behavior |
|---|---|
| `block` | The request or response is denied. The caller receives a synthetic assistant message identifying which categories triggered the block. |
| `flag` | The violation is recorded in the request log. The pipeline continues without modification. |

!!! note "Block response format"
    When a request is blocked, the gateway returns a synthetic assistant message identifying the triggering categories. For example:

    ```
    Request blocked by content policy (safety-filter): S1 – Violent Crimes, S9 – Weapons of Mass Destruction (CBRN)
    ```

    The guardrail `name` field value appears in the message, making it easy to correlate blocks with your guardrail configuration.

!!! warning "Scrub not supported"
    Prompt Guard does not support `action: "scrub"`. Configure `block` or `flag` only.

---

## `fail_open` Behavior

| `fail_open` | Sidecar unavailable |
|---|---|
| `true` (default) | Request passes through as if no violation was found |
| `false` | Request is blocked |

!!! warning
    Set `fail_open: false` in environments where safety enforcement must never be bypassed. With `fail_open: true`, a sidecar outage allows all traffic through unclassified.

---

## Limitations

- **`scrub` action not supported.** Configure `block` or `flag` only.
- **Request phase classifies only the last user message.** The full conversation history is not sent to the classifier. Only the most recent user turn is evaluated.
- **Input truncation.** Inputs longer than approximately 4,096 tokens are truncated before classification.
- **Not a replacement for Tier 1 guardrails.** For structured sensitive data (PII, card numbers, credentials), use regex or Presidio guardrails. Prompt Guard is optimised for unstructured content policy enforcement.

---

## Examples

### Block violent, extremist, and harmful content

```json
{
  "type": "prompt_guard",
  "name": "safety-filter",
  "action": "block",
  "target": "both",
  "categories": ["S1", "S4", "S9", "S10", "S11", "S12"]
}
```

### Flag specialized advice in responses for audit (no blocking)

```json
{
  "type": "prompt_guard",
  "name": "flag-advice",
  "action": "flag",
  "target": "response",
  "categories": ["S6"]
}
```

### Enforce all 14 categories on requests, blocking on sidecar failure

```json
{
  "type": "prompt_guard",
  "name": "full-safety",
  "action": "block",
  "target": "request",
  "fail_open": false
}
```

### Layer Prompt Guard after keyword pre-filtering

Running keyword guardrails first (Tier 1) can catch simple jailbreak strings before Prompt Guard's more expensive sidecar call.

```json
[
  {
    "type": "keyword",
    "name": "jailbreak-terms",
    "action": "block",
    "target": "request",
    "keywords": ["ignore previous instructions", "DAN mode", "jailbreak"],
    "case_sensitive": false
  },
  {
    "type": "prompt_guard",
    "name": "safety-filter",
    "action": "block",
    "target": "both",
    "categories": ["S1", "S3", "S4", "S9", "S10", "S11", "S12"]
  }
]
```

---

## Pipeline Position

Prompt Guard is **Tier 2** — it makes an HTTP call to a sidecar service. All Tier 1 guardrails (regex, keyword) run before any Tier 2 guardrail. Within Tier 2, guardrails run in the order they appear in the `guardrails` array.

---

## See Also

- [Guardrail Pipeline Overview](../guardrails.md)
- [Keyword Guardrail](keyword.md) — fast exact-string blocking, useful as a Tier 1 pre-filter
- [Presidio Guardrail](presidio.md) — NLP-based PII detection
