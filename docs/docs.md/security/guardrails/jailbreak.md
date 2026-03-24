# Jailbreak Guardrail

The Jailbreak guardrail is a **Tier 1** (in-process, sub-millisecond) guardrail pre-loaded with 18 known attack phrases covering instruction-override attempts, persona jailbreaks, bypass/override commands, and fake system-message injection. It works with zero configuration — operators add a single JSON object and detection begins immediately.

![Jailbreak guardrail editor](../../assets/screenshots/guardrail-jailbreak.png)

---

## Configuration Fields

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | string | — | Must be `"jailbreak"` |
| `name` | string | — | Human-readable label for this guardrail instance |
| `action` | string | `"flag"` | What to do on a match: `block` or `flag` |
| `target` | string | `"request"` | Which traffic to inspect: `request`, `response`, or `both` |
| `keywords` | array | `[]` | When non-empty, **replaces** the 18 built-in phrases entirely with this custom list |
| `case_sensitive` | boolean | `false` | Match case-sensitively |
| `whole_word` | boolean | `false` | Match only at word boundaries |

---

## Minimal Configuration

```json
{
  "type": "jailbreak",
  "name": "jailbreak-check",
  "action": "flag"
}
```

That is the complete configuration needed. The Guardrail Builder's **+ Jailbreak** button creates this config and displays the active phrase list in the editor.

---

## Built-In Phrase List

The following 18 phrases are active when `keywords` is empty or omitted:

| # | Phrase |
|---|---|
| 1 | `ignore previous instructions` |
| 2 | `ignore all instructions` |
| 3 | `ignore your instructions` |
| 4 | `disregard previous instructions` |
| 5 | `disregard your instructions` |
| 6 | `forget your instructions` |
| 7 | `DAN mode` |
| 8 | `do anything now` |
| 9 | `jailbreak` |
| 10 | `developer mode` |
| 11 | `unrestricted mode` |
| 12 | `your true self` |
| 13 | `bypass your guidelines` |
| 14 | `bypass your restrictions` |
| 15 | `override your guidelines` |
| 16 | `override your restrictions` |
| 17 | `prompt injection` |
| 18 | `[SYSTEM]` |

---

## Customising the Phrase List

When `keywords` is set to a non-empty array it **replaces** the 18 built-ins entirely — the original list is not merged in:

```json
{
  "type": "jailbreak",
  "name": "custom-jailbreak",
  "action": "block",
  "keywords": ["my custom phrase", "another attack pattern"]
}
```

Leave `keywords` empty or omit it to use the defaults.

---

## Layered Defence

| Layer | Guardrail | What it catches | Latency |
|---|---|---|---|
| 1 | `jailbreak` | Literal jailbreak phrases (18 built-in, customisable) | Sub-millisecond |
| 2 | `prompt_guard` | Semantically unsafe requests across 14 policy categories | ~10–50 ms |

The `jailbreak` guardrail catches literal, unmodified phrases only. Creative rephrasing, character insertion, encoding, or indirect prompt injection embedded in retrieved documents will not be caught. Layer a [`prompt_guard`](prompt-guard.md) guardrail for semantic coverage — Llama Guard 3 runs locally within Myra's certified infrastructure, so no prompt data leaves the Myra perimeter.

---

## See Also

- [Guardrail Pipeline Overview](../guardrails.md)
- [Keyword Guardrail](keyword.md) — exact-string matching for custom word lists
- [Prompt Guard](prompt-guard.md) — semantic safety classification via Llama Guard 3
