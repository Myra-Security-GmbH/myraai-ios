# Language Guardrail

The language guardrail is a **Tier 1** (in-process, sub-millisecond) guardrail that identifies the dominant writing system of request or response text and blocks or flags traffic that does not use a permitted script. It is suited for deployments that serve a known-language audience and need to prevent misuse through non-Latin scripts or detect unexpected language usage.

---

## Configuration Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | string | — | Must be `"language"` |
| `name` | string | — | Human-readable label for this guardrail instance |
| `action` | string | `"block"` | What to do on a disallowed script: `block` or `flag` |
| `target` | string | `"request"` | Which traffic to inspect: `request`, `response`, or `both` |
| `allowed` | array | — | Language codes that are permitted. Traffic using any other detected script triggers the configured action |
| `min_ratio` | number | `0.1` | Minimum fraction of non-Latin characters needed for a non-Latin script to be declared dominant. Below this threshold, the text is classified as `latin` |

---

## Supported Scripts

Detection uses UTF-8 byte-range heuristics — no dictionary lookups or external models are required. Each code point is classified into one of the following writing systems:

| Language code | Writing system | Unicode range |
|---|---|---|
| `latin` | Latin, ASCII, and all unclassified text | Default (non-matching characters) |
| `cjk` | Chinese, Japanese, Korean | U+4E00–U+9FFF |
| `cyrillic` | Russian, Bulgarian, Serbian, Ukrainian, … | U+0400–U+04FF |
| `arabic` | Arabic, Farsi, Urdu | U+0600–U+06FF |
| `hebrew` | Hebrew | U+0590–U+05FF |
| `thai` | Thai | U+0E00–U+0E7F |
| `devanagari` | Hindi, Sanskrit, Marathi, Nepali, … | U+0900–U+097F |

The detected script is the writing system with the highest character count, provided that count exceeds `min_ratio` of the total text. When no non-Latin script meets the `min_ratio` threshold, the text is classified as `latin`.

---

## `min_ratio` Setting

`min_ratio` prevents false positives on text that mixes scripts — for example, an English sentence that mentions a product name in Cyrillic or includes a few CJK characters. With the default `min_ratio: 0.1`, at least 10 % of the text must be a given non-Latin script before it is declared dominant.

Lower `min_ratio` to be more sensitive to mixed-script content. Raise it to require a more heavily non-Latin document before triggering.

---

## Limitation: Sub-Latin Language Discrimination

The language guardrail detects **writing systems**, not languages. All Latin-script languages — English, French, German, Spanish, Portuguese, and others — map to the same `latin` code. It is not possible to permit English while blocking French using this guardrail.

For sub-Latin language discrimination (e.g. allow English only), use a sidecar language-detect service and apply the result via a custom guardrail or routing rule.

---

## Examples

### Allow only Latin-script requests

Block any request that is predominantly written in a non-Latin writing system:

```json
{
  "type": "language",
  "name": "latin-only",
  "action": "block",
  "target": "request",
  "allowed": ["latin"]
}
```

### Allow Latin and CJK (for a bilingual deployment)

```json
{
  "type": "language",
  "name": "latin-cjk",
  "action": "block",
  "target": "both",
  "allowed": ["latin", "cjk"]
}
```

### Flag non-Latin requests for review without blocking

```json
{
  "type": "language",
  "name": "non-latin-flag",
  "action": "flag",
  "target": "request",
  "allowed": ["latin"]
}
```

### Increase sensitivity to mixed-script content

With `min_ratio: 0.05`, even a small fraction of Cyrillic characters triggers detection:

```json
{
  "type": "language",
  "name": "strict-latin",
  "action": "block",
  "target": "request",
  "allowed": ["latin"],
  "min_ratio": 0.05
}
```

---

## Pipeline Position

The language guardrail is **Tier 1** — it runs in-process with no external calls. It can run in both the request and response phases depending on the configured `target`. A `block` verdict stops the pipeline immediately.

---

## See Also

- [Guardrail Pipeline Overview](../guardrails.md)
- [Gibberish Detector](gibberish.md) — detect low-quality model responses
- [Keyword Guardrail](keyword.md) — exact-string matching for specific terms
