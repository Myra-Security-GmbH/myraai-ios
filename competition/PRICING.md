# Enterprise Pricing Model — AI Gateway by Myra Security

> Internal strategy document. Last updated: 2026-04-27.

---

## 1. Positioning

AI Gateway is sold as **infrastructure**, not as a subscription to AI models. Customers bring their own provider API keys (BYOK) and pay providers directly at list price. Our invoice covers the platform layer: routing, guardrails, compliance, analytics, audit logging, and the EU-certified infrastructure of Myra Security.

This creates a two-part pricing structure:

1. **Seat fee** — **€18/user/month**. Covers platform access and baseline features. Anchors us €2 below Mammouth AI's €20/user/month team subscription while delivering infrastructure value rather than a consumer chat subscription. At the current EUR/USD rate (~1.13), €18 is essentially $20 — the target psychological anchor.

2. **Management fee** — a declining percentage of monthly AI provider spend flowing through the gateway, invoiced in EUR. This is the primary growth lever for accounts where usage scales faster than headcount.

**All pricing is in EUR.** AI providers bill customers in USD; the management fee is calculated on USD-denominated managed spend and converted to EUR on the invoice at a quarterly fixed rate (published on the first business day of each quarter). We build a ~3% FX buffer into the fixed rate to cover exchange-rate exposure within the quarter.

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

| Product | Approximate cost at €10K/month AI spend |
|---|---|
| LiteLLM Enterprise Premium | ~€2,200/month (flat, regardless of spend) |
| Helicone Team | ~€710/month (flat) |
| Portkey (volume) | ~€440/month |
| **AI Gateway (proposed)** | **~€1,260–€1,960/month** (seat + 10–12% mgmt fee) |
| Build in-house | €4,400–€8,800/month (0.5–1 FTE + infra) |

We are more expensive than flat-fee alternatives at mid-range spend, but cheaper than building in-house. This gap must be justified by the compliance, security, and EU sovereignty features that flat-fee products do not provide.

---

## 3. Proposed Pricing Model

### Part A — Seat Fee

**€18 per user per month** (minimum 5 users, annual commitment)

Covers:
- Access to the Admin UI, Playground, and Chat module
- Gateway management (up to 20 gateways per tenant)
- Budget and rate-limit enforcement
- Basic routing rules (up to 10 rules per gateway)
- 30-day request log retention
- Standard support (email, 48h SLA)

### Part B — Management Fee on Managed AI Spend

Calculated monthly on the total AI provider spend tracked through the gateway (sum of `cost_usd` across all requests, based on model pricing at list rates), converted to EUR at the quarterly fixed rate.

| Monthly Managed AI Spend (USD equiv.) | Management Fee | Fee on Marginal Dollar |
|---|---|---|
| €0 – €250 | 0% (Starter free tier only) | — |
| €250 – €10,000 | 20% | €0.20 |
| €10,000 – €45,000 | 15% | €0.15 |
| €45,000 – €180,000 | 10% | €0.10 |
| €180,000 – €450,000 | 7% | €0.07 |
| €450,000 – €1,800,000 | 5% | €0.05 |
| > €1,800,000 | Negotiated (≥ 3%) | Custom |

The fee is tiered (not step): a customer spending €11,000/month pays 20% on €9,750 and 15% on €1,250 above €10,000. The effective rate declines continuously with volume.

**Annual cap (Enterprise tier only):** Management fees are capped at a negotiated annual maximum. This converts the model from open-ended exposure to a predictable line item — a prerequisite for enterprise procurement sign-off.

**Minimum monthly management fee:** €50. Prevents billing overhead for micro-usage; absorbed by Starter seat revenue at low volumes.

---

## 4. Starter Plan Viability — Token Cap Analysis

The Starter plan provides a **€250/month free management fee tier** to remove friction for small teams. This cap is set by the following analysis:

**Typical token consumption (claude-sonnet-4-6, blended €4.78/MTok):**

| User profile | Tokens/month | AI spend/month |
|---|---|---|
| Light (10 msg/day, 2K tokens) | 0.6M | €3 |
| Normal (20 msg/day, 4K tokens) | 2.4M | €12 |
| Heavy (50 msg/day, 8K tokens) | 12M | €57 |

**5-user Starter team:**
- All normal: ~12M tokens = ~€62/month AI spend → well below cap
- All heavy: ~60M tokens = ~€286/month AI spend → management fee applies on €36 above cap = €7.20/month
- Break-even for infrastructure: seat revenue (€90/month for 5 users) covers our hosting costs up to ~1.8 million requests/month (unreachable for any small team in practice)

**Conclusion:** The €250/month free tier covers 99% of genuine small teams. It is not a loss-leader. The seat fee alone (€90/month minimum) exceeds our infrastructure cost at any realistic small-team usage level by a wide margin. The cap exists as a commercial boundary, not a technical one.

---

## 5. Effective Rate by Volume — Examples

All figures in EUR (USD-denominated spend converted at quarterly fixed rate).

| Monthly AI Spend | Management Fee | Seat Fee (20 users) | Total/Month | Effective Rate (incl. seats) |
|---|---|---|---|---|
| €1,000 | €150 (15%) | €360 | €510 | 51% of spend |
| €5,000 | €935 (blended 18.7%) | €360 | €1,295 | 26% of spend |
| €15,000 | €1,625 (blended 10.8%) | €360 | €1,985 | 13% of spend |
| €50,000 | €4,500 (blended 9.0%) | €360 | €4,860 | 9.7% of spend |
| €100,000 | €7,750 (blended 7.75%) | €360 | €8,110 | 8.1% of spend |
| €300,000 | €19,500 (blended 6.5%) | €360 | €19,860 | 6.6% of spend |

At every tier, cost is well below the alternative of building equivalent infrastructure in-house (minimum €50K/year for a dedicated platform engineer, excluding infra costs).

---

## 6. Plan Tiers

### Starter — €18/user/month, min 5 users
*For teams up to ~25 users with <€5K/month in AI spend*

- Seat fee only; **no management fee on the first €250/month** in managed spend
- Core gateway features: routing, budgets, rate limiting, basic guardrails (Tier 1 only)
- 30-day log retention
- Standard email support
- Up to 5 tenants, 20 gateways

The €250/month free tier covers ~46M tokens at Sonnet rates — approximately 4× what a normal 5-user team consumes. Teams spending more than €250/month in AI pay 20% on the excess; this is the signal to move to Professional.

### Professional — €18/user/month + management fee
*For growing teams with €5K–€450K/month in AI spend*

- Full management fee schedule (20% → 15% → 10% → 7% as above)
- First €250/month in managed spend is NOT free (management fee applies from first euro)
- All Starter features plus:
  - Full guardrail pipeline (Tier 1 + Tier 2: Presidio, Prompt Guard, PII Protector)
  - SIEM export, Prometheus metrics
  - 90-day log retention
  - Priority support (email, 24h SLA; phone escalation)
  - Unlimited tenants and gateways
  - Anthropic usage sync with authoritative cost reporting

### Enterprise — Negotiated, anchored at €18/user/month
*For organisations with >€450K/month in AI spend or >100 users*

- All Professional features plus:
  - Annual management fee cap (negotiated; typically 10–15% of estimated annual AI spend at contract time)
  - Extended log retention (1 year+)
  - SSO (SAML/OIDC)
  - Dedicated account manager and CSE
  - 99.9% uptime SLA with service credits
  - Custom Myra CDN routing configuration (EU data residency paths)
  - GDPR/DSGVO data processing agreement (DPA) included
  - Compliance documentation (Myra Security certifications, ISO, SOC 2)
  - Wire transfer and PO-based invoicing in EUR
  - Custom contract terms (MSA, DPA, BAA where applicable)

---

## 7. Rationale: Why 20% to 5%?

### The high end (20% at low spend) is defensible

At €1,000/month in AI spend, the customer is a small team or early adopter paying ~€200/month in management fee:

- One engineer spending 2 hours/month on API key rotation, cost monitoring, and incident response costs €200+ in labour at EU market rates
- Helicone Pro is ~€70/month flat but provides no guardrails, no EU sovereignty, no compliance audit trail
- The comparison to Mammouth (€20/user including tokens) is irrelevant: a team spending €1,000/month on AI has already outgrown any bundled subscription tier

### The low end (5% at high spend) preserves margin at scale

At €300,000/month in AI spend, the management fee is ~€19,500/month (€234K/year):

- 10× LiteLLM Enterprise's price (€28K/year flat) — justified by managed-service and compliance premium
- Significant revenue with minimal incremental infrastructure cost
- Below the "political ceiling" for enterprise procurement: a €4M/year AI programme paying €234K/year to the gateway vendor is a 5.8% overhead — acceptable for finance and legal sign-off

### Hard cap prevents procurement failure at scale

Any enterprise spending >€1M/month in AI will model the annual gateway cost as a line item. An uncapped 5% against €1M/month = €600K/year. The hard annual cap converts this from a risk to a fixed cost:

| Annual AI Spend | Uncapped 5% | Typical Cap | Effective Rate |
|---|---|---|---|
| €1.1M (€90K/month) | €54K/year | €45K/year cap | 4.1% |
| €5.4M (€450K/month) | €270K/year | €135K/year cap | 2.5% |
| €10.8M (€900K/month) | €540K/year | €180K/year cap | 1.7% |

---

## 8. Currency and FX Handling

**All invoices are denominated in EUR.**

### Why EUR, not USD

- Target market is EU enterprises and public sector; EUR eliminates FX hedging requirements for customers
- Regulatory and procurement processes in the EU are EUR-denominated
- Anchors against Mammouth AI (€20/user/month) in the same currency
- Myra Security is a German company; EUR is the natural home currency

### FX mechanism for management fee

AI provider costs are USD-denominated (OpenAI, Anthropic, etc. bill in USD). The management fee calculation:

1. Monthly managed spend is summed in USD from the gateway's cost tracking
2. Converted to EUR using the **quarterly fixed rate** published on the first business day of each quarter
3. The quarterly fixed rate = ECB spot rate at quarter start, adjusted by a 3% buffer (e.g., if ECB rate is 1.13, our contracted rate is 1.097 USD/EUR, meaning customers pay slightly more EUR per USD of spend)
4. The 3% buffer compensates for intra-quarter exchange rate movements and eliminates quarterly P&L volatility for us

**Example (Q2 2026):**
- ECB rate on 1 April: 1.13 USD = €1.00
- Our contracted rate: 1.097 USD = €1.00
- Customer spends $10,000 in AI in April
- Management fee (15%): $1,500 USD
- Invoice amount: $1,500 / 1.097 = **€1,368**
- vs. spot: $1,500 / 1.13 = €1,327 (our FX margin: €41)

For Enterprise customers with annual contracts, the quarterly rate is locked for 12 months at contract signing with a ±5% reset clause.

---

## 9. Competitive Positioning Against Flat-Fee Alternatives

| Scenario | LiteLLM Enterprise | Helicone Team | **AI Gateway** |
|---|---|---|---|
| 20 users, €10K/month AI spend | ~€28K/year flat | ~€8.5K/year flat | ~€23K/year |
| 20 users, €50K/month AI spend | ~€28K/year flat | ~€8.5K/year flat | ~€59K/year |
| 20 users, €200K/month AI spend | ~€28K/year flat | ~€8.5K/year flat | ~€156K/year |

At low spend we are price-competitive with flat-fee products. At high spend we are more expensive. Differentiators that justify the premium:

1. **Myra Security EU-certified infrastructure** — LiteLLM is self-hosted, Helicone is US SaaS; we run on certified EU CDN
2. **Full Tier 2 guardrail pipeline** — PII tokenisation (reversible), Prompt Guard, Presidio NLP; no flat-fee alternative provides this
3. **Managed service** — zero infrastructure management; LiteLLM Enterprise is self-hosted (customer ops it)
4. **Compliance documentation** — DPA, data processing records, Myra certifications; Helicone offers HIPAA only on higher tiers

---

## 10. Comparison to Mammouth AI

| | Mammouth AI (Team) | AI Gateway (Starter) | AI Gateway (Professional) |
|---|---|---|---|
| Seat fee | €20/user/month | €18/user/month | €18/user/month |
| AI token costs | Included (quota-limited per 3h) | Customer pays providers (BYOK) | Customer pays providers (BYOK) |
| Free management tier | — | €250/month AI spend | None |
| Effective overhead at €10K AI spend | Not possible (exceeds any plan) | ~20% mgmt fee on €9,750 = €1,950 | ~20% on first €9,750 = €1,950 |
| API access for own apps | ✗ | ✅ | ✅ |
| Guardrails / PII scrubbing | ✗ | Tier 1 only | ✅ Full pipeline |
| Per-user budget enforcement | ✗ | ✅ | ✅ |
| EU compliance / audit log | ✗ | ✅ | ✅ |
| Custom routing / fallback | ✗ | ✅ | ✅ |
| Invoice currency | EUR | EUR | EUR |

---

## 11. Minimum Viable Deal Size

| Deal type | Users | Monthly AI spend | Annual contract |
|---|---|---|---|
| Minimum (Starter) | 5 | <€250 | **€1,080/year** |
| Typical SMB | 20 | €10K | **~€23K/year** |
| Mid-market | 50 | €50K | **~€82K/year** |
| Enterprise | 150 | €200K | **~€226K/year** |
| Large enterprise | 500 | €1M | **~€300K/year (capped)** |

---

## 12. Open Questions / Items to Validate

- [ ] Does Professional management fee start from the first euro of spend, or does it include a small free tier (e.g., €50/month) to reduce early friction?
- [ ] Annual cap formula: fixed euro amount (simple) or a percentage of contracted annual spend (auto-scales)? Fixed is simpler to administer.
- [ ] Quarterly FX rate: ECB reference or ECB + buffer? Consider publishing the rate on our website for transparency.
- [ ] Should the seat fee for Enterprise be negotiated below €18, or held firm with contract perks (longer retention, SLA) as the lever?
- [ ] VAT handling: EU B2B is reverse-charge (0% VAT on invoice if customer has EU VAT number); outside EU requires careful jurisdiction analysis.

---

## Sources

- Mammouth AI pricing: mammouth.ai/pricing (April 2026)
- Helicone: helicone.ai/pricing
- Portkey: portkey.ai/pricing
- LiteLLM Enterprise: litellm.ai/enterprise
- CloudHealth pricing: cloudzero.com/blog/cloudhealth-pricing
- OpenRouter BYOK fee: openrouter.ai/docs/faq
- Kong Konnect pricing: konghq.com/pricing
- Cloudflare AI Gateway: developers.cloudflare.com/ai-gateway/reference/pricing
- ECB EUR/USD reference rates: ecb.europa.eu
