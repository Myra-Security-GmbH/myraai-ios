---
title: Why AI Gateway
description: The key advantages of AI Gateway by Myra Security for enterprise and public-sector organisations adopting AI at scale.
---

# Why AI Gateway by Myra Security

Large organisations adopting AI often accumulate a tangle of direct provider API integrations with no visibility, no cost control, and no consistent policy enforcement. AI Gateway by Myra Security addresses each of these problems through a single, centrally managed platform.

---

## EU data sovereignty with US AI providers

The most capable AI models — OpenAI, Anthropic, Google Gemini, AWS Bedrock — are operated by US companies, subject to US law, and hosted in US data centres. For European enterprises and government bodies, sending sensitive data directly to those providers raises questions under GDPR (General Data Protection Regulation) and sector-specific regulations: who accesses that data, under what legal framework, and with what oversight?

AI Gateway places the **certified EU infrastructure** of Myra Security between your organisation and every US AI provider. All requests and responses flow through the network of Myra — a highly certified, EU-jurisdiction environment that operates under European data protection law. US providers receive only what your policies explicitly permit.

The content inspection and PII (Personally Identifiable Information) detection engines that power guardrails — the [NLP PII Detector](../security/guardrails/presidio.md), [Prompt Guard](../security/guardrails/prompt-guard.md), and [PII Protector](../security/guardrails/pii-protector.md) — run as sidecars **within the certified infrastructure of Myra**. Sensitive content is inspected, scrubbed, or tokenised inside the EU trust boundary; the US provider never sees it.

Specific controls available to your organisation:

- PII, financial data, or regulated content in a prompt is detected and redacted or tokenised before the request leaves the EU. The US provider receives a sanitised or tokenised body; the original values are restored in the response on the way back.
- Setting `fail_open: false` on any guardrail ensures an inspection failure blocks the request rather than allowing uninspected data to reach a US provider.

> ⚠️ **Caution:** If `fail_open` is set to `true` and the sidecar service is unavailable, requests pass through without Tier 2 inspection. For compliance-sensitive workloads, set `fail_open: false` on all Tier 2 guardrails.
- Payload logging is disabled globally or per-request via a single header, ensuring request and response bodies are not persisted — even within the infrastructure of Myra Security — for the most sensitive workloads.
- The audit trail — what was sent, what was detected, what was blocked — is recorded within the EU environment and accessible to your compliance team.

---

## Layered content security at sub-millisecond latency

A single guardrail is not a security posture. AI Gateway enforces a **two-tier pipeline** that applies fast in-process checks before anything reaches a network-bound service.

**Tier 1 — In-process, sub-millisecond:**

- **Jailbreak detection** ships with 18 pre-configured attack phrases covering instruction-override attempts, persona jailbreaks, and fake system-message injection. It is operational with a single line of JSON — no phrase list to maintain.
- **Keyword guardrail** performs exact-string matching for topic filtering, brand protection, or blocking known-bad strings, with configurable case sensitivity and whole-word boundaries.
- **Regex guardrail** supports named pattern libraries (PCI card numbers, HIPAA-structured fields, GDPR-structured fields, credentials) as well as custom Lua patterns, all evaluated in-process.

**Tier 2 — Sidecar, milliseconds:**

- **NLP PII Detector** (Presidio) identifies 50+ entity types with confidence scoring. High false-positive entity types — names, locations, dates — automatically have their confidence threshold raised, so blocking and scrubbing decisions remain accurate.
- **Prompt Guard** (Llama Guard 3) performs semantic safety classification across 14 policy categories including violence, self-harm, CBRN, and child safety content, catching rephrased attacks that literal keyword matching cannot reach.
- **PII Protector** tokenises PII reversibly: the AI provider receives a token placeholder, and the original value is restored in the response before it reaches the client. The model processes no real PII yet responds coherently.

Each guardrail in the pipeline independently issues a `block` (terminate the request), `scrub` (redact and continue), or `flag` (log and continue) verdict. A `block` verdict stops the pipeline immediately — no subsequent guardrails run. The cheapest checks always run first; expensive ML calls are made only when necessary.

---

## Complete financial governance across every team and project

Ungoverned AI spend is one of the fastest-growing sources of unplanned cost in large organisations. AI Gateway enforces a **three-tier budget hierarchy** that gives finance and operations teams direct control.

| Level | Scope | Example |
|---|---|---|
| Per authentication token | Individual user or application | Limit a single contractor's app to $50/month |
| Per tenant | Business unit or department | Cap the Legal team's total spend at $2,000/month |
| Per gateway | Specific AI application | Restrict a customer-facing chatbot to $500/day |

Budgets enforce automatic period resets — daily (UTC midnight), monthly (calendar month), or lifetime total. When a limit is reached, callers receive an HTTP 429 with an error message that identifies which budget was exhausted and the API call required to resolve it.

Real-time spend is visible in the dashboard broken down by tenant, gateway, user, and model, alongside cache savings. Analytics include latency percentiles (p50, p95, p99) for end-to-end and upstream separately, so cost and performance are visible in one place.

---

## No lock-in across 21 AI providers

Organisations that commit to a single AI provider today are placing a long-term bet on the pricing, capability, and availability of that provider. AI Gateway abstracts the provider layer: **21 providers** — including OpenAI, Anthropic, Google Gemini, Azure OpenAI, AWS Bedrock, and on-premises models via Ollama — share a single OpenAI-compatible API surface. Switching providers or adding a second one requires no changes to client code.

Beyond multi-provider access, routing provides operational control:

- **Fallback chains** automatically retry a failed request against secondary providers, so a provider outage does not affect your users.
- **Load balancing** distributes traffic across multiple provider keys or endpoints by weight, enabling gradual migrations and cost arbitrage.
- **Circuit breaker** tracks upstream error rates and stops forwarding traffic to a degraded provider automatically, protecting downstream users from cascading failures.
- **Base URL overrides** redirect traffic for any provider to an internal proxy, a staging endpoint, or a private deployment — without changing client code.

---

## Audit-ready observability from day one

When a security incident involves an AI system, auditors ask: what did the model receive, and what did it respond with? AI Gateway captures a structured log record for every request, including:

- Provider, model, tenant, gateway, and authenticated user
- Request and response token counts and cost
- End-to-end and upstream latency
- Cache hit/miss status, retry count, and fallback flag
- Every guardrail verdict: which detectors fired, what action was taken, and the specific matched content

The full request trace — phase by phase, from request receipt through upstream call to response delivery — is available via the Traces API and visible in the **Live Monitor**. Latency is broken down at each phase so bottlenecks are immediately identifiable.

All data is accessible through the admin dashboard and a structured REST API, feeding naturally into existing SIEM, BI, or cost management tooling.

---

## Multi-tenancy with genuine isolation

AI Gateway is built around a **tenant → gateway** hierarchy designed for organisations where multiple teams, business units, or external customers share the same infrastructure without sharing visibility into each other's usage.

Each tenant has its own:

- Budget and spend tracking
- Gateway configurations and guardrail policies
- Authentication tokens and user attribution
- Analytics and log views

An administrator scoped to one tenant cannot see the data, spend, or requests of another tenant. This makes AI Gateway suitable for both internal shared services and organisations that deliver AI-enabled services to external clients from a single platform.

---

## Summary

| Concern | How AI Gateway addresses it |
|---|---|
| EU data sovereignty | Certified EU infrastructure sits between your organisation and US providers; PII scrubbed or tokenised before crossing the boundary |
| PII and sensitive data | Detection, tokenisation (reversible), and scrubbing — all in-flight |
| Jailbreaks and prompt injection | Zero-config Tier 1 detection + semantic Llama Guard 3 classification |
| Uncontrolled AI spend | Three-tier budget hierarchy with automatic resets and real-time attribution |
| Provider lock-in | 21 providers behind one API; fallback, load balancing, circuit breaker |
| Audit and compliance | Structured request log with full guardrail decisions and per-phase trace |
| Multi-team governance | Tenant isolation with independent budgets, policies, and visibility |

For deployment options, prerequisites, and initial configuration, continue to [Getting access](installation.md).
