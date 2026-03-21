# Presidio Detector

The Presidio detector is a Tier 2 sidecar detector that uses Microsoft Presidio's NLP-based named entity recognition to detect and optionally anonymize personally identifiable information (PII) in request and response bodies. It runs as a platform-managed sidecar on the Global Myra Security CDN — no deployment or infrastructure configuration is required on your side.

## Configuration

Add a Presidio detector object to your route's `detectors` array:

```json
{
  "type": "presidio",
  "name": "my-presidio-detector",
  "action": "scrub",
  "target": "both",
  "entities": ["PERSON", "EMAIL_ADDRESS"],
  "score_threshold": 0.75
}
```

### Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | string | — | Must be `"presidio"` |
| `name` | string | — | Human-readable label for this detector instance |
| `action` | string | `"flag"` | What to do when PII is detected: `block`, `scrub`, or `flag` |
| `target` | string | `"request"` | Which phase to inspect: `request`, `response`, or `both` |
| `language` | string | `"en"` | Language used for entity recognition |
| `entities` | array \| null | `null` | Entity types to detect; `null` detects all supported entity types |
| `score_threshold` | number | `0.7` | Minimum confidence score for a detection to count (0.0–1.0) |
| `timeout_ms` | integer | `3000` | Timeout for the sidecar call in milliseconds |
| `fail_open` | boolean | `true` | If `true`, sidecar errors allow the request to pass through; if `false`, they block it |

## Actions

| Action | Behavior |
|---|---|
| `block` | Request is denied if any entity is detected above the confidence threshold. The caller receives an error response. |
| `scrub` | Detected spans are replaced with `<ENTITY_TYPE>` placeholders by the Presidio anonymizer. The pipeline continues with the redacted body. |
| `flag` | Entity detections are recorded in the request log. The pipeline continues without modifying the body. |

## Supported Entity Types

Presidio supports 50+ entity types. The following are among the most commonly used:

| Entity Type | Description |
|---|---|
| `PERSON` | Full or partial person names |
| `EMAIL_ADDRESS` | Email addresses |
| `PHONE_NUMBER` | Phone numbers |
| `CREDIT_CARD` | Credit card numbers |
| `IBAN_CODE` | IBAN bank account codes |
| `IP_ADDRESS` | IPv4 and IPv6 addresses |
| `US_SSN` | US Social Security numbers |
| `US_BANK_NUMBER` | US bank account numbers |
| `NRP` | Nationality, religion, or political affiliation |
| `MEDICAL_LICENSE` | Medical license numbers |
| `URL` | Web URLs |
| `DATE_TIME` | Dates and times |
| `LOCATION` | Location names |
| `ORGANIZATION` | Organization names |
| `US_PASSPORT` | US passport numbers |
| `US_DRIVER_LICENSE` | US driver's license numbers |

To restrict detection to specific entity types, provide them in the `entities` array. Set `entities` to `null` (or omit it) to detect all supported types.

## fail_open Behavior

When `fail_open: true` (the default), if the Presidio sidecar is unavailable or the call times out, the request is allowed to continue as if no PII was found. This prioritizes availability over enforcement.

When `fail_open: false`, any sidecar unavailability or timeout causes the request to be blocked. This prioritizes enforcement over availability and is appropriate for strict compliance requirements.

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

!!! note "Reversible tokenization"
    If you need the original PII values to be restored in the response — rather than permanently replaced — use the [PII Protector detector](pii-protector.md) instead. It tokenizes PII on the request side and restores the original values on the response side before they reach the client.

!!! warning "Streaming responses"
    When `action` is `"scrub"` and `target` is `"response"` or `"both"`, response-phase scrubbing only applies to non-streaming responses. Streamed responses are not buffered by the gateway, so response scrubbing is skipped for them. Request-phase scrubbing is unaffected by this limitation.

## See Also

- [Detector Pipeline Overview](../detectors.md)
- [PII Protector](pii-protector.md) — reversible tokenization that restores original values in the response
