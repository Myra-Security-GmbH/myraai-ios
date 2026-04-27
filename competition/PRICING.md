# Enterprise Pricing Model — AI Gateway by Myra Security

> Internal strategy document. Last updated: 2026-04-27.

---

## 1. Positioning

AI Gateway is sold as **infrastructure**, not as a subscription to AI models. Customers bring their own provider API keys (BYOK) and pay providers directly at list price. Our invoice covers the platform layer: routing, guardrails, compliance, analytics, audit logging, and the EU-certified infrastructure of Myra Security.

This creates a two-part pricing structure:

1. **Seat fee** — $20/user/month. Covers platform access and baseline features. Anchors us against Mammouth AI (€20/user/month) and positions us in the same mental bracket while delivering infrastructure value rather than a consumer chat subscription.

2. **Management fee** — a declining percentage of monthly AI provider spend flowing through the gateway. This is the primary growth lever for accounts where usage scales faster than headcount.

---

## 2. Market Context

No major AI gateway currently charges a percentage of managed AI spend. The incumbent model is flat subscription (Helicone $79–$799/month, Portkey $49+/month, LiteLLM Enterprise $30K/year). This creates a pricing gap:

- Flat-fee products become very cheap relative to value at high spend levels
- Customers using $100K+/month in AI tokens pay the same as customers using $5K/month
- The infrastructure provider captures no upside as the customer's AI investment grows

The closest analogies in adjacent markets:
- **FinOps tools** (CloudHealth, Cloudability): 2–3% of managed cloud spend for visibility and governance
- **OpenRouter BYOK tier**: 5% on usage beyond 1M requests/month (developer-facing, not enterprise)
- **DSP/adtech platforms**: 10–15% of managed media spend (normalised in marketing, not yet in infrastructure)

### Pricing floor set by competitors

| Product | Approximate cost at $10K/month AI spend |
|---|---|
| LiteLLM Enterprise Premium | $2,500/month (flat, regardless of spend) |
| Helicone Team | $800/month (flat) |
| Portkey (volume) | ~$500/month |
| **AI Gateway (proposed)** | **$1,400–$2,200/month** (seat + 10–12% mgmt fee) |
| Build in-house | $5,000–$10,000/month (0.5–1 FTE + infra) |

We are more expensive than flat-fee alternatives at mid-range spend, but cheaper than building in-house. This gap must be justified by the compliance, security, and EU sovereignty features that flat-fee products do not provide.

---

## 3. Proposed Pricing Model

### Part A — Seat Fee

**$20 per user per month** (minimum 5 users, annual commitment)

Covers:
- Access to the Admin UI, Playground, and Chat module
- Gateway management (up to 20 gateways per tenant)
- Budget and rate-limit enforcement
- Basic routing rules (up to 10 rules per gateway)
- 30-day request log retention
- Standard support (email, 48h SLA)

### Part B — Management Fee on Managed AI Spend

Calculated monthly on the total AI provider spend tracked through the gateway (sum of `cost_usd` across all requests, based on model pricing at list rates).

| Monthly Managed AI Spend | Management Fee | Fee on Marginal Dollar |
|---|---|---|
| $0 – $2,500 | 20% | $0.20 |
| $2,500 – $10,000 | 15% | $0.15 |
| $10,000 – $50,000 | 10% | $0.10 |
| $50,000 – $200,000 | 7% | $0.07 |
| $200,000 – $500,000 | 5% | $0.05 |
| > $500,000 | Negotiated (≥ 3%) | Custom |

The fee is tiered (not step): a customer spending $12,000/month pays 15% on the first $10,000 and 10% on the remaining $2,000. The effective rate declines continuously with volume.

**Annual cap (Enterprise tier only):** Management fees are capped at a negotiated annual maximum. This converts the model from open-ended exposure to a predictable line item — a prerequisite for enterprise procurement sign-off.

---

## 4. Effective Rate by Volume — Examples

| Monthly AI Spend | Management Fee | Seat Fee (20 users) | Total/Month | Effective Rate (incl. seats) |
|---|---|---|---|---|
| $1,000 | $200 (20%) | $400 | $600 | 60% of spend |
| $5,000 | $837 (blended 16.7%) | $400 | $1,237 | 25% of spend |
| $15,000 | $1,750 (blended 11.7%) | $400 | $2,150 | 14% of spend |
| $50,000 | $4,750 (blended 9.5%) | $400 | $5,150 | 10% of spend |
| $100,000 | $8,250 (blended 8.25%) | $400 | $8,650 | 8.7% of spend |
| $300,000 | $20,250 (blended 6.75%) | $400 | $20,650 | 6.9% of spend |

At every tier, cost is well below the alternative of building equivalent infrastructure in-house (minimum $60K/year for a dedicated platform engineer, excluding infra costs). At mid-range spend ($15K–$50K/month), the total platform cost is 10–15% of AI spend — comparable to a cloud FinOps tool at 2–3% of cloud spend, but with significantly more active functionality (routing, guardrails, compliance).

---

## 5. Plan Tiers

### Starter — $20/user/month, min 5 users
*For teams up to ~25 users with <$5K/month in AI spend*

- Seat fee only; no management fee on the first $2,500/month in managed spend
- Core gateway features: routing, budgets, rate limiting, basic guardrails (Tier 1 only)
- 30-day log retention
- Standard email support
- Up to 5 tenants, 20 gateways
- **Included managed spend:** $2,500/month (above that, management fee applies at 20%)

### Professional — $20/user/month + management fee
*For growing teams with $5K–$100K/month in AI spend*

- Full management fee schedule (15% → 10% → 7% as above)
- All Starter features
- Full guardrail pipeline (Tier 1 + Tier 2: Presidio, Prompt Guard, PII Protector)
- SIEM export, Prometheus metrics
- 90-day log retention
- Priority support (email, 24h SLA; phone escalation)
- Unlimited tenants and gateways
- Anthropic usage sync with authoritative cost reporting

### Enterprise — Negotiated, anchored at $20/user/month
*For organisations with >$100K/month in AI spend or >100 users*

- All Professional features
- Annual management fee cap (negotiated; typically 10–15% of estimated annual AI spend at onboarding)
- Extended log retention (1 year+)
- SSO (SAML/OIDC)
- Dedicated account manager and CSE
- 99.9% uptime SLA with credits
- Custom Myra CDN routing configuration (EU data residency paths)
- GDPR/DSGVO data processing agreement (DPA)
- Compliance documentation (SOC 2 report, ISO certification from Myra Security)
- Wire transfer and PO-based invoicing
- Custom contract terms (MSA, DPA, BAA where applicable)

---

## 6. Rationale: Why 20% to 5%?

### The high end (20% at low spend) is defensible

At $1,000/month in AI spend, the customer is a small team or early adopter. The 20% management fee = $200/month. For that:

- One engineer spending 2 hours/month managing API keys, monitoring costs, and handling incidents costs $200+ in labour at any market rate
- The alternative (Helicone Pro) is $79/month flat but provides no guardrails, no EU sovereignty, no compliance audit trail
- The comparison to Mammouth ($20/user including tokens) is misleading: Mammouth's ~$10 of API credits per Standard user does not cover serious usage; a team actually spending $1K/month has already outgrown bundled subscriptions

### The low end (5% at high spend) preserves margin at scale

At $300,000/month in AI spend, the management fee is $20,250/month ($243K/year). This is:

- 10× LiteLLM Enterprise's price ($30K/year flat) — must be justified by the managed-service and compliance premium
- A significant revenue line for us with minimal incremental cost (the gateway processes the traffic regardless)
- Below the "political ceiling" for enterprise procurement: at 5%, a $500K/year AI programme pays $25K/year to the gateway vendor — reasonable for finance and legal sign-off

The 5% floor is critical: below it, the fee does not cover the ongoing compliance, support, and infrastructure investment for large accounts.

### The decline structure reflects real cost structure

- **Low-spend accounts** require proportionally more support, onboarding, and configuration relative to revenue
- **High-spend accounts** are mostly self-sufficient; the infrastructure runs on autopilot; account management is the primary cost
- Declining percentage is standard in enterprise SaaS (volume discounts, committed use discounts) and aligns our margin structure with customer spend growth

### Hard cap prevents procurement failure

Any enterprise spending >$500K/month in AI will model the annual gateway cost as a line item. An uncapped 5% against $1M/month = $600K/year — larger than most enterprise software contracts. The hard annual cap (negotiated at contract time, typically 12–18 months of projected spend × 4–5%) converts this from a risk to a fixed cost. Cap examples:

| Annual AI Spend | Uncapped 5% | Typical Cap | Effective Rate |
|---|---|---|---|
| $1.2M ($100K/month) | $60K/year | $50K/year cap | 4.2% |
| $6M ($500K/month) | $300K/year | $150K/year cap | 2.5% |
| $12M ($1M+/month) | $600K/year | $200K/year cap | 1.7% |

---

## 7. Competitive Positioning Against Flat-Fee Alternatives

| Scenario | LiteLLM Enterprise | Helicone Team | **AI Gateway** |
|---|---|---|---|
| 20 users, $10K/month AI spend | $30K/year flat | $9.6K/year flat | ~$26K/year |
| 20 users, $50K/month AI spend | $30K/year flat | $9.6K/year flat | ~$67K/year |
| 20 users, $200K/month AI spend | $30K/year flat | $9.6K/year flat | ~$175K/year |

At low spend, we are price-competitive with flat-fee products. At high spend, we are significantly more expensive. The differentiators that justify the premium:

1. **Myra Security EU-certified infrastructure** — LiteLLM and Helicone are US-hosted SaaS; we operate on certified EU CDN infrastructure
2. **Full Tier 2 guardrail pipeline** — PII tokenisation, Prompt Guard, Presidio; LiteLLM has basic guardrails, Helicone has basic prompt inspection
3. **Managed service** — zero infrastructure management for the customer; LiteLLM Enterprise is self-hosted (customer ops it)
4. **Compliance documentation** — DPA, SOC 2, data processing records; Helicone offers HIPAA on Team tier only

For accounts >$100K/month in AI spend considering LiteLLM self-hosted, the conversation is: "Do you want to spend $30K/year on the software and dedicate engineering to operating it, or $X/year on a fully managed, compliance-ready platform?" The crossover point where AI Gateway is cheaper (including estimated ops cost) is approximately $50K/month in AI spend for most EU-based enterprise customers.

---

## 8. Comparison to Mammouth AI

| | Mammouth AI (Team) | AI Gateway (Professional) |
|---|---|---|
| Base price | €20/user/month | $20/user/month |
| Token costs | Included (quota-limited) | Customer pays providers directly (BYOK) |
| Effective cost at $10K AI spend (20 users) | €400/month (but tokens capped by quotas — $10K would far exceed any Mammouth plan) | ~$2,150/month (seat + 10–12% mgmt fee) |
| API access for your own apps | ✗ | ✅ |
| Guardrails / PII scrubbing | ✗ | ✅ |
| Per-user budget enforcement | ✗ | ✅ |
| EU compliance / audit log | ✗ | ✅ |
| Custom routing / fallback | ✗ | ✅ |

Mammouth's pricing is only competitive for end-users consuming AI via a chat interface and staying within quota limits. Any organisation that (a) integrates AI programmatically, (b) needs compliance controls, or (c) spends more than ~$100/month per user on AI will find Mammouth insufficient and AI Gateway the correct choice at an acceptable price premium.

---

## 9. Minimum Viable Deal Size

Given the seat minimum (5 users) and management fee structure:

- Minimum contract: 5 users × $20/month × 12 months = **$1,200/year** (Starter, no management fee on first $2,500/month)
- Typical SMB deal: 20 users + $10K/month AI spend = **~$26K/year**
- Typical mid-market deal: 50 users + $50K/month = **~$67K/year**
- Typical enterprise deal: 150 users + $200K/month = **~$202K/year**
- Target ACV (enterprise): **$100K–$500K/year**

---

## 10. Open Questions / Items to Validate

- [ ] Is the management fee legally structured as an "infrastructure management fee" (cleaner) or a "markup on AI spend" (accurate but may trigger procurement scrutiny)?
- [ ] Should Starter plan include ANY management fee, or be fully flat to maximise top-of-funnel conversion?
- [ ] Annual cap formula: fixed dollar amount, or a percentage of contracted spend? The latter auto-adjusts as customer scales.
- [ ] What's the minimum management fee per month (floor)? A customer spending $100/month in AI at 20% = $20/month, which creates billing overhead. Consider a $50/month floor on the management fee.
- [ ] Should EU-based customers pay in EUR rather than USD? Given the target market, EUR-denominated contracts reduce friction.

---

## Sources

- Mammouth AI pricing: mammouth.ai/pricing (April 2026)
- Helicone: helicone.ai/pricing
- Portkey: portkey.ai/pricing
- LiteLLM Enterprise: litellm.ai/enterprise
- CloudHealth pricing: cloudzero.com/blog/cloudhealth-pricing
- OpenRouter BYOK fee: openrouter.ai/docs/faq
- Portkey $93M spend analysis: portkey.ai/blog
- Kong Konnect pricing: konghq.com/pricing
- Cloudflare AI Gateway: developers.cloudflare.com/ai-gateway/reference/pricing
