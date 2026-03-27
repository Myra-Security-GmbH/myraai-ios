# NLP PII Detector

The NLP PII Detector is a **Tier 2** (sidecar HTTP call, milliseconds) guardrail that uses an NLP-based named entity recognition engine to detect and optionally anonymize personally identifiable information (PII) in request and response bodies. The detection engine runs as a locally hosted sidecar within Myra's certified infrastructure — data is never transmitted outside the Myra perimeter.

![Presidio (NLP) guardrail editor](../../assets/screenshots/guardrail-presidio.png)

---

## Configuration Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | string | — | Must be `"presidio"` |
| `name` | string | — | Human-readable label for this guardrail instance |
| `action` | string | `"flag"` | What to do when PII is detected: `block`, `scrub`, or `flag` |
| `target` | string | `"request"` | Which phase to inspect: `request`, `response`, or `both` |
| `entities` | array \| null | `null` | Entity types to detect; `null` detects all supported entity types |
| `score_threshold` | number | `0.7` | Minimum confidence score for a detection to count (0.0–1.0) |
| `allow_list` | array \| null | `null` | Values that are never flagged as PII, regardless of confidence score |
| `allow_list_match` | string | `"exact"` | How allow-list entries are matched: `"exact"` (full string) or `"partial"` (substring) |
| `timeout_ms` | integer | `3000` | Timeout for the sidecar call in milliseconds |
| `fail_open` | boolean | `true` | If `true`, sidecar errors allow the request to pass through; if `false`, they block it |

!!! note "Automatic language detection"
    The detection engine automatically identifies the language of each request and applies the appropriate NLP model. English and German are fully supported; other Latin-script languages are handled on a best-effort basis. No `language` field is required.

---

## Actions

| Action | Behavior |
|---|---|
| `block` | Request is denied if any entity is detected above the confidence threshold. The caller receives a synthetic assistant message. |
| `scrub` | Detected spans are replaced with `<ENTITY_TYPE>` placeholders (e.g. `<EMAIL_ADDRESS>`). The pipeline continues with the redacted body. |
| `flag` | Entity detections are recorded in the request log. The pipeline continues without modifying the body. |

!!! note "Scrub produces irreversible placeholders"
    When `action: "scrub"` is used, matched PII is replaced with static labels like `<PERSON>` or `<EMAIL_ADDRESS>`. Two different people both become `<PERSON>`. If the model's output needs to reference the original values (for example, drafting a personalised email), use the [PII Protector guardrail](pii-protector.md) instead, which tokenizes PII reversibly.

---

## Supported Entity Types

The NLP PII Detector supports 50+ entity types. The following are commonly configured. FP rates are benchmarked at `score_threshold: 0.7` across representative general-purpose and business text corpora.

| Entity Type | Description | FP risk at 0.7 |
|---|---|---|
| `EMAIL_ADDRESS` | Email addresses | Low |
| `PHONE_NUMBER` | Phone numbers | Low |
| `US_SSN` | US Social Security numbers | Low |
| `CREDIT_CARD` | Credit card numbers (Luhn-validated) | Low |
| `US_BANK_NUMBER` | US bank account numbers | Low |
| `IBAN_CODE` | IBAN bank account codes | Low |
| `US_PASSPORT` | US passport numbers (regex, US format only) | Low |
| `PASSPORT` | Passport numbers in any format — detected via NER (multilingual) | Low |
| `US_DRIVER_LICENSE` | US driver's licence numbers | Low |
| `US_ITIN` | Individual Taxpayer Identification Numbers | Low |
| `CRYPTO` | Cryptocurrency wallet addresses | Low |
| `IP_ADDRESS` | IPv4 and IPv6 addresses | Low |
| `MEDICAL_LICENSE` | Medical licence numbers | Low |
| `URL` | Web URLs | Low |
| `ORG` | Company and organisation names — detected via NER (multilingual) | **Medium** — threshold auto-raised to 0.85 |
| `PERSON` | Full or partial person names | **High** — ~20% FP; threshold auto-raised to 0.9 |
| `LOCATION` | Location names | **High** — ~18% FP; threshold auto-raised to 0.9 |
| `DATE_TIME` | Dates and times | **High** — ~7–14% FP; threshold auto-raised to 0.9 |

!!! tip "Focused PII preset"
    For `action: block` or `action: scrub`, restrict `entities` to the 14 low-FP types and omit `ORG`, `PERSON`, `LOCATION`, and `DATE_TIME`. This set produces 0% false positives across benchmarks. The gateway automatically raises `score_threshold` to 0.85 for `ORG` and to 0.9 for the other named-entity types when they are included.

To restrict detection to specific entity types, provide them in the `entities` array. Set `entities` to `null` (or omit it) to detect all supported types.

---

## `fail_open` Behavior

| `fail_open` | Sidecar unavailable |
|---|---|
| `true` (default) | Request passes through as if no PII was found |
| `false` | Request is blocked |

!!! warning
    Set `fail_open: false` when PII detection is a hard compliance requirement. With `fail_open: true`, a sidecar outage allows all traffic through uninspected.

---

## Examples

### Block any request containing detected PII

```json
{
  "type": "presidio",
  "name": "block-pii",
  "action": "block",
  "target": "request",
  "fail_open": false
}
```

### Scrub specific financial entity types from both request and response

```json
{
  "type": "presidio",
  "name": "scrub-financial",
  "action": "scrub",
  "target": "both",
  "entities": ["CREDIT_CARD", "IBAN_CODE", "US_BANK_NUMBER"],
  "score_threshold": 0.85
}
```

### Flag PII in responses for audit purposes only

```json
{
  "type": "presidio",
  "name": "flag-pii-responses",
  "action": "flag",
  "target": "response"
}
```

### Exempt specific values from detection

Use `allow_list` to prevent known non-PII values from triggering a detection. The example below exempts the company name and a product name that the NLP model may otherwise classify as a person or organisation.

```json
{
  "type": "presidio",
  "name": "block-pii",
  "action": "block",
  "target": "request",
  "entities": ["PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER"],
  "allow_list": ["Myra Security", "AI Gateway"],
  "allow_list_match": "exact"
}
```

### Use Presidio after a regex pre-filter

Running a regex guardrail first (Tier 1) can reduce the volume of content reaching the Presidio sidecar (Tier 2). The example below blocks obvious PCI patterns in-process, then sends everything else to Presidio for broader PII detection.

```json
[
  {
    "type": "regex",
    "name": "block-pci",
    "action": "block",
    "target": "request",
    "patterns": ["pci_pan"]
  },
  {
    "type": "presidio",
    "name": "scrub-remaining-pii",
    "action": "scrub",
    "target": "request",
    "entities": ["PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER", "US_SSN"]
  }
]
```

---

## Streaming Limitation

!!! warning "Streaming responses"
    When `target` is `"response"` or `"both"`, response-phase inspection only applies to non-streaming responses. Streamed responses are not buffered by the gateway, so response-phase scrubbing and flagging are skipped for them. Request-phase inspection is unaffected.

---

## Pipeline Position

The NLP PII Detector is **Tier 2** — it makes an HTTP call to a sidecar service. All Tier 1 guardrails (regex, keyword) run before any Tier 2 guardrail. Within Tier 2, guardrails run in the order they appear in the `guardrails` array.

---

## See Also

- [Guardrail Pipeline Overview](../guardrails.md)
- [Regex Guardrail](regex.md) — in-process pattern matching, no sidecar required
- [PII Protector](pii-protector.md) — reversible tokenization that restores original values in the response
