# PII Protector

PII Protector is a **Tier 2** (sidecar HTTP call, milliseconds) guardrail that provides reversible PII tokenization. It detects PII in the request body using Presidio, replaces each detected value with an opaque token, forwards the tokenized request to the AI provider, and then restores the original values in the response before it reaches the client. The AI model never processes real PII.

---

## How It Works

1. **Request phase** — Presidio scans the request body for PII spans. Each unique value is replaced with a token in the format `[PII:SALT:N]`, where `SALT` is a random per-request prefix and `N` is a sequential counter. The same original value always maps to the same token within a single request.
2. **Provider call** — The upstream AI provider receives only the tokenized body. Real PII values are never transmitted.
3. **Response phase** — All tokens present in the response are replaced with their original values before the response is sent to the client.

**Example:** a prompt containing `"My SSN is 123-45-6789"` is forwarded to the provider as `"My SSN is [PII:a3f1c2:1]"`. If the model echoes the token back, the client receives the response with `123-45-6789` restored.

---

## Configuration Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | string | — | Must be `"pii_protector"` |
| `name` | string | — | Human-readable label for this guardrail instance |
| `language` | string | `"en"` | Language used for entity recognition |
| `entities` | array \| null | `null` | Entity types to tokenize; `null` tokenizes all supported entity types |
| `score_threshold` | number | `0.7` | Minimum confidence score for a detection to count (0.0–1.0) |
| `timeout_ms` | integer | `3000` | Timeout for the sidecar call in milliseconds |
| `fail_open` | boolean | `true` | If `true`, sidecar errors allow the request to pass through without tokenization; if `false`, they block it |

!!! note "No `action` or `target` fields"
    PII Protector does not have an `action` or `target` field. It always tokenizes on the request phase and restores on the response phase. Both phases are always active. Configure `target: "both"` is implicit and not required.

---

## Examples

### Protect specific entity types

```json
{
  "type": "pii_protector",
  "name": "protect-pii",
  "entities": ["PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER", "US_SSN"],
  "score_threshold": 0.75
}
```

### Protect all entity types, blocking on sidecar failure

```json
{
  "type": "pii_protector",
  "name": "protect-all-pii",
  "fail_open": false
}
```

### Combine with regex pre-filtering

Use a regex guardrail (Tier 1) to block structured PCI data before PII Protector tokenizes remaining PII. The regex block prevents card numbers from ever reaching the provider; PII Protector handles names, emails, and other values that benefit from restoration.

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
    "type": "pii_protector",
    "name": "tokenize-pii",
    "entities": ["PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER", "US_SSN", "LOCATION"]
  }
]
```

---

## Token Format

Tokens use the format `[PII:SALT:N]`:

| Component | Description |
|---|---|
| `SALT` | 6-character random hex prefix, unique per request |
| `N` | Sequential integer starting at 1, incremented for each distinct PII value found |

The same original value appearing multiple times in a single request always maps to the same token. On the response side, all occurrences of a given token are restored to the same original value.

---

## Deduplication and Overlapping Spans

**Deduplication:** if the same PII value appears multiple times in the request, all occurrences are replaced with the same token and all are restored identically in the response.

**Overlapping spans:** when Presidio detects overlapping entity spans (for example, a phone number that also matches an IP address pattern), the span with the highest confidence score wins. The lower-confidence span is discarded.

---

## `fail_open` Behavior

| `fail_open` | Sidecar unavailable |
|---|---|
| `true` (default) | Request passes through without tokenization |
| `false` | Request is blocked |

---

## Limitations

!!! warning "Streaming responses"
    PII Protector does not restore tokens in streaming responses. When a request is streamed, the response body is not buffered by the gateway, so token restoration is skipped. The client will see raw tokens such as `[PII:a3f1c2:1]` in the streamed output instead of the original values.

    Privacy is fully preserved — the AI model never received the real PII — but the user experience is degraded for streaming. Use non-streaming requests (`"stream": false`) when complete token restoration is required.

!!! note "Model paraphrasing"
    If the model paraphrases rather than echoing a token verbatim, restoration is skipped for that value. Privacy is maintained (the model never saw the real PII), but the response will not contain the original value in that position.

---

## Comparison with Presidio `scrub`

| | PII Protector | Presidio (`action: "scrub"`) |
|---|---|---|
| Request PII handling | Tokenized (reversible) | Replaced with `<TYPE>` placeholder (permanent) |
| Response restoration | Yes (non-streaming only) | No |
| Model sees real PII | Never | Never |
| Client sees real PII | Yes (non-streaming) | No |
| Same-value deduplication | Yes (same token per value) | N/A (same label either way) |
| HTTP calls per request | 1 (analyze only) | 2 (analyze + anonymize) |
| Typical use case | Model needs contextual continuity; client needs original values | Audit or compliance logging; no restoration needed |

---

## Pipeline Position

PII Protector is **Tier 2** — it makes an HTTP call to the Presidio sidecar. All Tier 1 guardrails (regex, keyword) run before any Tier 2 guardrail. This means any regex or keyword scrubbing runs first; PII Protector tokenizes whatever remains.

---

## See Also

- [Guardrail Pipeline Overview](../guardrails.md)
- [Presidio Guardrail](presidio.md) — permanent scrubbing without restoration
- [Regex Guardrail](regex.md) — in-process pattern matching for structured data
