# Regex Detector

The regex detector is a **Tier 1** (in-process, sub-millisecond) detector that scans request and response content against named pattern libraries or custom expressions. It is the recommended starting point for detecting structured sensitive data such as PII, payment card numbers, credentials, and healthcare identifiers.

---

## Configuration Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | string | — | Must be `"regex"` |
| `name` | string | — | Human-readable label for this detector instance |
| `action` | string | `"flag"` | What to do on a match: `block`, `scrub`, or `flag` |
| `target` | string | `"request"` | Which traffic to inspect: `request`, `response`, or `both` |
| `patterns` | array | `[]` | Named patterns or pattern sets to match (see tables below) |
| `custom_patterns` | array | `[]` | Raw regex strings to match in addition to named patterns |
| `scrub_placeholder` | string | `"[REDACTED]"` | Replacement text used when `action` is `"scrub"` |

---

## Named Patterns

Reference these by name in the `patterns` array.

| Name | Description |
|---|---|
| `email` | Email addresses |
| `phone` | Phone numbers (international format) |
| `ssn` | US Social Security Numbers (dashes optional) |
| `dob` | Dates of birth (MM/DD/YYYY or MM-DD-YYYY) |
| `ip_address` | IPv4 addresses |
| `cc` | Credit/debit card numbers (Luhn-validated) |
| `cvv` | Card verification values |
| `card_expiry` | Card expiry dates |
| `iban` | International Bank Account Numbers |
| `routing_number` | ABA routing numbers (9-digit) |
| `mrn` | Medical Record Numbers |
| `npi` | National Provider Identifiers |
| `national_id` | National ID numbers |
| `passport_number` | Passport numbers |
| `api_key` | API key patterns (key=value format) |
| `jwt` | JSON Web Tokens (ey... three-segment format) |

!!! note "Credit card Luhn validation"
    The `cc` pattern applies a Luhn checksum check in addition to format matching. This significantly reduces false positives from 16-digit numbers that happen to match a card number format but are not valid card numbers.

---

## Pattern Sets

Pattern sets are shorthand aliases that expand to multiple named patterns. Use them in the `patterns` array the same way as individual pattern names.

| Set | Patterns included |
|---|---|
| `pci_pan` | `cc`, `cvv`, `card_expiry`, `iban`, `routing_number` |
| `hipaa_structured` | `ssn`, `mrn`, `npi`, `dob`, `phone`, `email`, `ip_address` |
| `gdpr_structured` | `email`, `phone`, `ip_address`, `iban`, `national_id`, `passport_number` |
| `credentials` | `api_key`, `jwt` |
| `pii_basic` | `email`, `phone`, `ssn` |

---

## Examples

### Block requests containing credit card numbers

This configuration uses the `pci_pan` pattern set to block any request that contains a credit or debit card number, CVV, expiry date, IBAN, or routing number.

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
        }
      ]
    }
  }'
```

### Scrub credentials from requests and responses

This configuration detects API keys and JWTs in both the outbound request and the inbound model response, replacing any matches with a custom placeholder before the content is forwarded or returned to the caller.

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

### Flag a custom internal ID format

Use `custom_patterns` to match formats not covered by the named pattern library. This example flags any occurrence of an internal customer ID (`CUST-` followed by six digits) in outbound requests, recording the match in the log without blocking or modifying the request.

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
    `custom_patterns` and `patterns` can be combined in a single detector. Both lists are evaluated, and the configured `action` applies if any pattern from either list matches.

---

## See Also

- [Detector Pipeline Overview](../detectors.md)
- [Keyword Detector](keyword.md)
- [Presidio Detector](presidio.md)