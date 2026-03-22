> **AI Gateway by Myra Security** — a multi-tenant reverse proxy that sits between your applications and every major AI provider. One URL structure, one key vault, one place for policy.

---

## New here?

| Step | What to do |
|------|-----------|
| 1 | Read [What is AI Gateway?](getting-started/what-is-ai-gateway.md) for a two-minute orientation |
| 2 | Follow the [Quick Start](getting-started/quick-start.md) to make your first proxied inference request |
| 3 | Work through [Installation](getting-started/installation.md) for a permanent, production-ready setup |
| 4 | Explore [Core Concepts](concepts/request-pipeline.md) to understand the middleware chain |

---

## Table of Contents

### Getting Started

- [What is AI Gateway?](getting-started/what-is-ai-gateway.md) — overview, key features, use cases, architecture diagram
- [Quick Start](getting-started/quick-start.md) — from zero to first inference request in five steps
- [Installation](getting-started/installation.md) — system requirements, configuration, start/stop

### Core Concepts

- [Request Pipeline](concepts/request-pipeline.md) — full phase-by-phase walkthrough of every middleware step
- [Multi-Tenancy](concepts/multi-tenancy.md) — tenant/gateway hierarchy, isolation mechanisms, user roles
- [Supported Providers](concepts/providers.md) — all 21 providers, wire formats, compat model resolution
- [Response Caching](concepts/caching.md) — exact-match cache mechanics, TTL, savings tracking
- [Cost Attribution](concepts/cost-attribution.md) — cost formula, pricing sources, bulk import scripts

### Configuration

- [Gateway Config Reference](configuration/gateway-config.md)
- [Rate Limiting](configuration/rate-limiting.md)
- [Budgets & Quotas](configuration/budgets.md)

### Security

- [Authentication](security/authentication.md)
- [Guardrail Pipeline](security/guardrails.md)
- [BYOK Key Vault](security/byok.md)
- [IP Allowlist](security/ip-allowlist.md)

### Routing

- [Routing Rules](routing/routing-rules.md)
- [Compat Endpoint](routing/compat-endpoint.md)
- [Fallback Chain](routing/fallback.md)

### Providers

- [Provider Overview](providers/overview.md)
- [OpenAI](providers/openai.md)
- [Anthropic](providers/anthropic.md)
- [Google Gemini](providers/gemini.md)
- [Azure OpenAI](providers/azure.md)
- [AWS Bedrock](providers/bedrock.md)
- [Ollama](providers/ollama.md)
- [OpenAI-Compatible Providers](providers/openai-compatible.md)

### Observability

- [Logging](observability/logging.md)
- [Dashboard](observability/dashboard.md)

### Observability

- [Playground](observability/playground.md)

### API Reference

- [Authentication](api-reference/authentication.md)
- [Tenants & Gateways](api-reference/tenants-gateways.md)
- [Users & Tokens](api-reference/users-tokens.md)
- [Routing Rules](api-reference/routing-rules.md)
- [Stats](api-reference/stats.md)
- [Logs](api-reference/logs.md)
- [Models & Pricing](api-reference/models.md)
- [Error Codes](api-reference/error-codes.md)

### Reference

- [Config Reference](reference/config-reference.md)
- [Changelog](reference/changelog.md)
- [Glossary](reference/glossary.md)
