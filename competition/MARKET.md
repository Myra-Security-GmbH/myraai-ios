# Market & Competitive Analysis

_Last updated: 2026-03-28 (Chat UI: thinking blocks, artifact panel, markdown import; vLLM 512K context)_

## Competitor Overview

| Company | Positioning | Pricing model |
|---|---|---|
| **Portkey** | Developer-first gateway with guardrails & prompt mgmt | Hosted SaaS + self-host |
| **LiteLLM** | OpenAI-compat proxy, strong spend controls | Open-source + hosted proxy |
| **Helicone** | Observability-first — traces, evals, prompt versions | Hosted SaaS |
| **Langfuse** | Full LLMOps platform — traces, evals, datasets | Open-source + hosted SaaS |
| **Kong AI Gateway** | Enterprise API gateway with AI plugins | Enterprise licence |
| **OpenRouter** | Model marketplace / unified API | Per-token markup |
| **AWS Bedrock** | Fully managed cloud AI platform (AWS ecosystem) | Pay-per-token, no platform fee |
| **Cloudflare AI Gateway** | Edge-native gateway; unified interface for 350+ models | Free core; pay for log egress / Workers AI |
| **Portkey** (enterprise) | LLMOps control plane; 1,600+ LLMs, SOC2/HIPAA | $49/mo → $2K–$10K+/mo enterprise |
| **Bifrost (Maxim AI)** | Performance-first OSS gateway; Go, 11µs overhead | Open source (Apache 2.0); enterprise support TBD |
| **Omnifact** | Privacy-first enterprise AI assistant (EU/GDPR); end-user chat platform | €25/user/month; enterprise on request |

---

## AWS Bedrock Deep-Dive

### What it is

Amazon Bedrock is a **fully managed cloud platform** — not a proxy or gateway. It provides direct API access to 50+ foundation models (Anthropic Claude, Meta Llama, Mistral, Cohere, AI21, Amazon Nova, Titan, etc.) with native AWS security, billing, and compliance tooling. Enterprises that are already AWS-native may reach for Bedrock as a "one-stop shop" rather than deploying a separate gateway.

This makes Bedrock a **different category of competitor**: it doesn't compete on the proxy/gateway layer directly, but on the "why deploy your own gateway at all?" question.

---

### AWS Bedrock Pricing

All pricing is **usage-based with no platform or seat fee**.

#### Model inference

| Pricing mode | Cost structure | Discount |
|---|---|---|
| **On-demand** | Per input/output token (varies by model) | — |
| **Provisioned Throughput** | Fixed monthly model-unit reservation | ~20–40% off on-demand |
| **Batch inference** | Same as on-demand jobs (async) | 50% off on-demand |
| **Prompt caching** | Cached input tokens | Up to 90% off input tokens; 1-hour TTL (launched Jan 2026 for Claude Sonnet/Haiku/Opus 4.5) |
| **Fine-tuning** | Per token processed + per model/month storage | Varies |

#### Guardrails surcharge (on top of model inference)

| Policy type | Price |
|---|---|
| Content filters + Denied Topics | **$0.15 per 1,000 text units** (~1,000 chars each) |
| Sensitive information (PII) filters | **Free** |
| Automated Reasoning (hallucination check) | Separate charge; see AWS pricing page |

Guardrails add ~10–30% to effective inference cost for filtered workloads at typical message lengths.

#### Additional hidden costs

- **Knowledge Bases on OpenSearch Serverless**: floor ~$350/month (2 OCUs × $0.24/hour) even at zero traffic — avoidable by using S3 Vectors (launched Dec 2025)
- **Bedrock Agents**: multi-step reasoning multiplies tokens 5–10× per user turn
- **Cross-region inference**: no extra charge, but latency increases

---

### Feature Comparison: AI Gateway vs AWS Bedrock

| Feature | **AI Gateway (Myra)** | **AWS Bedrock** |
|---|---|---|
| **Multi-provider routing** | ✅ 21 providers (true multi-cloud) | ❌ AWS-hosted models only |
| **OpenAI-compatible endpoint** | ✅ single `/compat` endpoint, no SDK changes | ❌ Bedrock-native API; requires SDK migration |
| **Circuit breaker** | ✅ CLOSED→OPEN→HALF_OPEN state machine | ❌ not implemented |
| **Load balancing (weighted/round-robin)** | ✅ per-route, per-target weight | ✅ cross-region automatic failover |
| **Fallback chains** | ✅ configurable per route | ✅ cross-region (same model family) |
| **Exact-match prompt cache** | ✅ SHA-256 keyed, configurable TTL | ✅ up to 1-hour TTL, up to 90% savings |
| **Semantic cache** | Planned | ❌ |
| **Guardrails — content/keyword/jailbreak** | ✅ Tier 1 in-process, sub-ms | ✅ $0.15/1k text units; parallel eval |
| **PII redaction** | ✅ Presidio (50+ entity types) | ✅ free; 1-way redaction |
| **PII reversible tokenization** | ✅ restore real values in response | ❌ one-way redact only |
| **Hallucination detection** | ❌ | ✅ Automated Reasoning checks (formal logic, 99% accuracy) |
| **Prompt injection / jailbreak detection** | ✅ 18 built-in attack phrases | ✅ Prompt Attack category in content filters |
| **Multi-tenancy** | ✅ tenant/gateway/token hierarchy | ❌ IAM roles / AWS accounts only |
| **Per-tenant spend limits** | ✅ daily / monthly / total budgets | ❌ AWS Cost Management (account-level only) |
| **Per-tenant rate limits** | ✅ sliding-window per token | ❌ no per-tenant rate limiting |
| **BYOK (provider keys vault)** | ✅ AES-256 encrypted, per-request alias | ✅ KMS encryption at rest |
| **Web search augmentation** | ✅ Brave Search, server-side tool loop | ❌ |
| **Prompt management / versioning** | ❌ | ✅ via Bedrock Flows + Prompt Management |
| **Request tracing / sessions** | ❌ (planned) | ✅ CloudWatch + X-Ray |
| **Eval framework** | ❌ | ✅ Bedrock Evaluation (automatic + human) |
| **Model fine-tuning** | ❌ | ✅ supervised fine-tuning + continued pretraining |
| **Agentic workflows** | ✅ web search loop | ✅ Bedrock Agents, Flows, AgentCore (2026) |
| **Batch inference** | ❌ | ✅ 50% off on-demand |
| **Admin UI** | ✅ React SPA (full gateway management) | ✅ AWS Console |
| **Playground** | ✅ 4-model side-by-side, streaming, cost metrics | ✅ Bedrock Playground |
| **SSO / SAML / OIDC** | ❌ | ✅ IAM Identity Center |
| **Self-hostable / on-premise** | ✅ | ❌ AWS-managed only |
| **EU data sovereignty** | ✅ Myra EU CDN; entire pipeline stays in EU | ❌ US-based by default; EU regions available but data may transit US |
| **Gateway overhead (latency added)** | <1 ms (LuaJIT in-process) | ~20–100 ms AWS API call overhead |
| **DDoS protection** | ✅ Myra CDN built-in | ✅ AWS Shield |
| **Observability** | ✅ structured JSON logs, Prometheus, stats API | ✅ CloudWatch, X-Ray, Bedrock model invocation logging |
| **Cost attribution per tenant** | ✅ micro-dollar precision | ❌ AWS Cost Explorer is account-level |
| **Pricing model** | Managed service (contact sales) | Pure pay-per-token; no platform fee |

---

### Where AWS Bedrock wins

1. **No platform fee** — start for free; pay only for what you use. Zero procurement friction.
2. **Model fine-tuning** — custom model training and continued pretraining within the AWS trust boundary.
3. **Batch inference at 50% off** — async workloads (doc processing, data enrichment) are dramatically cheaper.
4. **Provisioned throughput** — 20–40% discount for guaranteed capacity; important at scale.
5. **Automated Reasoning** — the only commercially available formal-logic hallucination checker; no competitor (including us) has this.
6. **Bedrock Agents + Flows + AgentCore** — managed multi-step agentic pipelines with Knowledge Bases, RAG, code interpreter, memory, and browser. Mature, production-ready.
7. **Prompt management + evals** — full prompt versioning, A/B, and automated eval framework built in.
8. **IAM / SSO** — enterprise auth out-of-the-box via AWS Identity Center; no separate OIDC integration needed.
9. **CloudWatch + X-Ray integration** — full distributed tracing, metrics, alarms within the AWS observability stack.
10. **ApplyGuardrail API** — apply Bedrock safety policies to *any* model (including OpenAI, Gemini) without invoking Bedrock for inference.

---

### Where AI Gateway wins

1. **True multi-cloud, multi-provider** — 21 providers behind one endpoint. Bedrock locks you into AWS-hosted models. When Anthropic or OpenAI release a new model, you get it immediately; with Bedrock you wait for AWS integration.
2. **OpenAI compatibility** — existing apps using the OpenAI SDK work without changes. Bedrock requires SDK migration to the Converse API or a separate compatibility layer.
3. **EU data sovereignty** — the entire request pipeline, including Presidio PII scanning and Llama Guard inference, runs within Myra's EU-certified CDN. With Bedrock, even EU-region deployments may have data touching US control planes. This is the decisive factor for European government and financial services customers.
4. **Circuit breaker** — automatic traffic isolation when a provider degrades; no major AI gateway competitor implements this. Bedrock's cross-region failover only covers capacity issues within AWS, not provider-level failures.
5. **Reversible PII tokenization** — real values restored in the model response so downstream apps see coherent output. Bedrock redacts one-way only; applications must handle the redacted tokens or re-query.
6. **Per-tenant multi-tenancy** — full tenant/gateway/token hierarchy with per-tenant budgets, rate limits, and cost attribution. Bedrock has no concept of tenants; isolation is AWS account/IAM-role-based, which doesn't map to SaaS multi-tenancy.
7. **Sub-millisecond gateway overhead** — LuaJIT in nginx adds <1 ms. Every Bedrock call incurs ~20–100 ms AWS API latency on top of model inference.
8. **Self-hostable** — air-gapped on-premise deployments for classified environments. Bedrock is AWS-only.
9. **Web search augmentation** — Brave Search built into the gateway, no application-side code required.
10. **DDoS + CDN** — Myra Security's CDN layer absorbs volumetric attacks before they reach the gateway; not available in Bedrock.
11. **BYOK with per-request key selection** — multiple encrypted provider keys per gateway with per-request alias override. Useful for multi-customer SaaS where each customer supplies their own API key.

---

### Strategic Positioning

**AWS Bedrock and AI Gateway target different buyer journeys:**

| Dimension | AWS Bedrock | AI Gateway (Myra) |
|---|---|---|
| **Buyer** | AWS-native engineering teams | EU enterprise / compliance-first / multi-cloud shops |
| **Deployment** | Fully managed cloud (no ops) | Managed service OR on-premise |
| **Vendor lock-in** | High — AWS API, AWS billing, AWS auth | Low — OpenAI-compatible; providers are interchangeable |
| **Compliance** | FedRAMP, SOC2, ISO 27001 (AWS) | EU GDPR / NIS2 / BSI angle via Myra CDN |
| **AI model policy** | Content filters + formal logic | Deep content pipeline: regex → keyword → jailbreak → Presidio → Llama Guard |
| **Cost at scale** | Cheapest via provisioned throughput + batch | No token markup; cost depends on Myra contract |
| **Time-to-value** | Hours (no infrastructure) | Days (managed) or weeks (on-premise) |

**Threat level: Medium.**

Bedrock is not a direct gateway competitor — it doesn't route between providers, add guardrail pipelines to existing LLM calls, or enforce multi-tenant policies across an SaaS product. However, enterprises evaluating "how do we manage AI spend and safety?" may choose Bedrock's platform approach over a separate gateway if they are already in AWS and don't need EU sovereignty or true multi-cloud. The ApplyGuardrail API (which works on any model) is the clearest overlap and the most credible Bedrock argument against buying a separate guardrail layer.

**Our response:**
- Lead with EU data sovereignty for European enterprise prospects — Bedrock cannot match this structurally.
- Lead with OpenAI-compat + multi-provider for teams that use multiple LLM providers or want to avoid Bedrock lock-in.
- Acknowledge Bedrock's stronger eval + agentic stack; position our roadmap (prompt management, tracing, evals) as closing that gap.
- Reversible PII tokenization is a concrete technical differentiator over Bedrock's one-way redaction — useful for healthcare, legal, and finance use cases where the AI must see anonymized data but the application receives real values.

---

## Cloudflare AI Gateway Deep-Dive

### What it is

Cloudflare AI Gateway is a **SaaS gateway layer** built into Cloudflare's global edge network. It sits in front of AI API calls, adding logging, caching, rate limiting, and DLP with zero infrastructure to run. Its core pitch is: if you're already behind Cloudflare, you get AI gateway capabilities essentially for free.

### Pricing

| Feature | Cost |
|---|---|
| Core gateway (logging, cache, rate limit) | **Free** on all Cloudflare plans |
| Logpush (external S3/SIEM streaming) | $0.05 per million records after 10M/month |
| Workers AI (Cloudflare-hosted models) | $0.011 per 1,000 Neurons |
| Unified billing (pay providers via CF invoice) | Small transaction fee (launched 2026) |

No per-request gateway fee. The gateway cost itself is effectively zero for most users.

### Feature Summary

| Capability | Detail |
|---|---|
| Model coverage | 350+ models across 6+ providers (OpenAI, Anthropic, Google, Groq, xAI, Mistral) |
| OpenAI-compat endpoint | ✅ |
| Caching | ✅ exact match |
| Rate limiting | ✅ |
| Logging | Up to 100M logs total (10M per gateway); available within 15 seconds |
| DLP / content filtering | ✅ GDPR, HIPAA, PCI DSS — text inspection on request + response |
| Guardrails depth | Basic DLP; no jailbreak detection, no Presidio NLP, no Llama Guard |
| Multi-tenancy | ❌ — no per-tenant hierarchy; Cloudflare account-level only |
| Per-tenant budgets | ❌ |
| Circuit breaker | ❌ |
| BYOK vault | ❌ — API keys managed in CF dashboard, not encrypted vault |
| PII reversible tokenization | ❌ |
| Self-hostable | ❌ — SaaS only |
| EU data residency | ⚠️ — SaaS model; data transits Cloudflare edge; EU regions available but compliance not guaranteed |
| SSO / SAML | ✅ via Cloudflare Access (enterprise) |

### Where Cloudflare wins

1. **Price**: core gateway is genuinely free — no platform fee, no per-request charge.
2. **Zero ops**: nothing to deploy or maintain; works by changing an API base URL.
3. **Infrastructure moat**: built on Cloudflare's global anycast network — latency to the nearest edge is typically <5 ms from anywhere in Europe.
4. **Unified billing**: consolidate AI provider invoices through one vendor.
5. **DDoS + WAF**: same protection as Cloudflare's enterprise-grade network, included by default.

### Where we win

1. **EU data sovereignty**: Cloudflare's SaaS model means request bodies transit Cloudflare infrastructure regardless of region. Myra's pipeline runs entirely within Myra EU CDN — no third-party SaaS data plane.
2. **Guardrail depth**: Cloudflare offers DLP (regex + entity detection). We offer six tiers: regex → keyword → jailbreak → Presidio NLP → Llama Guard → reversible PII tokenization. The gap is large.
3. **Multi-tenancy**: no per-tenant hierarchy in Cloudflare. No per-tenant budgets, rate limits, or cost attribution.
4. **BYOK vault**: Cloudflare stores provider keys in a dashboard, not an AES-256 encrypted vault with per-request alias selection.
5. **Circuit breaker**: not implemented in Cloudflare.
6. **Self-hostable / on-premise**: Cloudflare is SaaS-only; we offer on-premise for air-gapped environments.

### Threat level: Low–Medium

Cloudflare threatens the "why bother with a dedicated gateway?" question for teams that are already Cloudflare customers and have simple observability needs. It does not compete on enterprise governance, multi-tenancy, deep guardrails, or EU data sovereignty. The free price point will win casual evaluations but loses on any serious procurement checklist.

**Sales response**: Cloudflare is a logging/cache layer, not a policy enforcement layer. Show the guardrail pipeline comparison and the EU data sovereignty architecture diagram.

---

## Portkey Enterprise Deep-Dive

### What it is

Portkey is the most direct gateway-to-gateway competitor. It is an **LLMOps control plane** that covers the same surface as our product — multi-provider routing, guardrails, multi-tenancy, spend controls — plus prompt management and evals that we lack. It is open-source at the gateway layer (Apache 2.0 on GitHub) with a managed SaaS hosted tier and an enterprise tier with compliance certifications.

### Pricing

| Tier | Price | Notes |
|---|---|---|
| Starter | $49/mo | Basic features, limited governance |
| Pro | Custom | Adds RBAC, more guardrails |
| Enterprise | **$2,000–$10,000+/mo** | Full compliance, SSO, VPC, BAAs |

Billed per **recorded log**, not per request. At high volumes this can be cost-effective, but at low volumes the log-based model adds overhead. Enterprise pricing requires sales consultation.

### Feature Summary

| Capability | Detail |
|---|---|
| Model coverage | 1,600+ LLMs (via aggregator integrations) |
| Gateway latency | <1 ms claimed; 122 KB binary footprint |
| Guardrails depth | 50+ pre-built: PII redaction, jailbreak detection, toxic content, prompt injection |
| PII reversible tokenization | ❌ — redaction only, not reversible |
| Prompt management + versioning | ✅ full CRUD, A/B routing |
| Request tracing / sessions | ✅ |
| Evals framework | ✅ (basic) |
| Multi-tenancy | ✅ workspaces + roles |
| Per-tenant spend limits | ✅ |
| RBAC | ✅ enterprise tier |
| SSO / SCIM | ✅ enterprise tier |
| SOC2 / ISO 27001 | ✅ enterprise tier |
| HIPAA + BAA | ✅ enterprise tier |
| GDPR / CCPA | ✅ enterprise tier |
| VPC / private cloud | ✅ enterprise tier |
| Self-hostable | ✅ |
| EU data residency | ✅ with VPC hosting option |
| MCP support | ❌ — not prioritized |
| Web search augmentation | ❌ |
| Circuit breaker | ❌ |

### Where Portkey wins

1. **Prompt management + versioning** — the most mature prompt lifecycle tooling in the gateway market. Teams iterating on prompts get server-side storage, version history, and A/B routing built in.
2. **Compliance certifications** — SOC2 Type 2, HIPAA (with BAA), ISO 27001, GDPR, CCPA. We have none of these documented yet. This is a hard requirement for US healthcare and financial services.
3. **1,600+ models** — via aggregators; far broader catalog than our 21 direct integrations.
4. **Request tracing / sessions** — multi-turn conversation grouping and trace view; a gap we acknowledge on our roadmap.
5. **RBAC + SSO/SCIM** — enterprise identity management baked in; we currently have no SSO.
6. **Evals** — basic evaluation framework included.

### Where we win

1. **EU data sovereignty** — Portkey VPC option requires the customer to manage their own cloud infrastructure. Myra's managed service runs on the EU-certified Myra CDN with DDoS protection included.
2. **Reversible PII tokenization** — Portkey redacts PII one-way. Our `pii_protector` tokenizes before the model call and restores real values in the response — the model sees anonymized content, the application receives coherent output. No competitor does this.
3. **Circuit breaker** — Portkey has fallback/retry; it does not have a CLOSED→OPEN→HALF_OPEN state machine that automatically removes a degraded provider from rotation until it recovers.
4. **Web search augmentation** — Brave Search built into the gateway; Portkey has no equivalent.
5. **Sub-ms overhead via LuaJIT** — Portkey's claimed <1ms is competitive but achieved with a Node.js/TypeScript process; our LuaJIT runs in-process inside nginx with zero IPC overhead.
6. **DDoS + CDN layer** — Myra CDN absorbs volumetric attacks before they reach the gateway. Portkey self-hosted provides no equivalent; their managed SaaS does not include DDoS protection.

### Threat level: High

Portkey is the most capable direct competitor. It wins on compliance certifications, prompt management, model breadth, and evals — features on our Sprint 3–6 roadmap. For US enterprise deals, HIPAA + SOC2 will be a Portkey advantage until we obtain equivalent certifications. For EU deals, our data sovereignty posture and in-flight PII tokenization are the strongest counter-arguments.

**Sales response**: Lead with reversible PII tokenization, EU CDN data sovereignty, and circuit breaker. Acknowledge the prompt management gap and set a roadmap date. For regulated US industries, flag certification roadmap timeline.

---

## Bifrost (Maxim AI) Deep-Dive

### What it is

Bifrost is an **open-source, Go-based AI gateway** from Maxim AI. Its core proposition is raw performance: 11 µs gateway overhead at 5,000 RPS — roughly 9.5× faster than LiteLLM and 50× faster than Python-based alternatives on equivalent hardware. It is the only competitor that directly challenges our LuaJIT performance claim with published benchmarks.

Open source under Apache 2.0. Enterprise support and managed offerings contact-based.

### Benchmarks (Maxim AI published, t3.medium — 2 vCPUs)

| Metric | Bifrost | LiteLLM | Our claim |
|---|---|---|---|
| P50 latency overhead | ~11 µs | ~105 µs | <1 ms |
| P99 latency overhead | — | ~54× higher | — |
| Memory usage | baseline | +68% | — |
| Throughput (5k RPS) | sustained | degrades | — |

Note: Bifrost benchmarks are self-published by Maxim AI. Independent verification not yet available. Our own <1 ms claim similarly lacks a published benchmark methodology. **We should publish our own numbers.**

### Feature Summary

| Capability | Detail |
|---|---|
| Language / runtime | Go |
| Model coverage | 20+ providers |
| OpenAI compat | ✅ drop-in replacement |
| Load balancing | ✅ weighted + adaptive (detects throttling automatically) |
| Failover | ✅ automatic |
| Circuit breaker | ❌ — adaptive load balancing but no explicit CB state machine |
| Semantic caching | ✅ |
| MCP Gateway | ✅ OAuth 2.0, tool filtering, agent mode (unique in the market) |
| Hierarchical budgets | ✅ Virtual Keys: per-developer, per-team, per-org |
| Prometheus + OpenTelemetry | ✅ |
| Alerts | ✅ Slack, PagerDuty, Teams, email, webhooks |
| Secret management | ✅ HashiCorp Vault, AWS SM, GCP SM, Azure KV |
| Compliance claims | SOC2, GDPR, HIPAA, ISO 27001 (via audit trail feature) |
| PII scrubbing / tokenization | ❌ — not implemented |
| Jailbreak / prompt injection detection | ❌ — no guardrail pipeline |
| EU data sovereignty | ❌ — no CDN / EU-jurisdiction hosting |
| Self-hostable | ✅ Docker, Kubernetes |
| Managed SaaS | Contact for pricing |
| Open source | ✅ Apache 2.0 |

### Where Bifrost wins

1. **Raw performance** — if their benchmark holds, 11 µs is genuinely impressive. It is the strongest counter-argument to our LuaJIT performance narrative and we should validate with our own published benchmark.
2. **MCP Gateway** — native Model Context Protocol support with OAuth 2.0 and tool filtering. No other gateway in the market has this. Relevant for agentic workloads where models need to call external tools with permissioned access.
3. **Secret manager integrations** — native HashiCorp Vault, AWS SM, GCP SM, Azure KV. We use our own AES-256 vault; enterprises with existing secret management infrastructure may prefer Bifrost's integrations.
4. **Open source (Apache 2.0)** — zero cost to evaluate and run; community contributions; no vendor lock-in risk.
5. **Adaptive load balancing** — automatically detects provider throttling and shifts traffic; our weighted_random and round_robin are static.

### Where we win

1. **Guardrail depth** — Bifrost has no guardrail pipeline at all. We have six tiers including Presidio NLP, Llama Guard 3, and reversible PII tokenization. For any compliance-sensitive workload this is decisive.
2. **EU data sovereignty** — Bifrost is a self-hosted binary; customers must supply their own EU-compliant infrastructure. We provide a managed EU CDN with DDoS protection included.
3. **Circuit breaker** — explicit CLOSED→OPEN→HALF_OPEN state machine with configurable thresholds. Bifrost's adaptive load balancing shifts weights but does not hard-stop a failing provider.
4. **Web search augmentation** — no equivalent in Bifrost.
5. **Admin UI** — Bifrost is headless; management via config/API only. We provide a full React SPA with playground, live monitor, guardrail builder, and analytics dashboard.
6. **Managed service** — Bifrost is self-hosted only (managed offering unclear). We offer a fully managed EU-hosted service.

### Threat level: Medium (rising)

Bifrost is the most technically interesting new entrant. Its performance claims, MCP support, and Apache 2.0 licensing make it attractive for platform teams. It does not compete on guardrails or EU compliance. The risk is that it establishes a performance baseline that makes our "sub-millisecond" claim feel vague — **we should publish our own benchmark numbers against a common baseline (t3.medium, 5k RPS) before Bifrost's numbers become the market reference point.**

**Sales response**: For compliance/regulated prospects, the guardrail and EU sovereignty gap is disqualifying for Bifrost. For performance-sensitive prospects, acknowledge the competition and push for a benchmark bake-off. For MCP/agentic prospects, Bifrost is genuinely ahead — flag this as a roadmap item.

---

## Omnifact Deep-Dive

### What it is

Omnifact is a **privacy-first enterprise AI chat platform** headquartered in Germany. It is not an AI gateway in the developer/infrastructure sense. Its buyer is the **knowledge worker or IT admin** wanting a secure ChatGPT alternative, not the platform engineer building AI-powered applications. It competes in an adjacent category, but overlaps meaningfully on the EU data sovereignty and PII protection angles that are also central to Myra's positioning.

**Category**: Secure AI workplace assistant / RAG platform — not a routing/proxy gateway.

### Pricing

| Plan | Price |
|---|---|
| SME / Standard | **€25/user/month** (billed annually; min. 5 users = €125/month) |
| Enterprise | Contact sales |
| Free trial | 10 days |

Pricing is per seat, not per token or per request. Enterprise pricing covers larger user counts, on-premise deployment, and dedicated support.

### Feature Summary

| Capability | Detail |
|---|---|
| Target buyer | Knowledge workers, IT admins — not developers |
| Interface | Chat UI (browser-based); not an API proxy |
| Multi-model | ✅ OpenAI (GPT-5.4, GPT-4o), Anthropic (Claude 4.6 Opus/Sonnet), Google (Gemini 3.1 Pro), Mistral |
| Model selector with region flags | ✅ shows where data is processed per model |
| Privacy Filter™ | ✅ automatic prompt-level data masking before request leaves to provider |
| RAG / knowledge base ("Spaces") | ✅ custom AI assistants trained on internal docs |
| Cloud integrations | ✅ OneDrive, SharePoint, Google Drive |
| Admin usage analytics | ✅ per-user/assistant adoption tracking |
| User quotas + spend controls | ✅ |
| Audit trails | ✅ |
| SSO / RBAC | ✅ enterprise tier |
| GDPR compliance | ✅ German-hosted infrastructure |
| On-premise deployment | ✅ |
| Agentic API (Spaces as endpoints) | ✅ recently added |
| API proxy / routing | ❌ — no OpenAI-compat routing layer |
| Load balancing / failover | ❌ |
| Circuit breaker | ❌ |
| Per-tenant budgets (programmatic) | ❌ — user quotas in UI only |
| BYOK (provider key vault) | ❌ |
| Guardrail pipeline (jailbreak, Llama Guard) | ❌ — Privacy Filter™ is PII/sensitive data masking only |
| Webhooks / event callbacks | ❌ |
| Prometheus / OTel metrics | ❌ |
| Self-hostable by developers | ✅ on-premise, but for IT-managed deployment |
| Open source | ❌ |

### Where Omnifact wins

1. **End-user UX** — a polished chat interface designed for non-technical employees; RAG over internal documents (Spaces); image generation. Our product has no end-user interface and is not designed for knowledge workers.
2. **Seat-based pricing** — €25/user/month is simple and predictable for HR, finance, or ops teams rolling out AI to non-technical staff. No token math required.
3. **Privacy Filter™ usability** — automatic masking at the UI level, so employees don't need to understand what is or isn't sensitive. Our pii_protector operates at the API level and requires developer integration.
4. **German-hosted infrastructure** — EU data sovereignty is the same strength, but Omnifact's brand is built around it for a German-speaking B2B market.
5. **Established EU enterprise channel** — competing in the same regulatory market (banking, insurance, public sector) with a product already designed for non-technical procurement.

### Where we win

1. **Developer API / infrastructure layer** — Myra AI Gateway is an API proxy. Omnifact is a chat app. There is no overlap for teams building AI-powered products or platforms.
2. **Multi-tenant programmatic control** — our tenant/gateway/token hierarchy, per-tenant budgets, rate limiting, and BYOK vault are developer primitives that Omnifact has no equivalent for.
3. **Guardrail depth** — Privacy Filter™ masks PII/sensitive data; it does not detect jailbreaks, run Llama Guard content classification, or apply policy-as-code across API calls. Our six-tier pipeline is categorically deeper.
4. **Reversible PII tokenization** — Omnifact masks data going out and does not restore it in responses. Our pii_protector tokenizes, sends anonymized content to the model, and restores original values in the response — the application sees coherent output.
5. **Load balancing, failover, circuit breaker** — none of these exist in Omnifact; it is not an infrastructure product.
6. **OpenAI-compatible routing** — Omnifact has no API proxy layer for developers.
7. **Observability** — no Prometheus, no structured JSON logs, no OTel. Our platform is designed for platform engineers who need metrics pipelines and alerting.

### Competitive classification: Adjacent, not direct

Omnifact and Myra AI Gateway **do not compete for the same buyer** in the same purchase:

| Dimension | Omnifact | AI Gateway (Myra) |
|---|---|---|
| Buyer | IT admin / business unit head | Platform engineer / CISO / CTO |
| User | Knowledge workers (chat UI) | Developers (API) |
| Use case | Secure ChatGPT replacement for employees | Infrastructure for AI-powered applications |
| Pricing unit | Per seat | Per managed service / contract |
| EU angle | GDPR-compliant chat tool | GDPR-compliant API infrastructure layer |
| PII approach | UI-level masking (one-way) | API-level tokenization (reversible) |

**However**, Omnifact is relevant in two sales scenarios:

1. **Prospect overlap** — the same German enterprise CISO evaluating "how do we enable AI securely?" may talk to Omnifact (for employee chat rollout) *and* Myra (for developer API infrastructure) in the same procurement cycle. We should be able to position clearly: Omnifact is for the chat use case, we are for the API/platform use case. They are complementary.

2. **Competitive displacement risk** — if Omnifact expands its Spaces API into a fuller developer proxy (it has started: "Spaces published as API endpoints"), it could grow toward our territory. Monitor their API roadmap.

### Threat level: Low (currently)

Omnifact is not a gateway competitor today. Threat escalates if they ship a proper API routing layer, per-tenant policy enforcement, and observability stack — none of which are on their visible roadmap. Their moat is the end-user UX and Privacy Filter™ brand in the German-speaking market; ours is the infrastructure layer underneath.

**Sales response**: If a prospect mentions Omnifact, ask whether they are evaluating AI for employee productivity (→ Omnifact is appropriate) or for building AI-powered products/APIs (→ that's us). Frame as complementary where possible; avoid positioning as substitutes.

---

## Feature Comparison (Gateway Competitors)

| Feature | **Us** | Portkey | LiteLLM | Helicone | Langfuse | Kong AI | Cloudflare | Bifrost |
|---|---|---|---|---|---|---|---|---|
| **Providers** | ✅ 21+ | ✅ 1,600+ | ✅ 100+ | ✅ pass-through | ✅ pass-through | ✅ plugins | ✅ 350+ models | ✅ 20+ |
| **Load balancing / failover** | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ dynamic | ✅ adaptive |
| **Circuit breaker** | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ | ❌ | ❌ |
| **Exponential backoff + retry** | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ | ❌ | ✅ |
| **Semantic cache** | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ❌ | ✅ |
| **Multi-tenancy / API keys** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ virtual keys |
| **Per-tenant spend limits** | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ hierarchical |
| **Budget alerts / webhooks** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **Rate limits per tenant** | ✅ | ✅ | ✅ | ❌ | ❌ | ✅ | ✅ | ✅ |
| **Guardrails (content)** | ✅ 6-tier | ✅ 50+ | ✅ basic | ❌ | ❌ | ✅ | ✅ DLP only | ❌ |
| **PII scrubbing** | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ✅ DLP | ❌ |
| **PII reversible tokenization** | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Jailbreak detection** | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Prompt management** | ❌ | ✅ | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| **Prompt versioning / A/B** | ❌ | ✅ | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| **Request tracing / sessions** | ❌ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ logs | ✅ OTel |
| **Evals framework** | ❌ | ✅ basic | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ |
| **MCP Gateway** | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ✅ OAuth 2.0 |
| **Model aliases** | ❌ | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Streaming normalisation** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **BYOK** | ✅ AES-256 vault | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ dashboard | ✅ ext vaults |
| **Web search augmentation** | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Playground UI** | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ | ❌ |
| **Chat console (persistent, multi-turn)** | ✅ | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ | ❌ |
| **Reasoning model UI (thinking blocks)** | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Artifact panel (HTML/SVG live preview)** | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Cost analytics dashboard** | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| **SSO / SAML** | ❌ | ✅ paid | ✅ paid | ✅ paid | ✅ paid | ✅ | ✅ CF Access | ❌ |
| **SOC2 / HIPAA certs** | ❌ | ✅ enterprise | ❌ | ❌ | ❌ | ✅ | ✅ | claimed |
| **EU data sovereignty** | ✅ Myra CDN | ✅ VPC opt | ⚠️ self-host | ⚠️ self-host | ✅ self-host | ❌ | ❌ SaaS | ⚠️ self-host |
| **Self-hostable** | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ |
| **Open source** | ❌ | ✅ Apache 2.0 | ✅ MIT | ✅ MIT | ✅ MIT | ✅ OSS core | ❌ | ✅ Apache 2.0 |
| **Gateway overhead** | <1 ms LuaJIT | <1 ms Node.js | ~100 µs Python | ~ms Rust | N/A | ~ms plugins | <5 ms edge | ~11 µs Go |
| **Platform fee** | Managed SaaS | $49–$10K+/mo | Free–$19+/mo | $79+/mo | Free–$79+/mo | $30+/M req | Free core | Free OSS |

---

## Our Unique Strengths

- **Circuit breaker** — only Kong and us implement this among all tracked competitors; prevents cascade failures at the infrastructure level.
- **Web search augmentation** — automatic Brave Search tool injection; no gateway competitor bundles this.
- **PII reversible tokenization** — Presidio-backed in-flight scrub with response restoration; no competitor (including Portkey) does reversible tokenization.
- **LuaJIT on OpenResty** — <1 ms overhead; matches Portkey's Node.js claim; Bifrost (Go) now claims 11 µs and we should publish our own benchmark.
- **EU data sovereignty via Myra CDN** — the only managed gateway with the entire pipeline (PII scan, content moderation) running inside an EU-certified CDN. Cloudflare is SaaS; Portkey VPC requires customer-managed infra; Bifrost is self-hosted only.
- **Chat Console with reasoning-model UX** — built-in `/chat` interface with collapsible thinking-block rendering (duration-timed, auto-collapse on stream completion), live artifact panel for HTML/SVG code blocks, multi-format file import (images, PDF, DOCX, CSV/XLS, Markdown), and mobile-optimised input. No gateway competitor ships an end-user chat interface alongside the API layer.
- **512K-context local vLLM** — Qwen3-30B-A3B deployed with YaRN RoPE scaling to 524,288 tokens on an RTX PRO 6000 Blackwell (96 GB VRAM); available as a local sovereign inference option with no token cost.

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

9. **SSO / OIDC** — OIDC login for the admin UI. Gating feature for enterprise deals. Portkey, Kong, Cloudflare all have it.

10. **SOC2 / HIPAA certifications** — Portkey enterprise tier has SOC2 Type 2 + HIPAA + BAA. Currently a hard blocker for US healthcare/finance deals. Requires a compliance audit engagement.

11. **MCP Gateway** — Bifrost is first-to-market with OAuth 2.0 MCP support for agentic tool execution. Relevant for teams building autonomous agents with permissioned tool access.

12. **Published performance benchmarks** — Bifrost publishes Go vs LiteLLM numbers; our "sub-millisecond" claim is unsubstantiated in market materials. Publish LuaJIT benchmark (t3.medium, 5k RPS) before Bifrost's numbers become the market reference.

13. **Broader provider coverage** — Bedrock (AWS), Vertex AI native, Azure OpenAI native (currently via compat path).

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
