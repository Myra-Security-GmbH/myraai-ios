# Regex Guardrail

The regex guardrail is a **Tier 1** (in-process, sub-millisecond) guardrail that scans request and response content against named pattern libraries or custom expressions. It is the recommended starting point for detecting structured sensitive data such as PII, payment card numbers, credentials, and healthcare identifiers.

---

## Configuration Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | string | — | Must be `"regex"` |
| `name` | string | — | Human-readable label for this guardrail instance |
| `action` | string | `"flag"` | What to do on a match: `block`, `scrub`, or `flag` |
| `target` | string | `"request"` | Which traffic to inspect: `request`, `response`, or `both` |
| `patterns` | array | `[]` | Named patterns or pattern sets to match (see tables below) |
| `custom_patterns` | array | `[]` | Raw regex strings to match in addition to named patterns |
| `scrub_placeholder` | string | `"[REDACTED]"` | Replacement text used when `action` is `"scrub"` |

---

## Named Patterns

Reference these by name in the `patterns` array. FP rates are benchmarked across OR-Bench-hard, XSTest-safe, Dolly-15k, and a handcrafted business-text corpus. "High FP" patterns appear legitimately in general and business text; prefer `action: flag` or use them only with `action: scrub`.

| Name | Description | FP risk |
|---|---|---|
| `email` | Email addresses | Medium — 8% FP on business text |
| `phone` | Phone numbers (international format) | **High** — 26% FP; phone numbers appear in everyday queries |
| `ssn` | US Social Security Numbers (dashes optional) | **High** — 11.5% FP; 9-digit sequences match SSN format |
| `dob` | Dates of birth (MM/DD/YYYY or MM-DD-YYYY) | Low — 0% FP |
| `ip_address` | IPv4 addresses | **High** — 13% FP; IP addresses appear in technical text |
| `cc` | Credit/debit card numbers (Luhn-validated) | Low — 2% FP (Luhn check eliminates most false matches) |
| `cvv` | Card verification values | Low — 0% FP |
| `card_expiry` | Card expiry dates | Low — 1.5% FP |
| `iban` | International Bank Account Numbers | Low — 0% FP |
| `routing_number` | ABA routing numbers (9-digit) | Medium — 5% FP; 9-digit numbers are common |
| `mrn` | Medical Record Numbers | Low — 0% FP |
| `npi` | National Provider Identifiers | Low — 0.5% FP |
| `national_id` | National ID numbers | Low — 0% FP |
| `passport_number` | Passport numbers | Low — 0% FP |
| `api_key` | API key patterns (key=value format) | Low — 0% FP |
| `jwt` | JSON Web Tokens (ey... three-segment format) | Low — 0% FP |

!!! tip "High-FP patterns and `action: block`"
    `phone`, `ssn`, and `ip_address` have 11–26% false positive rates on general business text. Use `action: scrub` rather than `action: block` for these patterns, or switch to the [NLP PII Detector](presidio.md) which applies NLP context to reduce false detections.

!!! note "Credit card Luhn validation"
    The `cc` pattern applies a Luhn checksum check in addition to format matching. This significantly reduces false positives from 16-digit numbers that happen to match a card number format but are not valid card numbers.

---

## Pattern Sets

Pattern sets are shorthand aliases that expand to multiple named patterns. Use them in the `patterns` array the same way as individual pattern names.

| Set | Patterns included | FP risk |
|---|---|---|
| `pci_pan` | `cc`, `cvv`, `card_expiry`, `iban`, `routing_number` | Low — all patterns are format-specific; `cc` is Luhn-validated |
| `hipaa_structured` | `ssn`, `mrn`, `npi`, `dob`, `phone`, `email`, `ip_address` | **High** — includes `phone`, `ssn`, `ip_address` which have 11–26% FP on general text |
| `gdpr_structured` | `email`, `phone`, `ip_address`, `iban`, `national_id`, `passport_number` | **High** — includes `phone` and `ip_address` |
| `credentials` | `api_key`, `jwt` | Low — format-specific; 0% FP |
| `pii_basic` | `email`, `phone`, `ssn` | **High** — includes `phone` and `ssn` |

!!! tip "Prefer `scrub` over `block` for broad pattern sets"
    `hipaa_structured`, `gdpr_structured`, and `pii_basic` all include high-FP patterns. Use `action: scrub` to redact matched content rather than `action: block`, which would deny entire requests. `pci_pan` and `credentials` are low-FP and suitable for `action: block`.

---

## Matching Behavior

- **Named patterns** use pre-compiled regular expressions maintained by the gateway. They are updated centrally and do not require configuration changes.
- **Custom patterns** use Lua POSIX-style regular expressions. They are evaluated in addition to any named patterns in the same guardrail instance.
- **Both lists are evaluated together.** If any pattern from either list matches, the configured `action` is applied.
- **All matches trigger the action.** There is no minimum-match threshold; a single occurrence is sufficient.

For `action: "scrub"`, the regex guardrail replaces each matched span individually. If multiple spans match, each is replaced independently. The `scrub_placeholder` value is used for all replacements within a single guardrail instance.

---

## Examples

### Block requests containing credit card numbers

```bash
curl -X PATCH "https://<your-gateway-host>/admin/v1/gateways/{id}" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "guardrails": [
        {
          "type": "regex",
          "name": "block-pci",
          "action": "block",
          "target": "request",
          "patterns": ["pci_pan"]
        }
      ]
    }
  }'
```

### Scrub credentials from requests and responses

Detects API keys and JWTs in both the outbound request and the inbound model response, replacing any matches with a custom placeholder.

```json
{
  "type": "regex",
  "name": "scrub-credentials",
  "action": "scrub",
  "target": "both",
  "patterns": ["credentials"],
  "scrub_placeholder": "[REDACTED-CREDENTIAL]"
}
```

### Scrub HIPAA-structured identifiers from requests

```json
{
  "type": "regex",
  "name": "hipaa-scrub",
  "action": "scrub",
  "target": "request",
  "patterns": ["hipaa_structured"]
}
```

### Flag a custom internal ID format

Use `custom_patterns` to match formats not covered by the named pattern library. This example flags any occurrence of an internal customer ID (`CUST-` followed by six digits), recording the match in the log without blocking or modifying the request.

```json
{
  "type": "regex",
  "name": "internal-ids",
  "action": "flag",
  "target": "request",
  "custom_patterns": ["CUST-%d%d%d%d%d%d"]
}
```

!!! note
    `custom_patterns` and `patterns` can be combined in a single guardrail. Both lists are evaluated, and the configured `action` applies if any pattern from either list matches.

### Combine named patterns and custom patterns

```json
{
  "type": "regex",
  "name": "combined-scrub",
  "action": "scrub",
  "target": "request",
  "patterns": ["pii_basic"],
  "custom_patterns": ["ACCT-[0-9]{10}"],
  "scrub_placeholder": "[PII]"
}
```

---

## Pipeline Position

The regex guardrail is **Tier 1** — it runs in-process with no external calls. Within the guardrail pipeline, all Tier 1 guardrails run before any Tier 2 guardrail. When multiple regex guardrails are configured, they run in the order they appear in the `guardrails` array.

A `block` verdict from this guardrail stops the pipeline immediately. No subsequent guardrails run.

---

## See Also

- [Guardrail Pipeline Overview](../guardrails.md)
- [Keyword Guardrail](keyword.md)
- [NLP PII Detector](presidio.md)
