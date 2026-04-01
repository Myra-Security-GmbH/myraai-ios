# AI Gateway by Myra Security

**Document type:** Online Help

---

## Product description

AI Gateway by Myra Security is a multi-tenant AI proxy that provides a single, secure endpoint for enterprise access to 21 AI providers. Built upon the Global Myra Security CDN, the gateway sits between your applications and upstream AI provider APIs and enforces rate limits, budgets, guardrails, and audit logging across all AI requests. All policy enforcement runs in-process within Myra's certified EU infrastructure, ensuring consistent low-latency enforcement with no external sidecar required for core functions.

---

## Purpose of this document

This document is the Online Help for AI Gateway by Myra Security. It describes how to configure and use the product. The target audience is administrators, tenant administrators, and developers who integrate AI capabilities through the gateway.

---

## Features and limitations

### Features

- Support for 21 AI provider integrations, including OpenAI, Anthropic, Google Gemini, Vertex AI, AWS Bedrock, Azure OpenAI, Mistral, Groq, Together AI, Fireworks, Cerebras, DeepSeek, OpenRouter, Perplexity, SambaNova, xAI, NVIDIA NIM, Cloudflare AI, Cohere, HuggingFace, and Ollama
- Unified OpenAI-compatible endpoint that resolves the provider automatically based on the model name
- Exact-match response caching that serves repeated identical prompts from cache, saving cost and latency
- Sliding-window rate limiting at the gateway level and per authentication token, enforced before any upstream call
- Three-tier budget enforcement (per token, per tenant, per gateway) with automatic period resets (daily, monthly, or lifetime total)
- Two-tier guardrail pipeline: Tier 1 in-process checks (regex, keyword, jailbreak detection, JSON schema, code detection, gibberish, language) at sub-millisecond latency; Tier 2 sidecar-based NLP checks (NLP PII Detector, Prompt Guard, PII Protector) within Myra's certified EU infrastructure
- BYOK key vault with provider API keys encrypted at rest using AES-256
- Routing rules engine that rewrites provider and model, distributes traffic by weight, and chains fallback providers
- Automatic fallback chains that retry failed requests against secondary providers transparently
- Per-provider circuit breaker that stops routing to failing providers for a configurable cooldown period
- IP allowlist enforcement per gateway
- Structured audit logging for every request, including provider, model, tenant, token counts, cost, cache status, and all guardrail verdicts
- Request tracing with per-phase latency breakdown
- Prometheus metrics exposed at `/metrics`
- Web-based admin UI with dashboard, live monitor, cost analytics, request log, playground, and persistent multi-turn chat
- SIEM event streaming to Splunk HEC, Elasticsearch, OpenSearch, Vector HTTP source, and Syslog (CEF or RFC 5424)
- Multi-tenancy with isolated budgets, policies, authentication tokens, and analytics per tenant

### Limitations

- Streaming responses are not cached; the exact-match cache applies only to non-streaming requests
- Semantic caching is not available; caching uses exact-match comparison only and requires no embedding provider
- IPv6 addresses are not supported in the IP allowlist; only IPv4 CIDR ranges are accepted
- Tier 2 guardrail sidecars (NLP PII Detector, Prompt Guard, PII Protector) must be separately deployed; they are not included in the base gateway installation
- Cost tracking requires model pricing data in the gateway's internal model pricing table; requests for models without a known price are not tracked for spend
- Per-provider 4xx responses are not retried and do not trigger fallback chains

---

## Version history

| Version | Date | Reason for change |
|---|---|---|
| — | 01/04/2026 | Added drag-and-drop file upload, spreadsheet attachment, conversation export, processing status indicator, and code-block copy button to Chat |
| — | 01/04/2026 | Added persistent multi-turn chat with file attachments (images, PDFs, plain text, Word documents) |
| — | 01/04/2026 | Added stay-logged-in option (30 days) on Email OTP login |
| — | 01/04/2026 | Added pricing for Claude 4.5 and Claude 4.6 model families |
| — | 01/04/2026 | Added collapsible cards on gateway detail page |
| — | 01/04/2026 | Added SIEM event streaming (Splunk HEC, Elasticsearch, OpenSearch, Vector, Syslog) |
| — | 01/04/2026 | Restricted Management sidebar section to admin and tenant_admin roles |
| — | 01/04/2026 | Added tenant reassignment for admin users |
| — | 01/04/2026 | Added analytics tabs (By Tenant, By Gateway, By Provider, By Model, By User), overview chart, and latency percentile strip |
| — | 01/04/2026 | Added gateway request tracing with per-phase step breakdown and Traces API |
| — | 01/04/2026 | Added persistent spend ledger (SQLite), `total` budget period, and actionable QUOTA_EXCEEDED messages |
| — | 01/04/2026 | Added timeseries stats API with five bucket sizes and multi-day dashboard views |
| — | 01/04/2026 | Fixed Ollama model prefix stripping; added weighted load-balancing and per-provider circuit breaker |
| — | 01/04/2026 | Added web search in Playground with Gemini native grounding support |
| — | 01/04/2026 | Added human-readable guardrail block messages and Anthropic tool use conversion on compat endpoint |
