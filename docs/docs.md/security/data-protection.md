---
title: Data protection and compliance
description: Overview of AI Gateway data protection capabilities — PII detection and scrubbing, reversible tokenisation, jailbreak prevention, output policy enforcement, and the guardrail pipeline.
---

# Data protection and compliance

AI Gateway by Myra Security provides a layered content inspection pipeline — called the **guardrail pipeline** — that runs on every request sent to an AI provider and on every response returned from one. The pipeline can detect, block, scrub, or log sensitive content before it reaches the provider and before it reaches the user.

This chapter describes the available protection mechanisms and guides you to the right configuration for your use case.

---

## Why data protection matters for AI workloads

When users interact with an AI model through a chat interface or API, they frequently include sensitive information in their messages — personal details, financial data, internal reference numbers, or confidential business context. Without controls in place, this content is forwarded verbatim to the AI provider, stored in provider logs, and may be used in model training depending on the provider agreement.

AI Gateway intercepts every request at the gateway level, before it leaves the Myra perimeter, and applies the configured protection rules. No custom code is required in the client application.

---

## How the guardrail pipeline works

Every gateway has a configurable list of guardrails. When a request arrives, the gateway runs each guardrail in sequence and collects a verdict for each one.

### Verdict actions

| Verdict | Effect |
|---|---|
| **Block** | The request is denied. The user receives a structured error message. No provider call is made. |
| **Scrub** | Matched content is replaced with a placeholder before the request is forwarded. The provider never sees the original value. |
| **Flag** | The match is recorded in the request log. The request is not modified and is forwarded normally. |

A `block` verdict from any single guardrail stops the pipeline immediately. `scrub` and `flag` are non-terminal — the remaining guardrails continue to run.

### Two tiers of inspection

Guardrails run in two tiers.

| Tier | Types | Where it runs | Latency |
|---|---|---|---|
| **Tier 1** | Regex, Keyword, Jailbreak, JSON schema, Language, Gibberish, Contains code | In-process within the gateway | Sub-millisecond |
| **Tier 2** | NLP PII detector, PII Protector, Prompt Guard | Sidecar HTTP call within the Myra perimeter | Milliseconds |

All Tier 1 guardrails run before any Tier 2 guardrail. Within the same tier, guardrails run in the order defined in the gateway configuration.

### Request and response inspection

Each guardrail can target the **request** (outbound to provider), the **response** (inbound to user), or **both**.

---

## Choosing the right protection approach

The table below maps common compliance and security requirements to the recommended guardrails.

| Requirement | Recommended guardrail(s) |
|---|---|
| Prevent personal data (names, emails, phone numbers) from reaching the provider | [PII Protector](guardrails/pii-protector.md) or [NLP PII detector](guardrails/presidio.md) with `action: "scrub"` |
| Protect PII while preserving contextual continuity in the response | [PII Protector](guardrails/pii-protector.md) |
| Block credit card numbers, SSNs, IBANs, and other structured data | [Regex guardrail](guardrails/regex.md) with named patterns (`pci_pan`, `iban`, etc.) |
| Block specific terms, product codes, or confidential strings | [Keyword guardrail](guardrails/keyword.md) |
| Prevent prompt injection and jailbreak attacks | [Jailbreak detector](guardrails/jailbreak.md) and/or [Prompt Guard](guardrails/prompt-guard.md) |
| Enforce structured output format (e.g. JSON) | [JSON schema guardrail](guardrails/json-schema.md) |
| Restrict interactions to a specific language | [Language guardrail](guardrails/language.md) |
| Detect and filter incoherent or low-quality model responses | [Gibberish detector](guardrails/gibberish.md) |
| Prevent source code from appearing in requests or responses | [Contains-code detector](guardrails/contains-code.md) |
| Audit all requests that contain PII without modifying traffic | [NLP PII detector](guardrails/presidio.md) with `action: "flag"` |

---

## PII protection

AI Gateway provides two approaches to protecting personally identifiable information (PII).

### Reversible tokenisation — PII Protector

[PII Protector](guardrails/pii-protector.md) is the recommended approach for interactive use cases such as the **Chat** view. It detects PII in the user's message, replaces each value with an opaque token before forwarding the request to the provider, and restores the original values in the response. The AI model never sees real PII; the user receives a natural, contextually coherent response.

> ⭐ **Example:** A user types `"My email is alice@example.com"`. The provider receives `"My email is [MYRA-REDACT-EMAIL_ADDRESS:a3f1:1]"`. The model's response referencing the token is returned to the user with `alice@example.com` restored.

Use PII Protector when:

- The AI model needs to reference PII contextually in its response (for example: summarising a document that mentions people's names).
- The end user should receive the original values in the response.
- Non-streaming requests are used (PII Protector does not restore tokens in streamed responses).

### Permanent scrubbing — NLP PII detector

The [NLP PII detector (Presidio)](guardrails/presidio.md) detects PII and replaces it with static labels such as `<EMAIL_ADDRESS>`. The replacement is permanent — the original value is not restored in the response.

Use the NLP PII detector with `action: "scrub"` when:

- The response does not need to reference the original PII values.
- Compliance requires that PII never appear in the response, even in restored form.
- You need an audit log of all detected PII (use `action: "flag"`).

### Structured data — Regex guardrail

The [Regex guardrail](guardrails/regex.md) is the fastest and most precise tool for structured sensitive data formats — credit card numbers, SSNs, IBANs, routing numbers, passport numbers, and similar values with predictable patterns. It runs in-process (Tier 1) with sub-millisecond latency and supports a built-in library of named patterns with checksum validation.

Use the regex guardrail for structured PCI, PII, or domain-specific data patterns. Combine it with Tier 2 guardrails for comprehensive coverage: the regex guardrail blocks structured data first, then the NLP PII detector handles unstructured forms such as names and addresses.

---

## Prompt injection and jailbreak protection

### Jailbreak detector

The [Jailbreak detector](guardrails/jailbreak.md) is a zero-configuration Tier 1 guardrail pre-loaded with detection patterns for 18 categories of known prompt injection and jailbreak attacks. It requires no configuration beyond adding it to the gateway.

### Prompt Guard

[Prompt Guard](guardrails/prompt-guard.md) is a Tier 2 semantic safety classifier based on Meta's Llama Guard 3, running locally within the Myra perimeter. It classifies requests against a configurable set of harm categories and is more robust against novel or paraphrased attack patterns than the keyword-based Jailbreak detector.

For maximum coverage, use both guardrails: the Jailbreak detector (Tier 1) blocks known patterns instantly, and Prompt Guard (Tier 2) catches semantic variants.

---

## Output policy enforcement

The following guardrails inspect model responses rather than — or in addition to — user requests.

| Guardrail | What it enforces |
|---|---|
| [JSON schema](guardrails/json-schema.md) | The model response must match a declared JSON schema. Non-conforming responses are blocked. |
| [Language restriction](guardrails/language.md) | Requests or responses must use a specific writing system (Latin, Cyrillic, Arabic, etc.). |
| [Gibberish detection](guardrails/gibberish.md) | Low-quality or incoherent model responses are blocked or flagged before reaching the user. |
| [Contains-code detection](guardrails/contains-code.md) | Source code in requests or responses is detected and the configured action applied. |

---

## Building a guardrail pipeline

A production data protection configuration typically combines multiple guardrails. A recommended starting point for a general-purpose gateway handling user data:

```json
[
  {
    "type": "jailbreak",
    "name": "block-jailbreaks",
    "action": "block",
    "target": "request"
  },
  {
    "type": "regex",
    "name": "block-structured-pii",
    "action": "block",
    "target": "request",
    "patterns": ["pci_pan", "iban", "us_ssn", "aba_routing"]
  },
  {
    "type": "pii_protector",
    "name": "tokenize-pii",
    "entities": ["PERSON", "EMAIL_ADDRESS", "PHONE_NUMBER", "LOCATION"],
    "fail_open": false
  }
]
```

This pipeline:

1. Blocks known jailbreak attempts instantly (Tier 1, no latency).
2. Blocks structured financial and identity data before it leaves the network (Tier 1, no latency).
3. Tokenises remaining personal data contextually and restores original values in the response (Tier 2, milliseconds).

For the full reference on how guardrails are configured, ordered, and managed, see [Guardrail pipeline](guardrails.md).

---

## Viewing guardrail events

Every guardrail verdict is recorded in the request log. To view guardrail activity, navigate to **Request logs** in the sidebar and filter by **Blocked** status or search for a specific guardrail name.

The following fields are available in each log entry:

| Field | Description |
|---|---|
| `blocked` | Whether the request was blocked by any guardrail |
| `blocked_by` | The name of the guardrail that issued the block |
| `block_reason` | The pattern or category that triggered the verdict |
| `detectors_fired` | All guardrails that produced a non-pass verdict |

The **Dashboard** also shows recent guardrail events in the **Recent guardrail events** card. The **Cost analytics** view breaks down blocked requests by gateway and time period.

---

## See also

- [Guardrail pipeline](guardrails.md) — full technical reference, verdict actions, and pipeline management
- [PII Protector](guardrails/pii-protector.md) — reversible PII tokenisation
- [NLP PII detector](guardrails/presidio.md) — permanent scrubbing via NER
- [Regex guardrail](guardrails/regex.md) — structured data pattern matching
- [Keyword guardrail](guardrails/keyword.md) — exact string matching
- [Jailbreak detector](guardrails/jailbreak.md) — zero-config prompt injection protection
- [Prompt Guard](guardrails/prompt-guard.md) — semantic safety classification
- [Request logs](../observability/logging.md) — viewing guardrail events
