# What's New

Recent additions and fixes to AI Gateway, organised by feature area.

---

## Observability

**New: Timeseries stats** — Time-bucketed request counts, block counts, and cost are now available via the Stats API. Supports five bucket sizes (`5m`, `15m`, `30m`, `1h`, `6h`, `1d`) with up to 168 buckets per query. See [Stats API](../api-reference/stats.md).

**New: Multi-day dashboard views** — The dashboard now shows Yesterday and Last 7 days alongside the existing Today, Last hour, and Last minute views.

---

## Providers & Routing

**Fixed: Ollama model prefix stripping** — Requests using the `ollama/` model prefix (e.g. `ollama/llama3.2`) now correctly strip the prefix before forwarding to the Ollama API. Previously the prefix was forwarded verbatim, causing model-not-found errors.

**New: Weighted load-balancing** — Routing rules support weighted distribution across multiple providers. Traffic that exceeds a provider's weight is automatically routed to the next entry in the fallback chain.

**New: Per-provider circuit breaker** — After a configurable failure threshold is crossed, the gateway stops routing to the failing provider for a cooldown period before retrying.

---

## Playground

**New: Web search** — The Playground includes a web search toggle. When enabled, the gateway performs a live search and injects results into the model context before responding. A "searched" badge is shown on responses that used web search.

**Fixed: Web search empty results** — Search snippets that were empty or whitespace-only are now skipped; the page description is used as fallback.

**New: Filter non-runnable models** — The model picker can be filtered to show only models with a configured API key, reducing noise in large setups.

**New: Gemini native grounding** — Gemini models use Google's built-in grounding feature when web search is enabled, rather than the Brave Search path.

---

## Security & Guardrails

**New: Human-readable block messages** — Guardrail block responses now include the human-readable harm category name (e.g. "Violent Crimes") alongside the category code (e.g. `S2`).

**New: Anthropic tool use on compat endpoint** — OpenAI-format `tool_calls` sent via the compat endpoint to Anthropic are now automatically converted to Anthropic's native `tool_use` format.

---

## See also

- [Gateway Configuration Reference](config-reference.md)
- [Stats API](../api-reference/stats.md)
- [Routing Rules API](../api-reference/routing-rules.md)
- [Guardrail Pipeline](../security/guardrails.md)
- [Glossary](glossary.md)
