# Keyword Guardrail

The keyword guardrail is a **Tier 1** (in-process, sub-millisecond) guardrail that scans request and response content for exact string matches. It is suited for topic filtering, brand protection, and blocking known-bad strings where pattern-based matching is not required.

---

## Configuration Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | string | — | Must be `"keyword"` |
| `name` | string | — | Human-readable label for this guardrail instance |
| `action` | string | `"flag"` | What to do on a match: `block` or `flag` |
| `target` | string | `"request"` | Which traffic to inspect: `request`, `response`, or `both` |
| `keywords` | array | `[]` | Exact strings to match |
| `case_sensitive` | boolean | `false` | When `true`, matching is case-exact; when `false`, matching is case-insensitive |

!!! warning "Scrub is not supported"
    The keyword guardrail does not support `action: "scrub"`. If `"scrub"` is configured, the guardrail treats it as `"flag"`. To redact matched content, use the [Regex guardrail](regex.md) or [Presidio guardrail](presidio.md) instead.

---

## Matching Behavior

The keyword guardrail performs plain string matching — each keyword in the `keywords` array must appear verbatim in the inspected body. No wildcards, regular expressions, or stemming are applied.

- **Case-insensitive (default):** `"lawsuit"` matches `lawsuit`, `Lawsuit`, `LAWSUIT`, and any other case variant.
- **Case-sensitive:** `"API"` matches only `API`, not `api` or `Api`.

A single match from any keyword in the list is sufficient to trigger the configured action. All matched keyword names are recorded in the `detectors_fired` log field.

---

## Examples

### Block requests mentioning competitor names

```json
{
  "type": "keyword",
  "name": "competitor-block",
  "action": "block",
  "target": "request",
  "keywords": ["AcmeCorp", "RivalAI", "OtherVendor"],
  "case_sensitive": false
}
```

### Flag responses containing specific internal terms

Records a log entry whenever the model response contains an internal codename, without blocking or modifying the response.

```json
{
  "type": "keyword",
  "name": "internal-term-flag",
  "action": "flag",
  "target": "response",
  "keywords": ["Project Nightingale", "Operation Keystone"],
  "case_sensitive": true
}
```

### Block profanity or prohibited topics

```json
{
  "type": "keyword",
  "name": "prohibited-topics",
  "action": "block",
  "target": "both",
  "keywords": ["jailbreak", "ignore previous instructions", "DAN mode"],
  "case_sensitive": false
}
```

!!! note "For pattern-based detection, use a different guardrail"
    The keyword guardrail only supports exact string matching. For detecting structured sensitive data such as email addresses, credit card numbers, or PII categories, use the [Regex guardrail](regex.md) or [Presidio guardrail](presidio.md) instead.

---

## Pipeline Position

The keyword guardrail is **Tier 1** — it runs in-process with no external calls. Within the guardrail pipeline, all Tier 1 guardrails run before any Tier 2 guardrail. When multiple keyword guardrails are configured, they run in the order they appear in the `guardrails` array.

A `block` verdict from this guardrail stops the pipeline immediately. No subsequent guardrails run.

---

## See Also

- [Guardrail Pipeline Overview](../guardrails.md)
- [Regex Guardrail](regex.md)
- [Presidio Guardrail](presidio.md)
