# LLM Guard Detector

The LLM Guard detector uses Meta's Llama Guard 3 model to classify request and response content against 14 safety categories. It runs as a platform-managed sidecar on the Global Myra Security CDN — no deployment or infrastructure configuration is required on your side.

## Configuration

Add an LLM Guard detector object to your route's `detectors` array:

```json
{
  "type": "llm_guard",
  "name": "my-safety-filter",
  "action": "block",
  "target": "both",
  "categories": ["S1", "S9", "S10"]
}
```

### Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | string | — | Must be `"llm_guard"` |
| `name` | string | — | Human-readable label for this detector instance |
| `action` | string | `"block"` | What to do on a safety violation: `block` or `flag` |
| `target` | string | `"request"` | Which phase to classify: `request`, `response`, or `both` |
| `timeout_ms` | integer | `2000` | Timeout for the sidecar call in milliseconds |
| `fail_open` | boolean | `true` | If `true`, sidecar errors allow the request to pass through; if `false`, they block it |
| `categories` | array \| null | `null` | Safety categories to enforce; `null` enforces all 14 categories |

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

## Category Filtering

When `categories` is set to an array, the detector only blocks or flags violations within the listed categories. Content classified as unsafe for a category not in your list is treated as safe and does not trigger the configured action.

When `categories` is `null` or omitted, all 14 categories are enforced.

## Actions

| Action | Behavior |
|---|---|
| `block` | The request or response is denied. The caller receives a synthetic assistant message describing which categories triggered the block (see note below). |
| `flag` | The violation is recorded in the request log. The pipeline continues without modification. |

!!! note "Block response format"
    When a request is blocked, AI Gateway returns a synthetic assistant message identifying the triggering categories. For example:

    ```
    Request blocked by content policy (safety-filter): S1 – Violent Crimes, S9 – Weapons of Mass Destruction (CBRN)
    ```

    The detector `name` field value appears in the message, making it easy to correlate blocks with your detector configuration.

The `scrub` action is not supported for LLM Guard. Configure `block` or `flag` as appropriate.

## fail_open Behavior

When `fail_open: true` (the default), if the LLM Guard sidecar is unavailable or the call times out, the request is allowed to continue as if no safety violation was found. This prioritizes availability over enforcement.

When `fail_open: false`, any sidecar unavailability or timeout causes the request to be blocked. Use this setting in environments where safety enforcement must never be bypassed.

## Limitations

- **`scrub` action not supported.** Configure `block` or `flag` only.
- **Request phase classifies only the last user message.** The full conversation history is not sent to the classifier. Only the most recent user turn is evaluated.
- **Input truncation.** Inputs longer than approximately 4,096 tokens are truncated before classification.

## Examples

### Block violent, extremist, and harmful content

```json
{
  "type": "llm_guard",
  "name": "safety-filter",
  "action": "block",
  "target": "both",
  "categories": ["S1", "S4", "S9", "S10", "S11", "S12"]
}
```

### Flag specialized advice in responses for audit (no blocking)

```json
{
  "type": "llm_guard",
  "name": "flag-advice",
  "action": "flag",
  "target": "response",
  "categories": ["S6"]
}
```

### Enforce all 14 categories on requests, blocking on sidecar failure

```json
{
  "type": "llm_guard",
  "name": "full-safety",
  "action": "block",
  "target": "request",
  "fail_open": false
}
```

## See Also

- [Detector Pipeline Overview](../detectors.md)
