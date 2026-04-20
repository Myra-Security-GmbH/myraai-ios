# AI Gateway vs Claude.ai — Feature Comparison by Persona

**Scope:** Side-by-side comparison of Anthropic's Claude Team/Enterprise chat product
(claude.ai) and our AI Gateway, organised by the three personas that matter in a
procurement cycle: **CISO**, **ADMIN**, and **END-USER**.

**Sources**
- Claude.ai: `claude.com/pricing`, `claude.com/pricing/enterprise` — fetched April 2026
- AI Gateway: this repository (`src/`, `frontend/src/`, `config/`, `docs/`),
  plus the feature-by-feature gap analysis at [`CLAUDE-AI.md`](./CLAUDE-AI.md)

**Legend**
- ✅ shipped · ⚠ partial · ❌ absent · 🏆 persona winner

**Headline** — we win on CISO and ADMIN; claude.ai wins on END-USER polish.

---

## 1 · CISO — security, compliance, data governance

A CISO's test: *can I defend this procurement to the board, the DPO, and my
incident-response team?*

| Capability | Claude.ai Enterprise | AI Gateway | Winner |
|---|---|---|---|
| **Deployment model** | SaaS only (claude.com) | Self-hosted Docker on private infra; air-gapped possible | 🏆 **us** |
| **Data residency** | "Custom options" (sales-assisted, region-dependent) | You own the box — residency is wherever you run it | 🏆 **us** |
| **"No training on your data"** | Default on Enterprise; contractual | Structural — your data never leaves your network | 🏆 **us** |
| **BYOK to model providers** | ❌ Anthropic-hosted models only | ✅ per-gateway, per-provider, AES-256-CBC at rest (`src/auth/byok.lua`) | 🏆 **us** |
| **Customer-managed encryption keys** | ✅ (sales-assisted) | ✅ `AIG_MASTER_KEY` env var; rotation supported | tie |
| **SSO / domain capture** | ✅ SAML via SSO | ⚠ Google OAuth + email OTP only — **no SAML / OIDC federation** | 🏆 **claude.ai** |
| **SCIM auto-provisioning** | ✅ | ❌ | 🏆 **claude.ai** |
| **Audit log (admin actions)** | ✅ Enterprise tier | ✅ `audit_log` table — actor IP, user, method, path, status | tie |
| **Inference request log (prompts/responses)** | Limited; via Compliance API | ✅ every request: tenant, gateway, model, tokens, cost, latency, cache, detector events, trace_id (`src/observability/logger.lua`) | 🏆 **us** |
| **Real-time SIEM integration** | ❌ (Compliance API = pull-based) | ✅ Splunk HEC, Elasticsearch, Vector, Syslog-CEF (`src/observability/siem.lua`) | 🏆 **us** |
| **OpenTelemetry tracing** | ❌ | ✅ OTLP/HTTP (`src/observability/tracer.lua`) | 🏆 **us** |
| **PII detection & scrubbing at inference time** | ❌ Anthropic sees raw content | ✅ Presidio-backed PII tokenization **before** the request leaves your network; token map restored in response (`src/guardrails/pii_protector.lua`) | 🏆 **us** |
| **Prompt-injection / jailbreak guardrail** | ❌ in product (safety happens inside Claude) | ✅ pluggable Tier-1/Tier-2 pipeline: regex, keyword, jailbreak, prompt_guard, JSON-schema, language, gibberish | 🏆 **us** |
| **IP allowlist (CIDR)** | ✅ Enterprise tier | ✅ `src/middleware/ip_allowlist.lua` | tie |
| **Network-level access control** | ✅ | ✅ — and you can put it behind any corporate WAF | tie |
| **SOC 2 Type II attestation** | ✅ | ❌ | 🏆 **claude.ai** |
| **HIPAA-ready offering** | ✅ | ⚠ self-hosted = you BAA with the model provider directly | 🏆 **claude.ai** (document) / us (mechanism) |
| **GDPR alignment** | Contractual | Structural — data never leaves EU if deployed in EU | 🏆 **us** |
| **EU AI Act posture** | Unclear | Structural data-minimisation + pre-flight PII scrubbing is provable | 🏆 **us** |
| **Right-to-delete automation** | ✅ | ⚠ manual via admin API (no cascade automation) | 🏆 **claude.ai** |
| **Ghost/ephemeral mode** | ❌ | ✅ 👻 toggle — no DB writes, no request log, no attachment storage | 🏆 **us** |

**CISO verdict.** Our story is *"data never leaves your perimeter, you see every
token that moved, you can scrub PII before it ships."* Theirs is *"we're SOC 2
Type II, we're the authoritative shop for Claude."* The two gaps that cost us
deals are **SAML/SCIM** and **a published compliance attestation pack**.
Everything else, we match or better — and the PII-at-inference pipeline and SIEM
feed are things claude.ai cannot offer at all because they are the model vendor.

---

## 2 · ADMIN — platform team, IT ops, FinOps

An admin's test: *can I give 500 users Claude without the bill exploding,
without drowning in tickets, and without flying blind?*

| Capability | Claude.ai Enterprise | AI Gateway | Winner |
|---|---|---|---|
| **Multi-provider routing** (OpenAI, Anthropic, Gemini, Bedrock, vLLM, Ollama…) | ❌ Claude-only | ✅ 22 providers, per-gateway BYOK, fallback chains, circuit breaker | 🏆 **us** |
| **OpenAI wire-format compatibility** | N/A | ✅ `/v1/chat/completions` passthrough → any of 22 providers | 🏆 **us** |
| **Per-seat pricing control** | ✅ $20/seat/mo, 20-seat floor, 50+ for sales | ✅ per-user, per-gateway, per-tenant budgets with hard-stop enforcement | tie |
| **Per-request cost visibility** | Monthly rollups | ✅ per-message USD cost inline; timeseries by minute/hour/day | 🏆 **us** |
| **Rate limits** | Per-seat (opaque) | ✅ sliding-window: per-token, per-user, per-gateway, per-IP | 🏆 **us** |
| **Exact-match cache** | ❌ | ✅ SHA-256 body hash | 🏆 **us** |
| **Semantic cache** | ❌ | ✅ embedding-based, configurable threshold | 🏆 **us** |
| **Circuit breaker on provider errors** | ❌ | ✅ CLOSED/OPEN/HALF-OPEN per provider | 🏆 **us** |
| **Provider fallback chain** | ❌ | ✅ routing rules with automatic failover | 🏆 **us** |
| **Self-serve seat management** | ✅ | ⚠ admin UI can manage users, but no CSV bulk import; no SCIM | 🏆 **claude.ai** |
| **SCIM lifecycle** | ✅ | ❌ | 🏆 **claude.ai** |
| **User roles** | Roles + granular permissions | Admin / editor / viewer, per-tenant scoped | ≈ tie |
| **Admin console — dashboard** | ✅ usage analytics | ✅ spend trends, top models, live monitor, trace viewer, analytics | tie |
| **Alerting / webhooks** | ❌ | ✅ webhook delivery with event filters, exponential-backoff retry | 🏆 **us** |
| **Prometheus metrics** | ❌ | ✅ `/metrics` endpoint | 🏆 **us** |
| **Guardrail builder UI** | ❌ | ✅ `modules/guardrails/GuardrailBuilder.tsx` | 🏆 **us** |
| **Playground / API test UI** | ⚠ chat only | ✅ request/response inspector with token + model picker | 🏆 **us** |
| **Docs site bundled** | Help-center only | ✅ MkDocs-generated, served from the same container | 🏆 **us** |
| **Bulk user import / CSV** | ✅ (via SCIM) | ❌ | 🏆 **claude.ai** |
| **Connector governance** | ✅ org-level enable/disable | ⚠ MCP connector UI exists; external-SaaS connectors don't | 🏆 **claude.ai** |
| **Organisation-wide skill/prompt distribution** | ✅ "organization-wide skills" | ✅ tenant-wide slash commands (not per-user) | tie |
| **Model pricing table management** | Anthropic owns | ✅ editable `model_price` table; per-model input/output/cache rates | 🏆 **us** |

**Admin verdict.** For any org that runs more than one model family — which now
includes most of them — we are structurally ahead. Cost ceilings, rate limits,
fallbacks, caching and observability are the kind of gears an IT org expects
and claude.ai does not provide because it doesn't need to: it sells one model.
Our two real admin gaps are **SCIM** (which is mostly an SSO-flow extension of
the CISO gap) and **first-class SaaS connectors** — if Admin has to manually
give users a GitHub PAT, that's worse UX than claude.ai's in-product
connectors.

---

## 3 · END-USER — the actual chat experience

An end-user's test: *does this feel as good as claude.ai on my everyday work?*

| Capability | Claude.ai | AI Gateway | Winner |
|---|---|---|---|
| **Streaming SSE, markdown, syntax highlighting** | ✅ | ✅ | tie |
| **Extended thinking display** | ✅ toggle | ✅ collapsible `<think>` blocks, toggle shipped | tie |
| **Projects** (instructions + knowledge base) | ✅ | ✅ shipped (`modules/projects/`) — instructions, knowledge upload, members | tie |
| **Artifacts** (code/HTML/markdown panel) | ✅ multiple + versioning + inline edit | ⚠ single artifact panel, no versioning, no inline edit | 🏆 **claude.ai** |
| **React component artifact rendering** | ✅ | ❌ | 🏆 **claude.ai** |
| **Memory system** (cross-conversation recall) | ✅ | ❌ per-conversation only, no cross-chat memory | 🏆 **claude.ai** |
| **Slash commands / prompt templates** | ✅ personal + org | ✅ tenant-wide with `{{placeholder}}` variable modal | ≈ tie |
| **MCP connectors** | ✅ | ✅ UI shipped (`modules/mcp/`) | tie |
| **Native integrations — Google Drive / GitHub / Jira / Confluence / Slack** | ✅ | ❌ | 🏆 **claude.ai** |
| **Web search** | ✅ multi-turn research with citations | ✅ Brave API, two-leg agentic loop, markdown results | tie |
| **URL fetch / read** | ✅ | ✅ | tie |
| **Model switching mid-conversation** | ✅ with per-message model badge | ⚠ switchable but no per-message badge | 🏆 **claude.ai** |
| **Conversation share link (read-only)** | ✅ | ✅ `admin/share.lua` + `chat_share` table | tie |
| **Cowork / real-time co-editing** | ✅ | ❌ | 🏆 **claude.ai** |
| **Message branching** | ✅ | ❌ | 🏆 **claude.ai** |
| **Per-message 👍/👎 feedback** | ✅ with optional comment | ⚠ conversation-level feedback only | 🏆 **claude.ai** |
| **Reason-annotated regenerate** ("too long", "too formal") | ✅ | ❌ | 🏆 **claude.ai** |
| **File uploads** — PDF/DOCX/XLSX/PPTX/images | ✅ | ✅ all of them, plus Anthropic Skills API extraction | tie |
| **Image input** | ✅ | ✅ | tie |
| **Audio input** | ✅ | ❌ | 🏆 **claude.ai** |
| **Chat history — search / star / archive** | ✅ starred, archived, semantic search | ✅ star + archive + full-text; **no semantic search** | ≈ claude.ai |
| **Mobile app (iOS/Android)** | ✅ | ❌ responsive web only | 🏆 **claude.ai** |
| **Keyboard shortcuts** | ✅ `Cmd+K` etc. | ⚠ partial | 🏆 **claude.ai** |
| **Ghost / ephemeral chat** | ❌ | ✅ 👻 toggle suppresses DB writes and logs | 🏆 **us** |
| **Per-message cost + token count inline** | ❌ | ✅ | 🏆 **us** (our power-user delight) |
| **Choose any model mid-stream** (Claude, GPT, Gemini, local…) | ❌ | ✅ | 🏆 **us** |

**End-user verdict.** Feature-by-feature we are behind on the polish tier —
memory, artifacts v2, native SaaS connectors, mobile. Our existing gap
analysis at [`CLAUDE-AI.md`](./CLAUDE-AI.md) estimates **~45–50 engineering
days** to close the most impactful end-user gaps and **~110–130 days** for
full parity. The two things we do that claude.ai cannot is **"any model in
one UI with cost on the tin"** and **ghost mode** — both genuinely useful,
but niche.

---

## Net positioning

- **Where we already win — lead with these in every deal.**
  BYOK + multi-provider + per-message cost + SIEM/OTel/Prometheus + pre-flight
  PII scrubbing + self-hosted. These are structural advantages claude.ai
  cannot replicate without becoming a different product.

- **Where parity is within reach (weeks, not quarters).**
  Memory system (~10 d), semantic conversation search (~5 d), artifact
  versioning + inline edit (~5 d), per-message feedback (~2 d),
  model-badge-per-message (~1 d), mobile-responsive polish (~4 d). This is the
  existing backlog and it closes the most visible end-user gaps.

- **Where we concede today but should staff.**
  SAML/OIDC federation and SCIM — without these we lose procurement at
  ≥500-seat orgs on the first security questionnaire. A publishable SOC 2
  Type II roadmap closes the compliance-attestation gap. First-party
  Drive/GitHub/Jira connectors are the one feature claude.ai ships that
  genuinely changes daily end-user workflow, and MCP alone does not
  substitute.

- **Where we cheerfully don't compete.**
  Consumer tier, the Claude-brand model sell, and the `$20/seat` marketing
  motion. We are a platform, not a destination.
