# Changelog

Recent additions and fixes to the AI Gateway, organised by feature area.

---

## Analytics & Observability

**New: Timeseries stats API** — `GET /admin/v1/stats/timeseries` returns time-bucketed request counts, block counts, and cost. Supports five bucket sizes (`5m`, `15m`, `30m`, `1h`, `6h`, `1d`) and up to 168 buckets per query. Zero-filled for empty buckets. See [Stats API](../api-reference/stats.md).

**New: Yesterday and Last 7 days timeframes in dashboard** — The stats dashboard now exposes `yesterday` and `last_7d` period stats alongside the existing `today`, `hour`, and `last_min` views, giving operators a quick multi-day cost and usage summary without querying the timeseries endpoint.

**New: Sparkline hero cards** — The admin UI dashboard renders live sparkline charts in the summary cards, driven by the timeseries API.

---

## Admin UI

**New: Provider base URL override editor** — The gateway config UI now includes an editable table for `provider_base_urls`, letting operators point any provider at a custom endpoint (e.g. a remote Ollama host or internal OpenAI-compat proxy) without editing JSON by hand.

---

## Providers & Routing

**Fixed: Ollama namespace prefix stripping** — Requests using the `ollama/` model prefix (e.g. `ollama/llama3.2`) now correctly strip the prefix before forwarding to the Ollama API. Previously the prefix was forwarded verbatim, causing model-not-found errors.

**New: Dynamic provider dropdown with requires_key filtering** — The gateway config UI provider dropdown is now populated from the live `/admin/v1/providers` list and filters out providers that do not require an API key (e.g. Ollama) from the BYOK key creation form.

**New: Weighted load-balancing with automatic fallback chain** — Routing rules support weighted distribution across multiple providers. Traffic that exceeds a provider's weight is automatically routed to the next entry in the fallback chain.

**New: Per-provider circuit breaker** — Each provider tracks consecutive failure counts. After a threshold is crossed the circuit opens, preventing further requests to the failing provider for a cooldown period before retrying.

---

## Playground

**New: Web search in Playground** — The Playground now includes a web search toggle. When enabled, the gateway performs a server-side Brave Search lookup before sending the prompt to the model, appending search results as context. The UI shows a "searched" badge on responses that used web search.

**Fixed: Web search returning "(no content)"** — Web search results that contained empty or whitespace-only snippets were previously displayed as "(no content)" in the Playground. The parser now skips empty snippets and falls back to the page description.

**New: "Only show runnable models" checkbox** — The ModelPicker in the Playground now has a checkbox to filter out models that cannot run (e.g. models for providers with no key configured), reducing noise in large multi-tenant setups.

**New: Unsupported-model badge** — Models that are known to be unsupported by the selected provider (e.g. Gemini model names on the Anthropic provider) now display a visual badge in the ModelPicker.

**New: Gemini grounding via web_search tool** — Gemini models in the Playground can use Google's native grounding feature when web search is enabled, rather than the Brave Search path.

---

## Security

**New: Llama Guard human-readable category names** — Guardrail block responses now include the human-readable Llama Guard harm category name (e.g. "Violent Crimes") alongside the category code (e.g. `S2`), making block messages easier to interpret without consulting the category table.

**New: Anthropic tool_calls conversion on compat path** — OpenAI-format `tool_calls` in requests sent to the compat endpoint targeting Anthropic are now automatically converted to Anthropic's `tool_use` format, enabling tool use via the unified endpoint.

**Fixed: BYOK key lookup skipped for keyless providers** — The BYOK middleware no longer attempts an API key lookup for providers that do not require one (e.g. Ollama), eliminating spurious "key not found" log warnings on keyless provider requests.

---

## See also

- [Gateway Configuration Reference](config-reference.md)
- [Stats API](../api-reference/stats.md)
- [Routing Rules API](../api-reference/routing-rules.md)
- [Guardrail Pipeline](../security/guardrails.md)
- [Glossary](glossary.md)
