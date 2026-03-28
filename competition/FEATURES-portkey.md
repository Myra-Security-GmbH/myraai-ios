# Portkey AI Gateway — Feature Analysis

> Source: https://portkey.ai/docs — analyzed March 2026.
> Portkey is a managed AI gateway (also open-source self-hosted) with 250+ models across 50+ providers.

---

## Table of Contents

1. [AI Gateway](#1-ai-gateway)
2. [Observability](#2-observability)
3. [Guardrails](#3-guardrails)
4. [Prompt Library](#4-prompt-library)
5. [Agent Support](#5-agent-support)
6. [Enterprise Features](#6-enterprise-features)
7. [Integration Methods](#7-integration-methods)
8. [Plan Tiers](#8-plan-tiers)
9. [Comparison to Our AI Gateway](#9-comparison-to-our-ai-gateway)

---

## 1. AI Gateway

### 1.1 Universal API

- **Single endpoint** — `https://api.portkey.ai/v1` covering 250+ models across 50+ providers
- **OpenAI-compatible interface** — Existing OpenAI SDK code works with a 2-line change (swap base URL + add headers)
- **Model slug format** — Reference any model as `@provider-slug/model-name` (e.g., `@openai-prod/gpt-4o`)
- **Provider coverage** — OpenAI, Anthropic, Azure, AWS Bedrock, Google Gemini, Google Vertex AI, Mistral, Cohere, Groq, DeepSeek, Perplexity, AI21, Stability AI, Ollama, LocalAI, Together AI, Fireworks AI, Anyscale, Jina AI, Voyage AI, Recraft AI, Snowflake Cortex, Lambda, Lepton, Nebius, Openrouter, Predibase, SiliconFlow, ZhipuAI, Moonshot, Dashscope, DeepInfra, GitHub Models, and 20+ more

### 1.2 Caching

- **Exact-match cache** — SHA hash of prompt; returns cached response without calling LLM
- **Semantic cache** — Vector-similarity matching for near-identical prompts with configurable similarity threshold
- **Cache states** — `disabled`, `miss`, `refreshed`, `hit`, `semantic hit` — visible in logs
- **Force refresh** — Bypass cache and force a fresh LLM call, then repopulate
- **Configurable TTL** — Per-config time-to-live; unlimited TTL on Enterprise
- **Cache analytics** — Dedicated tab showing cost savings and latency savings metrics

### 1.3 Fallbacks

- **Automatic provider/model failover** — Switches to backup LLM on any non-2xx
- **Selective trigger codes** — `on_status_codes` (e.g., `[429, 503]`)
- **Multi-tier chains** — 3+ backup targets in sequence
- **Cross-provider and cross-model** — Mix providers and models in the fallback chain
- **Composable** — Fallback targets can themselves be load balancers or conditional routers
- **Available on all plans**

### 1.4 Load Balancing

- **Weight-based traffic splitting** — Normalized weights (e.g., 5:3:1); weight 0 disables a target without removing it
- **Across providers, models, or API keys** — Full flexibility
- **Cost optimization** — Route majority traffic to budget models, minority to premium
- **Canary / gradual rollout** — E.g., 5% to a new model for safe migration
- **Sticky sessions** — `hash_fields` (dot-notation field, e.g., `metadata.user_id`) + `ttl` for consistent routing per user or conversation; backed by in-memory + Redis two-tier cache
- **Composable** — Combine with routing and fallback strategies
- **Available on all plans**

### 1.5 Conditional Routing

- **Metadata-based conditions** — Route on arbitrary key-value pairs attached to requests
- **Request parameter conditions** — Route on `model`, `temperature`, `max_tokens`, etc.
- **URL path matching** — Pattern match against request pathnames
- **Operators** — `$eq`, `$ne`, `$in`, `$nin`, `$regex`, `$gt`, `$gte`, `$lt`, `$lte`
- **Logical operators** — `$and`, `$or`
- **Default target** — Fallback when no condition matches
- **Per-target guardrails** — Attach input/output guardrails to individual routing targets
- **Composable** — Each target can itself contain a load balancer, fallback chain, or nested router
- **Use cases** — Premium vs. free user routing, regional compliance, model aliasing (`"fastest"`, `"smartest"`), A/B testing, feature-flag deployment

### 1.6 Automatic Retries

- **Up to 5 attempts** with exponential backoff (1s → 2s → 4s → 8s → 16s)
- **Configurable trigger codes** — `on_status_codes`; defaults: `[429, 500, 502, 503, 504]`
- **Provider header compliance** — `use_retry_after_headers: true` respects `retry-after` / `retry-after-ms` headers
- **Response header** — `x-portkey-retry-attempt-count`
- **Max cumulative wait** — 60 s; retry-after values exceeding 60 s fail immediately
- **Available on all plans**

### 1.7 Circuit Breaker

- **Automatic target removal** — Stops routing to unhealthy targets until recovery
- **Configurable thresholds** — `failure_threshold` (count) and/or `failure_threshold_percentage` (rate)
- **Minimum request window** — `minimum_requests` before threshold evaluation begins
- **Cooldown interval** — `cooldown_interval` in ms (minimum 30 s); auto-closes after cooldown
- **Configurable failure codes** — `failure_status_codes` (default: codes > 500)
- **Bypass behavior** — Routes to all targets if all become unhealthy
- **Configuration inheritance** — Settings cascade from parent strategy to child targets
- **Available on all plans**

### 1.8 Request Timeouts

- **Millisecond precision** with client-level, request-level, strategy-level, and target-level granularity
- **HTTP 408** on timeout; integrates with fallback (`on_status_codes: [408]`) and retry
- **Streaming exemption** — Streaming requests won't timeout if at least one chunk already received
- **Available on all plans**

### 1.9 Virtual Keys / Model Catalog

- **Secure credential storage** — Provider API keys encrypted, never exposed in code
- **Model Catalog** — Centralized credential management with `@provider-slug/model-name` format
- **Organization-level sharing** — Credentials shared across workspaces
- **Budget controls** — Monthly or custom-period spending limits per key
- **Rate limits** — Per-key rate limit enforcement
- **Model allow-lists** — Restrict which models a team or key can access

### 1.10 Configs System

- **JSON config objects** — Define fallback, load balancing, retries, caching, routing in one object
- **Config ID reference** — Apply via `config` SDK parameter or `x-portkey-config` header
- **Per-request override** — Supersedes client defaults
- **API key default configs** — Attach config to an API key for automatic application
- **Available on all plans**

### 1.11 Multimodal

- Vision, Image Generation, Function Calling, Speech-to-Text, Text-to-Speech
- Inline image display in log viewer for vision and image-gen requests

### 1.12 gRPC Support

- gRPC → HTTP proxy mode for all supported providers
- Native gRPC for Gemini only
- TLS support
- **Enterprise self-hosted only**

---

## 2. Observability

### 2.1 Logs

- **Full request/response logging** — Prompt, response, model, tokens, thinking tokens, cost, latency
- **Inline multimodal display** — Images shown in log viewer
- **Shareable log URLs** — Per-log URL for team collaboration
- **Gateway status columns** — Cache status, retry count, fallback status, load balancer status
- **Manual feedback annotation** — Annotate logs to build evals datasets
- **Log Replay** — One-click re-execution in prompt playground
- **DO NOT TRACK mode** — `x-portkey-debug: false` disables body logging while preserving metrics

| Plan | Monthly Logs | Retention |
|---|---|---|
| Developer | 10,000 | 3 days |
| Production | 100,000 (+$9/100k) | 30 days |
| Enterprise | Unlimited | Unlimited |

### 2.2 Analytics (21+ metrics)

- Cost by model, provider, user, metadata key
- Latency (mean, p50, p95, p99)
- Token usage (input / output / total)
- Request volume over time
- User activity via `user` field or `_user` metadata
- Feedback scores and trends
- Cache hit rates
- Error tracking with rescued-request counts
- Top models dashboard
- Group-by on any custom metadata property

| Plan | Retention |
|---|---|
| Developer | 30 days |
| Production | 365 days |
| Enterprise | Unlimited |

### 2.3 Tracing

- **OpenTelemetry-compliant** — W3C Trace Context (`traceparent` + `baggage`)
- **Span hierarchy** — `traceId`, `spanId`, `spanName`, `parentSpanId`
- **Agentic workflow support** — Multi-step LLM ops, tool calls, chain steps in a single trace
- **Cost aggregation** — Total LLM spend for an entire agent run
- **Framework integrations** — LangChain callback handler, LlamaIndex callback handler
- **Insert Log API** — Direct log submission for arbitrary trace depth
- **Gateway-generated spans** — Auto-spans for retry and fallback mechanics

### 2.4 Filters & Saved Filters

- 15 filter parameters: Model, Cost, Tokens, Status, Metadata, Feedback, Provider, Config ID, Trace ID, Time Range, API Key, Prompt ID, Cache Status, Workspace
- **Saved Filters** — Save and share filter sets org-wide

### 2.5 Custom Metadata

- Arbitrary string key-value pairs (max 128 chars per key)
- Reserved fields: `_user`, `_organisation`, `_prompt`, `_environment`
- Multi-level metadata: workspace → API key → request (request wins)
- **Enterprise:** enforce required metadata keys org-wide

### 2.6 Feedback API

- Weighted feedback scores (integer −10 to 10) with weight float 0–1
- `POST /v1/feedback` — link score to trace ID
- Auto-extracted trace ID from `x-portkey-trace-id` response header

---

## 3. Guardrails

### 3.1 Architecture

- **Input guardrails** (`before_request_hooks`) — Validate/block before LLM
- **Output guardrails** (`after_request_hooks`) — Validate/transform after LLM
- **Parallel execution** by default (`async: true`); sequential available
- **Actions** — `deny: true` (446 block) or `deny: false` (246 log-only)
- **Fallback on guardrail failure** — Route to alternative model if check fails
- **Evals dataset** — Automatic dataset creation via success/failure feedback tagging

### 3.2 Basic Guardrails (All Plans)

Regex Match, Sentence/Word/Character Count, Case checks, Ends With, JSON Schema, JSON Keys, Valid URLs, Contains Code (SQL/Python/TypeScript), Not Null, Contains phrase, JWT Token Validator, Request Parameters, Model Whitelist, Model Rules, Allowed Request Types, Required Metadata Keys, Webhook (custom), Log (external)

### 3.3 Pro Guardrails (Production + Enterprise)

- **Content Moderation** — Moderation by category
- **Language Detection** — Validate response language
- **PII Detection** — Identify PII by category (input and output)
- **Gibberish Detection** — Flag incoherent output

### 3.4 Partner Guardrails (Enterprise)

22 third-party integrations: Acuvity, Aporia, AWS Bedrock, Azure, Javelin, Lasso Security, Mistral, Pangea, Palo Alto Networks Prisma AIRS, Patronus, Pillar, Prompt Security, Qualifire, CrowdStrike AIDR, Exa, F5, Walled AI, Zscaler

---

## 4. Prompt Library

### 4.1 Prompt Playground

- **Multi-model testing** — 1,600+ models from 20+ providers simultaneously
- **Side-by-side comparison** — Parallel responses with latency, tokens, throughput
- **Thinking Mode** — Reasoning model support (e.g., Claude 3.7 Sonnet) with configurable token budget
- **Function calling UI** — Tool definitions within playground
- **Multimodal input** — Image upload or JSON mode

### 4.2 Prompt Templates

- **Mustache templating** — Variable injection via `{{variable}}`, conditional, iterative, partial blocks
- **Runtime variable injection** — `variables` parameter in SDK
- **Unique Prompt ID** — Reference templates directly from code via `prompts.completions.create()`
- **Versioning** — Automatic version on every save; revert to any prior version
- **Update & Publish workflow** — Staged publishing to production

| Plan | Templates |
|---|---|
| Developer | 3 |
| Production | Unlimited |
| Enterprise | Unlimited |

### 4.3 Prompt Partials

- **Reusable components** — Shared instruction sets, schemas, examples
- **Global variable store** — Common variables used across templates
- **Version pinning** — `{{>partial-id@version}}` for specific version
- **Auto-update propagation** — Published partials auto-update all referencing templates

### 4.4 Prompt Management

- Folder-based organization, RBAC per prompt, team collaboration, production monitoring, usage logs

---

## 5. Agent Support

### 5.1 Framework Integrations (16 frameworks)

OpenAI Agents (Python + TypeScript), AWS AgentCore, Pydantic AI, Autogen, CrewAI, Agno AI, Mastra Agents, LlamaIndex, LangChain, LangGraph, Langroid, OpenAI Swarm, Control Flow, Strands Agents, and custom

### 5.2 Agent-Specific Observability

- **Full trace logging** — Model calls, tool executions, reasoning steps in one trace tree
- **Agentic cost tracking** — Aggregate cost across an entire agent run
- **Multi-step lifecycle view** — Prompt → tool call → LLM call → response in tree view
- **Minimal integration** — 2-line change; no framework modification required

---

## 6. Enterprise Features

### 6.1 Security & Compliance

- SOC 2 certified, ISO 27001 certified, GDPR compliant, HIPAA compliant (custom BAA)
- AES-256 encryption at rest, TLS 1.2+ in transit
- KMS / Bring Your Own Key (customer-managed encryption keys)
- 99.995% uptime SLA
- 310 global data centers (edge deployment)
- DDoS protection, advanced firewall, regular third-party pen testing

### 6.2 Access & Identity

- **SSO via OIDC** — Custom provider (Okta, Microsoft, etc.)
- **RBAC** — Owner, Admin, Member roles with granular per-feature API key permissions
- **Audit logging** — Filter by user, action, resource, timestamp

### 6.3 Organizational Hierarchy

- **Account → Organizations → Workspaces** — Three-tier hierarchy
- Data isolation per organization (logs, analytics, prompts, configs, keys)
- Workspace-level API keys and metadata

### 6.4 Data Management

- Custom retention periods, isolated storage, export to data lakes, private cloud hosting

---

## 7. Integration Methods

| Method | Details |
|---|---|
| Portkey Python SDK | `portkey_ai` package |
| Portkey Node.js SDK | npm `portkey-ai` package |
| OpenAI SDK | 2-line swap: base URL + header |
| LangChain | `ChatOpenAI` with Portkey base URL |
| LlamaIndex | Callback handler |
| REST API | `https://api.portkey.ai/v1/` |
| Self-hosted OSS | `npx @portkey-ai/gateway` |
| Private cloud | Enterprise deployment |

**Key headers:** `x-portkey-api-key`, `x-portkey-config`, `x-portkey-metadata`, `x-portkey-trace-id`, `x-portkey-debug`, `x-portkey-request-timeout`

---

## 8. Plan Tiers

| Feature | Developer | Production | Enterprise |
|---|---|---|---|
| Monthly logs | 10,000 | 100,000 (+$9/100k) | Unlimited |
| Log retention | 3 days | 30 days | Unlimited |
| Analytics retention | 30 days | 365 days | Unlimited |
| Prompt templates | 3 | Unlimited | Unlimited |
| Guardrails (Basic) | Yes | Yes | Yes |
| Guardrails (Pro — PII, gibberish, language, moderation) | No | Yes | Yes |
| Guardrails (Partner — 22 integrations) | No | No | Yes |
| gRPC | No | No | Yes (self-hosted) |
| SSO (OIDC) | No | No | Yes |
| RBAC / Workspaces | No | No | Yes |
| KMS / BYOK encryption | No | No | Yes |
| Data lake export / private cloud | No | No | Yes |
| Caching, fallbacks, retries, load balancing, routing, circuit breaker, timeouts | All | All | All |
| Multimodal, configs, virtual keys, metadata, feedback, tracing | All | All | All |

---

## 9. Comparison to Our AI Gateway

### Feature Matrix

| Feature | Our Gateway | Portkey |
|---|---|---|
| **Providers** | 6 (OpenAI, Anthropic, Gemini, Azure, Mistral, Groq) | 250+ models, 50+ providers |
| **Exact-match caching** | Yes (SHA-256, shared dict / Redis) | Yes |
| **Semantic caching** | Planned (not implemented) | Yes (vector similarity, configurable threshold) |
| **Fallbacks** | Yes (rule-based, retry + fallback chain) | Yes (composable, status-code selective) |
| **Load balancing** | No | Yes (weighted, sticky sessions, canary) |
| **Conditional routing** | Yes (Lua rules engine, priority-ordered) | Yes (JSON DSL, composable, per-target guardrails) |
| **Automatic retries** | Yes (configurable retry_count) | Yes (up to 5, exponential backoff, retry-after header compliance) |
| **Circuit breaker** | No | Yes (threshold + cooldown, auto-recovery) |
| **Request timeouts** | Yes (gateway-level, ms precision) | Yes (client / request / strategy / target granularity) |
| **Rate limiting** | Yes (sliding window per gateway / token) | Yes (per API key, hourly/daily/per-minute) |
| **Budget enforcement** | Yes (per gateway + per token) | Yes (per key, monthly or custom period) |
| **BYOK / virtual keys** | Yes (AES-256-CBC, per gateway) | Yes (AES-256, org-level sharing, model allow-lists) |
| **DLP / PII** | Yes (block/scrub/flag, Lua patterns) | Pro plan: PII detection by category |
| **Content moderation** | Yes (Llama Guard 3, S1–S14) | Basic: regex; Pro: moderation categories; Enterprise: 22 partner integrations |
| **Guardrails — input** | Yes (Llama Guard + DLP) | Yes (20+ checks, LLM-based, partner integrations) |
| **Guardrails — output** | Yes (pattern-based only) | Yes (JSON schema, code detection, PII, language, moderation) |
| **IP allowlist** | Yes (CIDR, per gateway) | Not documented |
| **Structured logging** | Yes (SQLite / swap for ClickHouse) | Yes (managed, 21+ metrics) |
| **Analytics dashboard** | No (raw SQL / Prometheus only) | Yes (cost, latency percentiles, user activity, metadata grouping) |
| **Distributed tracing** | No | Yes (OpenTelemetry / W3C, span hierarchy) |
| **Feedback API** | No | Yes (weighted scores, link to trace) |
| **Prompt library** | No | Yes (versioned templates, Mustache, partials, playground) |
| **Agent framework integrations** | No | Yes (16 frameworks, agentic trace + cost rollup) |
| **Admin REST API** | Yes (tenant/gateway/user/token CRUD) | Yes (config, keys, prompts, guardrails CRUD) |
| **Multi-tenancy** | Yes (tenant + gateway hierarchy) | Yes (account → org → workspace) |
| **SSO / RBAC** | No | Yes (Enterprise — OIDC, 3 roles, granular key permissions) |
| **Audit logging** | No | Yes (Enterprise) |
| **SOC 2 / HIPAA** | No | Yes (Enterprise) |
| **Self-hosted / OSS** | Yes (the whole stack) | Yes (`npx @portkey-ai/gateway`) |
| **gRPC** | No | Yes (Enterprise self-hosted) |
| **Multimodal** | No (text only) | Yes (vision, image-gen, TTS, STT, function calling) |
| **Frontend / UI** | React admin UI + Chat console + Playground | Managed SaaS UI (full featured) |
| **Chat console (persistent conversations)** | Yes — full multi-turn chat with history, presets, export | Yes — basic prompt playground |
| **Reasoning model rendering (thinking blocks)** | Yes — collapsible `<think>` panel, duration timer | Yes — thinking mode with token budget |
| **Artifact panel (HTML/SVG live preview)** | Yes — sandboxed iframe, streaming-aware | No |
| **File attachments in chat** | Yes — images, PDF, DOCX, CSV/XLS, TXT, Markdown | Yes — images, vision only |

---

### Major Gaps

#### 1. Provider Coverage
We support 21 providers (OpenAI, Anthropic, Google Gemini, Vertex AI, Azure OpenAI, AWS Bedrock, Mistral, Groq, Together AI, Fireworks, Cerebras, DeepSeek, OpenRouter, Perplexity, SambaNova, xAI, NVIDIA NIM, Cloudflare AI, Cohere, HuggingFace, Ollama). Portkey supports 50+ with 1,600+ model aliases via aggregator integrations. The gap has narrowed significantly but Portkey's aggregator model allows faster long-tail coverage.

#### 2. Load Balancing
We have no load balancing. Portkey offers weighted round-robin across providers, models, and API keys — including sticky sessions (consistent routing per user/conversation) and canary rollout (gradual traffic migration). This is a significant operational gap for teams managing rate limits across multiple API keys or running A/B model tests.

#### 3. Circuit Breaker
✅ **Implemented.** We have a CLOSED→OPEN→HALF_OPEN state machine with configurable `failure_threshold`, `window_sec`, `cooldown_ms`, and `failure_status_codes`. This is actually a gap for Portkey — their circuit breaker auto-closes after cooldown but lacks the HALF_OPEN probe behaviour that ours implements.

#### 4. Semantic Caching
Our cache is exact-match only. Portkey offers vector-similarity caching (configurable threshold) that catches near-identical prompts differing only in minor phrasing. This can meaningfully improve cache hit rates for conversational use cases.

#### 5. Analytics & Dashboards
We now have an analytics dashboard with hero cards (requests, cost, guardrail hits), sparkline charts, top models, usage-by-tenant tables, and latency percentiles (p50/p95/p99). Portkey still leads on group-by custom metadata, feedback score trends, and 365-day retention. Our gap has narrowed substantially for operational monitoring; Portkey's advantage is mainly in eval-driven analytics workflows.

#### 6. Distributed Tracing (OpenTelemetry)
We have no tracing. Portkey emits W3C-compliant OpenTelemetry spans covering the full request lifecycle including retries, fallbacks, and agentic sub-calls. This is especially important for multi-step agent workflows where understanding cost and latency per step is essential for optimization.

#### 7. Guardrails Depth
Our guardrails are: Llama Guard 3 (input, 14 categories) + regex patterns (output). Portkey has 20+ deterministic checks, LLM-based checks (gibberish, prompt injection), language detection, and 22 partner integrations (Pangea, Palo Alto Prisma, CrowdStrike, etc.). The output guardrail story is particularly weak on our side.

#### 8. Prompt Library
We have no prompt management. Portkey has a versioned prompt library with Mustache templating, reusable partials, a multi-model playground, and staged publishing workflows. Teams using our gateway must manage prompts entirely outside the gateway.

#### 9. Feedback API & Evals
We have no feedback mechanism. Portkey's feedback API allows linking human scores (−10 to 10) to individual traces, enabling eval dataset curation and A/B model comparison workflows.

#### 10. Agent Support
We have no agent-specific features. Portkey integrates with 16 frameworks (LangChain, LlamaIndex, CrewAI, AutoGen, OpenAI Agents SDK, etc.) and provides trace-level cost and latency rollups for multi-step agent runs.

#### 11. SSO, RBAC, Audit Logging
We have a simple admin/member/viewer role model with no SSO or audit trail. Portkey has OIDC SSO, per-feature API key permissions, and full audit logging — table-stakes for enterprise sales.

#### 12. Multimodal
At the **gateway routing layer**, we handle chat completions only (text and vision via `image_url` blocks). Portkey additionally routes image generation (DALL-E, Stable Diffusion), text-to-speech, speech-to-text, and function calling across providers.

In the **Chat Console UI**, we handle a broad set of file types: images (JPEG/PNG/GIF/WebP), PDF, plain text, Markdown (.md), Word (.docx), CSV, TSV, Excel (.xlsx/.xlsm), and OpenDocument (.ods). Images are sent as `image_url` blocks for vision-capable models. This makes the chat UI practically multimodal for document and image workflows, even if the gateway routing layer is text/vision only.

---

### Implementation Ideas to Close the Gap

#### High priority — core gateway

| Gap | Implementation Idea |
|---|---|
| **More providers** | Add provider modules for AWS Bedrock (SigV4 signing already planned), Cohere, Ollama/LocalAI (custom base URL passthrough), Together AI, Fireworks AI, Vertex AI. Each is ~100–200 lines following the existing provider interface in `src/providers/`. |
| **Load balancing** | Add a `load_balance` action type in the routing rules engine. Store weights in the routing rule `actions` JSON. Select target using weighted random in `routing/engine.lua`. Sticky sessions can be a keyed entry in `aig_config` shared dict (hash of `metadata.user_id` → target index, TTL configurable). |
| **Circuit breaker** | Add a `circuit_breaker` table in `aig_ratelimit` shared dict: `{failures, last_failure_ts, state: closed|open}`. Check state in `upstream.lua` before each attempt; after `cooldown_interval` ms, probe once and close on success. |
| **Semantic caching** | Add a vector embedding step to `cache_check.lua`: call an embedding endpoint (can reuse existing provider connections), store vector + response in a local HNSW index or Redis vector field. Add a `cache.semantic_threshold` config option. |

#### Medium priority — observability

| Gap | Implementation Idea |
|---|---|
| **Analytics dashboard** | Extend the React admin UI (`frontend/`) with an analytics page that queries the existing `request_logs` table. Aggregate by provider, model, user, cost, status. Add latency percentile queries (SQLite `percentile()` extension or manual). |
| **OpenTelemetry tracing** | Add `observability/tracer.lua` emitting OTLP HTTP spans. Create a root span per request, child spans for upstream calls, and link retry/fallback attempts as child spans. The W3C `traceparent` header can carry the trace ID across hops. |
| **Feedback API** | Add `POST /v1/feedback` to `admin/api.lua`. Store `{request_id, score, weight, meta}` in a new `feedback` table in `logs.db`. Join to `request_logs` for analytics. |
| **Log retention controls** | Add `log_retention_days` to gateway config. Add a background Lua timer (`init_worker_by_lua`) that runs a nightly `DELETE FROM request_logs WHERE ts < now - retention` query. |

#### Medium priority — guardrails

| Gap | Implementation Idea |
|---|---|
| **Output guardrail depth** | Add a `guardrails_response` pass through Llama Guard 3 for non-streaming responses (currently only regex patterns). Add JSON schema validation and `contains_code` checks as deterministic output guardrails. |
| **Guardrail actions** | Add `log_only` action (current `flag` does this) and a `deny` action with a configurable response message. Add `fallback_target` action: on guardrail block, re-route to an alternative gateway/model rather than hard-failing. |
| **PII category detection** | Extend `security/dlp.lua` with per-pattern category metadata (email → PII, SSN → PII, jwt → credential). Report category in logs alongside the pattern name. |

#### Lower priority — enterprise & DX

| Gap | Implementation Idea |
|---|---|
| **Prompt library** | Add a `prompts` table (id, name, template, variables, version, published_at). Expose `POST /admin/v1/prompts` and `POST /v1/prompts/{id}/completions`. Mustache rendering via a small Lua implementation or `lua-resty-template`. |
| **Agent tracing** | Accept `x-aig-trace-id` and `x-aig-span-id` headers. Propagate through to child requests. Store `parent_span_id` in `request_logs`. Add a trace-level cost rollup query to the analytics API. |
| **RBAC improvements** | Add granular permission scopes to `auth_tokens` (e.g., `logs:read`, `prompts:write`, `admin:full`). Check scopes in `admin/api.lua` per endpoint. |
| **Audit log** | Add an `audit_log` table: `{id, user_id, action, resource_type, resource_id, ts, ip}`. Write to it on every admin API mutation. Expose via `GET /admin/v1/audit`. |
| **Retry-after compliance** | In `upstream.lua`, parse `retry-after` and `retry-after-ms` response headers on 429. Pass the delay to the retry loop instead of using a fixed backoff. |
| **Timeout granularity** | Support per-routing-rule `timeout_ms` override in the `actions` JSON. Currently timeout is gateway-wide only. |
| **Canary / traffic split UI** | Extend the admin API to support `load_balance` routing actions with a `weights` array. Surface this in the React admin UI as a traffic split editor. |
