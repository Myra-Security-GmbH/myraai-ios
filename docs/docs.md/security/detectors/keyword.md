# Keyword Detector

The keyword detector is a **Tier 1** (in-process, sub-millisecond) detector that scans request and response content for exact string matches. It is suited for topic filtering, brand protection, and blocking known-bad strings where pattern-based matching is not required.

---

## Configuration Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | string | — | Must be `"keyword"` |
| `name` | string | — | Human-readable label for this detector instance |
| `action` | string | `"flag"` | What to do on a match: `block` or `flag` |
| `target` | string | `"request"` | Which traffic to inspect: `request`, `response`, or `both` |
| `keywords` | array | `[]` | Exact strings to match |
| `case_sensitive` | boolean | `false` | When `true`, matching is case-exact; when `false`, matching is case-insensitive |

!!! warning "Scrub is not supported"
    The keyword detector does not support `action: "scrub"`. If `"scrub"` is configured, the detector treats it as `"flag"`. To redact matched content, use the [Regex detector](regex.md) or [Presidio detector](presidio.md) instead.

---

## Matching Behavior

The keyword detector performs plain string matching — each keyword in the `keywords` array must appear verbatim in the inspected body. No wildcards, regular expressions, or stemming are applied.

- **Case-insensitive (default):** `"lawsuit"` matches `lawsuit`, `Lawsuit`, `LAWSUIT`, and any other case variant.
- **Case-sensitive:** `"API"` matches only `API`, not `api` or `Api`.

---

## Examples

### Block requests mentioning competitor names

This configuration blocks any request that contains a competitor name, regardless of capitalisation.

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

This configuration records a log entry whenever the model response contains an internal codename, without blocking or modifying the response.

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

!!! note "For pattern-based detection, use a different detector"
    The keyword detector only supports exact string matching. For detecting structured sensitive data such as email addresses, credit card numbers, or PII categories, use the [Regex detector](regex.md) or [Presidio detector](presidio.md) instead.

---

## See Also

- [Detector Pipeline Overview](../detectors.md)
- [Regex Detector](regex.md)
- [Presidio Detector](presidio.md)