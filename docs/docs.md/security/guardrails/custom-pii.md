---
title: Custom PII Blacklist
description: Configuration reference for the AI Gateway Custom PII Blacklist guardrail — reversible keyword masking for client names, codenames, and sensitive terms.
---

# Custom PII Blacklist

The Custom PII Blacklist is a **Tier 1** (in-process, sub-millisecond) guardrail that masks admin-defined sensitive terms before they reach the model and restores them in the response. It is suited for protecting client names, internal project codenames, employee surnames, and any other terms that must not appear in prompts sent to external AI providers.

![Screenshot: Custom PII Blacklist editor in the Guardrail Builder](../../assets/screenshots/guardrail-custom-pii-builder.png)
*Custom PII Blacklist editor*

## When to use the Custom PII Blacklist

Use the Custom PII Blacklist when you need to prevent specific, known strings from reaching the model — and when you need the model response to contain the original values again. Unlike the [Keyword guardrail](keyword.md), which blocks or flags traffic, the Custom PII Blacklist is transparent to both the caller and the model: the caller sends the original text, the model sees masked tokens, and the caller receives the original text in the response.

For NLP-based PII detection (email addresses, card numbers, names inferred from context), use the [NLP PII Detector](presidio.md) or [PII Protector](pii-protector.md) instead.

## How it works

The guardrail intercepts each request and response in two phases.

**Request phase:** Each keyword in the `keywords` list is replaced with an opaque token in the format `[MYRA-CUSTOM:SALT:N]`, where `SALT` is derived from the request identifier and `N` is a sequential counter. The request body with masked values is forwarded to the model.

**Response phase:** Every token in the model response is replaced with the original keyword value before the response is returned to the caller.

The token mapping persists for the lifetime of the request. The model never receives the original keyword values.

> 💡 **Note:** The masking is fully reversible within a single request. Stored logs contain the masked form (tokens, not original values) when `log_payloads: true` is configured.

> 💡 **Note:** For non-ASCII names (for example, names containing accented characters or non-Latin scripts), either enable the **Case sensitive** option and enter the exact capitalisation, or disable the **Case sensitive** option and enter a lowercase form — ASCII case-folding applies only to ASCII characters.

---

## Configuration reference

| Field | Type | Default | Description |
|---|---|---|---|
| `type` | string | — | Must be `"custom_pii"` |
| `name` | string | — | Human-readable label for this guardrail instance |
| `keywords` | array of strings | `[]` | Sensitive terms to mask. Each string must appear verbatim in the request. |
| `case_sensitive` | boolean | `false` | When `false`, matching is case-insensitive (ASCII only). When `true`, only the exact capitalisation matches. |
| `whole_word` | boolean | `false` | When `true`, a keyword only matches when surrounded by non-word characters. When `false`, substring matches also apply. |

> 💡 **Note:** The Custom PII Blacklist does not have an `action` field. Masking is always active and cannot be configured to block or flag.

---

## Example configuration

### Mask client names in a customer support gateway

```json
{
  "type": "custom_pii",
  "name": "client-name-mask",
  "keywords": ["Acme Corp", "Globex", "Initech"],
  "case_sensitive": false,
  "whole_word": true
}
```

### Mask internal codenames with exact case

```json
{
  "type": "custom_pii",
  "name": "project-codename-mask",
  "keywords": ["Project Nightingale", "Operation Keystone"],
  "case_sensitive": true,
  "whole_word": true
}
```

---

## Configuring the Custom PII Blacklist

Proceed as follows to configure the Custom PII Blacklist in the Guardrail Builder:

1. Open the gateway detail page and scroll down to the **Guardrails** card.
2. Click on the **+ Custom PII Blacklist** button.
   - A collapsed Custom PII Blacklist card appears at the bottom of the list.
3. Click on the card to expand it.
4. Enter a name in the **Name** text field.
5. Enter each sensitive term in the **Sensitive terms** text field and click on the **Add** button.
   - The term is added to the keyword list below the field.
6. If required, enable the **Case sensitive** toggle for exact-case matching.
7. If required, enable the **Whole-word matching** toggle to prevent substring matches.
8. Click on the **Save Guardrails** button.

→ The Custom PII Blacklist is saved and appears in the execution plan.

---

## Pipeline position

The Custom PII Blacklist is **Tier 1** — it runs in-process with no external calls. All Tier 1 guardrails run before any Tier 2 guardrail.

The masking and restoration phases operate independently of other guardrails in the pipeline. Other Tier 1 guardrails that run after the Custom PII Blacklist inspect the already-masked request body — the original keyword values are not visible to them.

---

## See also

- [Guardrail pipeline overview](../guardrails.md)
- [Keyword guardrail](keyword.md)
- [NLP PII detector](presidio.md)
- [PII Protector](pii-protector.md)
