---
title: Gibberish detector
description: Configuration reference for the AI Gateway gibberish detector — entropy and vocabulary heuristics, signal thresholds, and example configurations.
---

# Gibberish detector

The gibberish detector is a **Tier 1** (in-process, sub-millisecond) guardrail that identifies low-quality, incoherent, or machine-garbled text in model responses. It is suited for ensuring response quality on customer-facing deployments and for catching model failure modes such as token repetition loops, encoding artefacts, or near-empty responses.

## When to use the gibberish detector

Use the gibberish detector when you need to block or log degraded model output — responses dominated by repeated tokens, symbol floods, binary encoding artefacts, or near-empty text. It inspects model responses only.

## How it works

Three independent heuristic signals are computed against the response text. Each signal that exceeds its threshold counts as one signal hit.

| Signal | Detects | Threshold |
|---|---|---|
| **Shannon entropy** | Character repetition — e.g. `aaaaaaa…` or repeated tokens | `entropy < entropy_threshold` (default 2.5) |
| **Word repetition ratio** | Vocabulary collapse — few unique words relative to total word count | `unique_words / total_words < word_repeat_ratio` (default 0.15) |
| **Alpha character ratio** | Non-text content — encoding artefacts, symbol flooding, binary data | `alpha_chars / total_chars < alpha_ratio` (default 0.6) |

**Verdict rule:**

| Signal hits | Result |
|---|---|
| 1 | Always flagged — recorded in `detectors_fired`, pipeline continues |
| 2 or more | Configured `action` applied — `block` or `flag` |

A single signal hit never blocks on its own, regardless of the configured action. Blocking requires at least two signals. This prevents false positives from short, terse, or numeric responses.

!!! note "Short response handling"
    Responses shorter than 20 characters are always passed without inspection. Very short responses (e.g. `"Yes."`) produce unreliable heuristic scores.

!!! note "CJK text exemption"
    The alpha-ratio check is skipped for responses where the dominant writing system is CJK (Chinese, Japanese, Korean). CJK text uses a character space that is legitimately low in Latin alpha characters.

---

## Configuration reference

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | string | — | Must be `"gibberish"` |
| `name` | string | — | Human-readable label for this guardrail instance |
| `action` | string | `"block"` | What to do when 2 or more signals fire: `block` or `flag` |
| `target` | string | `"response"` | Must be `"response"` — the detector inspects model output only |
| `entropy_threshold` | number | `2.5` | Shannon entropy threshold. Responses with character entropy below this value are flagged as repetitive |
| `word_repeat_ratio` | number | `0.15` | Minimum unique-word ratio. Responses where fewer than this fraction of words are unique are flagged |
| `alpha_ratio` | number | `0.6` | Minimum alphabetic character ratio. Responses that are mostly non-alphabetic are flagged |

!!! note "Response-only guardrail"
    The gibberish detector inspects model responses and cannot be targeted at `request` or `both`. The request phase always passes without inspection.

---

## Threshold tuning

| Signal | Default | Loosen (fewer blocks) | Tighten (more blocks) |
|---|---|---|---|
| `entropy_threshold` | `2.5` | Lower (e.g. `2.0`) | Raise (e.g. `3.0`) |
| `word_repeat_ratio` | `0.15` | Lower (e.g. `0.05`) | Raise (e.g. `0.25`) |
| `alpha_ratio` | `0.6` | Lower (e.g. `0.4`) | Raise (e.g. `0.75`) |

---

## Example configurations

### Block gibberish responses (default configuration)

```json
{
  "type": "gibberish",
  "name": "quality-check",
  "action": "block",
  "target": "response"
}
```

Blocks responses that score badly on at least two of the three signals.

### Flag only — monitoring mode

Records suspected gibberish in the log without disrupting the client:

```json
{
  "type": "gibberish",
  "name": "quality-monitor",
  "action": "flag",
  "target": "response"
}
```

### Strict quality enforcement

Tighter thresholds to catch more marginal responses — useful for structured-output pipelines where responses should contain well-formed prose or data:

```json
{
  "type": "gibberish",
  "name": "strict-quality",
  "action": "block",
  "target": "response",
  "entropy_threshold": 3.0,
  "word_repeat_ratio": 0.25,
  "alpha_ratio": 0.7
}
```

---

## Configuring the gibberish detector

![Screenshot: Gibberish detector card in the Guardrail Builder](../../assets/screenshots/guardrail-gibberish-builder.png)
*Gibberish detector card — expanded view*

Proceed as follows to configure the gibberish detector in the Guardrail Builder:

1. Open the gateway detail page and scroll down to the **Guardrails** card.
2. Click on the **+ Gibberish** button.
    - A collapsed gibberish detector card appears at the bottom of the list.
3. Click on the card to expand it.
4. Enter a name in the **Name** text field.
5. Select the action from the **Action** drop-down list: `block` or `flag`.
6. Verify that the **Target** drop-down list is set to `response`.
7. If required, adjust the **Entropy Threshold**, **Word Repeat Ratio**, and **Alpha Ratio** fields.
8. Click on the **Save Guardrails** button.
    - -> The gibberish detector is saved and appears in the execution plan.

---

## Pipeline position

The gibberish detector is **Tier 1** — it runs in-process with no external calls. It executes in the response phase only. A `block` verdict prevents the malformed response from reaching the client.

---

## See also

- [Guardrail pipeline overview](../guardrails.md)
- [JSON Schema guardrail](json-schema.md) — validate structured output shape
- [Language guardrail](language.md) — detect non-permitted writing systems
