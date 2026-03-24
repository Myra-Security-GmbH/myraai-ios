# Market & Competitive Analysis

_Last updated: 2026-03-22_

## Competitor Overview

| Company | Positioning | Pricing model |
|---|---|---|
| **Portkey** | Developer-first gateway with guardrails & prompt mgmt | Hosted SaaS + self-host |
| **LiteLLM** | OpenAI-compat proxy, strong spend controls | Open-source + hosted proxy |
| **Helicone** | Observability-first — traces, evals, prompt versions | Hosted SaaS |
| **Langfuse** | Full LLMOps platform — traces, evals, datasets | Open-source + hosted SaaS |
| **Kong AI Gateway** | Enterprise API gateway with AI plugins | Enterprise licence |
| **OpenRouter** | Model marketplace / unified API | Per-token markup |

---

## Feature Comparison

| Feature | **Us** | Portkey | LiteLLM | Helicone | Langfuse | Kong AI |
|---|---|---|---|---|---|---|
| **Providers** | ✅ 21+ | ✅ 250+ | ✅ 100+ | ✅ pass-through | ✅ pass-through | ✅ plugins |
| **Load balancing / failover** | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ |
| **Circuit breaker** | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ |
| **Exponential backoff + retry** | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ |
| **Semantic cache** | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **Multi-tenancy / API keys** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Per-tenant spend limits** | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| **Budget alerts / webhooks** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Rate limits per tenant** | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ |
| **Guardrails (content)** | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ |
| **PII scrubbing** | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| **Prompt management** | ❌ | ✅ | ❌ | ✅ | ✅ | ❌ |
| **Prompt versioning / A/B** | ❌ | ✅ | ❌ | ✅ | ✅ | ❌ |
| **Request tracing / sessions** | ❌ | ✅ | ✅ | ✅ | ✅ | ❌ |
| **Evals framework** | ❌ | ❌ | ❌ | ✅ | ✅ | ❌ |
| **Model aliases** | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| **Streaming normalisation** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **BYOK** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Web search augmentation** | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Playground UI** | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| **Cost analytics dashboard** | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| **SSO / SAML** | ❌ | ✅ paid | ✅ paid | ✅ paid | ✅ paid | ✅ |
| **Self-hostable** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |

---

## Our Unique Strengths

- **Circuit breaker** — no major competitor implements this; prevents cascade failures at the infrastructure level.
- **Web search augmentation** — automatic tool injection for search-enabled models; no competitor bundles this.
- **PII scrubbing in-flight** — Presidio-based redaction before the request leaves the network perimeter.
- **LuaJIT on OpenResty** — sub-millisecond gateway overhead vs. Python/Node proxies that add 5–20 ms.
- **Built on Global Myra Security CDN** — DDoS protection and edge presence out of the box.

---

## Critical Gaps

### Tier 1 — High impact, moderate effort

1. ✅ **Per-tenant rate limits** _(implemented 2026-03-22)_
   Requests/min and tokens/day enforced per API key. Every enterprise prospect asks for this.
   LiteLLM and Portkey both have it.
   _Implementation_: sliding-window counter (`rl:token:{token_id}`) in shared dict; enforced in `rate_limit.lua` alongside gateway-level limit.

2. ✅ **Per-tenant spend limits + alerts** _(implemented 2026-03-22)_
   Hard block or soft alert when a tenant exceeds a monthly USD budget.
   LiteLLM's flagship feature; required for cost-accountable multi-tenancy.
   _Implementation_: `budget_usd` on tenant record; three-scope enforcement (token → tenant → gateway) in `quota.lua`; reset via `DELETE /admin/v1/tenants/:id/budget`.

3. **Model aliases**
   Friendly names like `fast` → `gpt-4o-mini`, `smart` → `claude-opus-4-6`.
   Zero client changes when swapping underlying models.
   _Implementation_: alias lookup table in gateway config; two-line change in `transform.lua`.

4. ✅ **Webhooks / event callbacks** _(implemented 2026-03-22)_
   POST to a configured URL on: blocked request, budget exceeded, circuit open, error threshold.
   Required for Slack/PagerDuty/SIEM integration. All four main competitors have it.
   _Implementation_: `utils/webhook.lua` fire-and-forget via `ngx.timer.at`; optional HMAC-SHA256 signing; events: `blocked`, `budget_exceeded`, `circuit_open`; configured per gateway in `webhooks.url/secret/events`.

### Tier 2 — High impact, higher effort

5. **Request tracing / sessions**
   Group multi-turn requests under a `session_id` (from `x-aig-session-id` header).
   Surface as trace view in the Logs UI. Helicone and Langfuse differentiate on this.

6. **Prompt management**
   Store, version, and render prompt templates server-side.
   Client sends `prompt_id + variables` instead of raw messages.
   Portkey and Langfuse both lead here — biggest differentiator for teams iterating on prompts.

7. **Prompt A/B testing**
   Route a traffic percentage to prompt variant A vs B; compare cost, latency, and quality.
   Follows naturally from prompt management.

### Tier 3 — Competitive parity, lower urgency

8. **Eval framework** — Run prompt templates against test datasets; track pass/fail metrics. Requires Tier 2 first.

9. **SSO / OIDC** — OIDC login for the admin UI. Gating feature for enterprise deals.

10. **Broader provider coverage** — Bedrock (AWS), Vertex AI native, Azure OpenAI native (currently via compat path).

---

## Recommended Build Order

| Sprint | Items | Est. |
|---|---|---|
| **Sprint 1** | Model aliases · ~~Per-tenant rate limits~~ ✅ | ~2 days remaining |
| **Sprint 2** | ~~Per-tenant spend limits + alerts~~ ✅ · ~~Webhooks~~ ✅ | done |
| **Sprint 3** | Session/trace ID storage · Logs trace view | ~5 days |
| **Sprint 4** | Prompt management CRUD · Playground prompt picker | ~7 days |
| **Sprint 5** | Prompt versioning + A/B routing | ~4 days |
| **Sprint 6** | Eval harness · SSO/OIDC | ~10 days |
