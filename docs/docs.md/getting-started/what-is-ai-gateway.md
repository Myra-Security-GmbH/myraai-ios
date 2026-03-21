# What is AI Gateway by Myra Security?

AI Gateway is a multi-tenant reverse proxy built upon the Global Myra Security CDN. It sits between your applications and upstream AI provider APIs, enforcing policy, managing credentials, and recording every request — all in-process with no external sidecar required.

---

## Key features

- **21 provider integrations** — OpenAI, Anthropic, Google Gemini, Vertex AI, AWS Bedrock, Azure OpenAI, Mistral, Groq, Together AI, Fireworks, Cerebras, DeepSeek, OpenRouter, Perplexity, SambaNova, xAI, NVIDIA NIM, Cloudflare AI, Cohere, HuggingFace, Ollama
- **Unified OpenAI-compatible endpoint** — send any model name to `/compat/chat/completions`; the gateway resolves the provider automatically
- **Exact-match response caching** — repeated identical prompts are served from cache, saving cost and latency
- **Rate limiting** — per-gateway or per-token request caps, enforced before any upstream call is made
- **Budget enforcement** — hard spending caps at the gateway level and per auth token
- **Guardrail pipeline** — two-tier system: fast in-process regex/keyword (Tier 1) then optional HTTP sidecars — NLP PII Detector, Prompt Guard, and PII Protector (Tier 2)
- **BYOK key vault** — provider API keys encrypted at rest with AES-256
- **Routing rules** — ordered rule engine that can rewrite provider, model, and attach fallback chains based on request metadata
- **Prometheus metrics** — four counters/histograms with `provider`, `tenant_id`, `status`, `cached` labels; exposed at `/metrics`
- **Admin UI + Playground** — React SPA for managing tenants, gateways, users, routing rules, pricing, and running multi-model comparisons

---

## Use cases

**Centralized API key management**
Store all provider API keys in one encrypted vault. Applications never touch raw provider credentials — they authenticate to the gateway with a scoped token.

**Cost control and attribution**
Every request is logged with token counts, cost in USD, and a `meta` map of custom headers. Budget caps prevent runaway spend at both the gateway and per-user-token level.

**Compliance and security policy enforcement**
Apply PII scrubbing via the guardrail pipeline (NLP PII Detector, regex, keyword) and Prompt Guard content moderation centrally, before prompts ever reach a provider.

**A/B routing and model experimentation**
Write routing rules that redirect a percentage of traffic to a different provider or model, with automatic fallback if the primary fails. Compare results side-by-side in the Playground.

**Connect your own Ollama deployment**
Route requests to a self-hosted Ollama instance via `provider_base_urls`. Application code stays identical whether it targets Ollama or any cloud provider.

---

## Architecture overview

```
Consumer
   │  POST /v1/{tenant}/{gateway}/{provider}/chat/completions
   ▼
┌──────────────────────────────────────────┐
│           AI Gateway                     │
│  ┌────────────────────────────────────┐  │
│  │     Access processing phase        │  │
│  │  auth · rate-limit · IP allowlist  │  │
│  ├────────────────────────────────────┤  │
│  │     Content processing phase       │  │
│  │  cache · guardrails · routing ·    │  │
│  │  BYOK · upstream ·                 │  │
│  │  cost · cache-store                │  │
│  ├────────────────────────────────────┤  │
│  │     Log phase (best-effort)        │  │
│  │  structured log · Prometheus       │  │
│  └────────────────────────────────────┘  │
└──────────────────────────────────────────┘
          │                    │
   ┌──────┴──────┐      ┌──────┴──────┐
   │Configuration│      │  Upstream   │
   │   Store     │      │  Providers  │
   │Request Logs │      │ (21 total)  │
   └─────────────┘      └─────────────┘
```

All policy enforcement — authentication, rate limiting, caching, and security checks — runs in-process with no additional network round trips, ensuring consistent low-latency enforcement at scale.

| Capability | Description |
|---|---|
| Platform | Built upon the Global Myra Security CDN |
| Providers | 21 AI providers via a unified API |
| Security | Authentication, rate limiting, budget enforcement, and guardrail pipeline (regex, NLP PII Detector, Prompt Guard, PII Protector) — all enforced in-process |
| Encryption | Provider API keys encrypted at rest with AES-256 |
| Observability | Structured request logs, Prometheus metrics, real-time admin dashboard |
| Admin UI | React-based admin interface with playground for model testing |

---

## See also

- [Quick Start](quick-start.md) — make your first request in four steps
- [Getting Access](installation.md) — managed service and on-premise options
- [Request Pipeline](../concepts/request-pipeline.md) — detailed walkthrough of every middleware step
- [Supported Providers](../concepts/providers.md) — full provider table with supported models
