# Glossary

Definitions for all key terms used across the AI Gateway documentation, listed alphabetically.

---

## Auth Token

An opaque bearer credential issued by the Admin API that authenticates inference requests. The gateway stores only the SHA-256 hash of the token; the plaintext is returned once at creation time and never stored again. Tokens are scoped to a single gateway. See [Authentication](../api-reference/authentication.md).

## Block

A guardrail or policy action that rejects a request entirely and returns an error response to the caller. Compare with **Scrub** (redact and continue) and **Flag** (log and continue). See [Guardrail Pipeline](../security/guardrails.md).

## Budget

A cumulative spend cap in USD applied at either the gateway level (`config.budget_usd`) or the per-token level (`auth_token.budget_usd`). Once the cap is reached all requests return `429 QUOTA_EXCEEDED`. Budgets are reset via the Admin API. See [Budget & Quota Enforcement](../configuration/budgets.md).

## BYOK

**Bring Your Own Key** — the practice of supplying your own provider API keys to the gateway rather than using any keys the gateway operator holds. Keys are stored encrypted at rest and decrypted in-process at request time. The encryption key is managed by the Myra Security platform. See also: **BYOK alias**.

## BYOK alias

A named label for a stored provider key, e.g. `default` or `team-a`. Multiple keys for the same provider can be stored under different aliases. The alias is selected per-request via the `x-aig-byok-alias` header. See [Gateway Configuration Reference](config-reference.md).

## Cache TTL

The time-to-live in seconds for cached inference responses. Set via `config.cache_ttl`. When `0`, caching is disabled. See also: **Exact-match cache**.

## Compat endpoint

The unified `POST /v1/{tenant}/{gateway}/compat/chat/completions` endpoint that accepts any model name and automatically resolves the correct provider using prefix matching and an OpenRouter fallback. Always returns an OpenAI-shaped response. See [Providers Overview](../providers/overview.md).

## cost_usd

The estimated cost of an inference request in US dollars, calculated from token counts multiplied by the model's per-token pricing in the gateway's pricing table. Stored as micro-dollars internally. Appears in log entries and in the stats API. See [Models & Pricing API](../api-reference/models.md).

## Guardrail

A configurable content inspection component in the gateway's two-tier pipeline. Tier 1 guardrails (regex, keyword) run in-process in sub-milliseconds. Tier 2 guardrails (presidio, prompt_guard, pii_protector) call external HTTP sidecars. Each guardrail has an action: `block`, `scrub`, or `flag`. See [Guardrail Pipeline](../security/guardrails.md).

## DLP

**Data Loss Prevention** — the practice of scanning request and response content for sensitive patterns (PII, credentials, etc.) before they leave or enter the system. In AI Gateway, DLP is implemented through the [guardrail pipeline](../security/guardrails.md) using regex and keyword guardrails, or the Presidio sidecar for NER-based PII detection.

## Exact-match cache

The gateway's response caching mechanism. Responses are keyed on a SHA-256 hash of the provider name, model name, and canonicalized request body (excluding `stream`, `user`, and `metadata` fields). A cache hit returns the stored response without calling the upstream provider, saving cost and latency. Controlled by `config.cache_ttl`.

## Fallback

An alternative provider and model that the gateway tries when the primary provider fails all retries. Fallbacks are defined in routing rule `actions.fallbacks` as an ordered array. Each fallback in the chain is attempted once. Only the primary provider uses `retry_count`. See [Routing Rules API](../api-reference/routing-rules.md).

## Flag

A detector action that records a match in the log entry (`detector_flags`) and continues the request without modifying the content. Compare with **Block** and **Scrub**.

## Gateway

The second-level entity in the tenant hierarchy. A gateway belongs to a tenant and holds a configuration object, a set of provider keys, routing rules, and auth tokens. Each gateway corresponds to a unique path prefix in inference endpoint URLs: `/v1/{tenant}/{gateway}/...`. See [Tenants & Gateways API](../api-reference/tenants-gateways.md).

## In-process shared memory

The gateway's in-process key/value store used for hot state: rate-limit counters, config and BYOK key caches, Prometheus metric counters. On a single-server deployment these are the primary state stores; on multi-node deployments they are swapped for Redis.

## Llama Guard

An open-weight safety classification model (Meta's Llama Guard 3) that inspects prompt and response content for harm across 14 categories. In AI Gateway it is used as the `prompt_guard` Tier-2 guardrail sidecar. See [Prompt Guard](../security/guardrails/prompt-guard.md).

## Micro-dollars

The internal unit for cost storage: `cost_usd × 1,000,000` stored as an integer. This avoids floating-point precision loss when accumulating small per-request costs in an atomic counter. The API always returns values in USD (as a float), not micro-dollars.

## Playground

The interactive model testing interface in the Admin UI. Supports multi-model comparisons, streaming responses, web search, and session persistence. Playground sessions use short-lived tokens issued by `POST /admin/v1/playground/token`. See [Admin API](../api-reference/authentication.md).

## Playground token

A short-lived token issued for the Playground UI. Expires after 10 minutes and is managed automatically by the admin UI. Cannot be used for production inference. See [Authentication](../api-reference/authentication.md).

## Presidio

[Microsoft Presidio](https://microsoft.github.io/presidio/) — an open-source NER-based PII detection service. Used as a Tier 2 guardrail sidecar in AI Gateway, operated as a managed sidecar by the Myra Security platform. More accurate than the in-process regex guardrails for unstructured text but adds network round-trip latency. See [Guardrail Pipeline](../security/guardrails.md).

## Provider

An upstream AI inference service (e.g. OpenAI, Anthropic, Google Gemini, AWS Bedrock). The gateway supports 21 providers. Each provider has a native endpoint path and a registered adapter that translates the OpenAI-compatible request format to the provider's native wire format. See [Providers Overview](../providers/overview.md).

## Quota

The exhaustion state when a budget cap is reached. Requests are blocked with `429 QUOTA_EXCEEDED` until the budget is reset. See **Budget**.

## Rate limit

A sliding-window request frequency cap, applied at the gateway level (`config.rate_limit`) or per token (`auth_token.rate_limit`). Implemented using a dual-bucket approximation in in-process shared memory. Exceeded limits return `429 RATE_LIMITED`. See [Rate Limiting](../configuration/rate-limiting.md).

## Retry

An automatic re-attempt of a failed upstream provider request on 5xx errors. The number of retries is configured via `config.retry_count` (default: 2). Each retry is a separate upstream call to the same provider. If all retries fail, the gateway walks the fallback chain.

## Routing rule

A priority-ordered conditional rule that rewrites the provider and model for matching requests. Rules are evaluated in ascending priority order; the first match wins. See [Routing Rules API](../api-reference/routing-rules.md).

## saved_cost_usd

For cache-hit requests: the cost that would have been incurred if the response had been fetched from the provider rather than served from cache. Reported in log entries and aggregated in stats as a "savings" metric. See [Stats API](../api-reference/stats.md).

## Scrub

A detector action that replaces matched content with a placeholder (e.g. `[REDACTED]`) and allows the (modified) request to continue. Compare with **Block** and **Flag**.

## SigV4

AWS Signature Version 4 — the HMAC-SHA256-based request signing scheme used by AWS services including Bedrock. The gateway signs Bedrock requests using credentials stored via BYOK. See [AWS Bedrock](../providers/bedrock.md).

## Slug

A URL-safe lowercase string identifier (e.g. `myapp`, `production`). Slugs are unique within their scope (tenant slugs are globally unique; gateway slugs are unique within a tenant). They appear directly in inference endpoint URLs: `/v1/{tenant_slug}/{gateway_slug}/...`.

## SSE

**Server-Sent Events** — the streaming transport used for `"stream": true` inference requests. The gateway proxies SSE chunks from the provider to the client as they arrive. On the compat endpoint, provider-native SSE formats are re-encoded into OpenAI `chat.completion.chunk` format.

## Streaming

The mode of operation when a request includes `"stream": true`. The provider sends tokens as they are generated; the gateway proxies each SSE chunk to the client without buffering the full response first. Usage data (token counts) is emitted in a final chunk just before `data: [DONE]`.

## Tenant

The top-level organizational unit. A tenant corresponds to one application or team. Each tenant has a unique slug that appears in all inference endpoint URLs. Tenants contain gateways, users, and tokens. See [Tenants & Gateways API](../api-reference/tenants-gateways.md).

## Tier 1 guardrail

An in-process guardrail (regex, keyword) that runs entirely inside the gateway process with no external calls. Execution time is in the sub-millisecond range. Tier 1 guardrails always run before Tier 2. See [Guardrail Pipeline](../security/guardrails.md).

## Tier 2 guardrail

An HTTP-sidecar-based guardrail (presidio, prompt_guard, pii_protector) that sends content to an external service for analysis. Execution time is in the millisecond range due to the network round trip. Tier 2 guardrails run only after all Tier 1 guardrails pass without blocking. See [Guardrail Pipeline](../security/guardrails.md).

---

## See also

- [What is AI Gateway?](../getting-started/what-is-ai-gateway.md)
- [Request Pipeline](../concepts/request-pipeline.md)
- [Gateway Configuration Reference](config-reference.md)
- [Changelog](changelog.md)
