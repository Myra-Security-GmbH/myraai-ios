# What's new

Recent additions and fixes to AI Gateway, organised by feature area.

---

## Chat — April 2026

**New: Ghost mode** — Toggle ghost mode using the ghost icon in the conversation list header. While active, no messages are saved to the database, no request logs are created, and conversations exist only in memory. Use it for exploratory or sensitive conversations.

**New: Conversation sharing** — Generate a public share link for any conversation. Recipients can view the conversation without logging in. Share links can be revoked at any time. See [Chat — Sharing a conversation](../admin-ui/chat.md#sharing-a-conversation).

**New: Starring and archiving** — Star conversations to pin them at the top of the list. Archive conversations to remove them from the main view. A toggle reveals archived conversations when needed.

**New: Memory system** — The model can remember facts, preferences, and instructions across conversations. Memories are injected into the system prompt automatically. Create memories manually or let the model learn them from conversation context. Memory can be disabled per conversation. See [Chat — Memory](../admin-ui/chat.md#memory).

**New: Chat presets** — Tenant administrators can define preset buttons that appear in the Chat configuration bar. Members see only presets and cannot override gateway or model selection. See [Tenants — Chat presets](../admin-ui/tenants.md#chat-presets).

**New: Web search in Chat** — A globe icon in the chat toolbar toggles web search on or off for the current conversation. Previously web search was available only via API header or in the Playground.

**New: PowerPoint (.pptx) attachment** — `.pptx` files can be attached to chat messages alongside existing Word, Excel, and PDF support.

**New: Extended thinking display** — When extended thinking is enabled, the model's reasoning appears in a collapsible block above the response with a duration indicator.

**New: Automatic context management** — Long conversations are automatically summarised when they approach the model's context limit, allowing uninterrupted multi-turn sessions.

**New: Conversation URL sync** — The active conversation ID is reflected in the browser URL as a `?conv=` parameter, enabling direct links to specific conversations.

**New: Copy to Markdown** — A clipboard button in the configuration bar copies the full conversation as Markdown text.

**New: MCP connectors** — Register external Model Context Protocol servers to provide tools that models can call during chat. See [MCP Connectors](../admin-ui/mcp-connectors.md).

---

## Projects — April 2026

**New: Binary knowledge files** — Upload PDFs, Word documents, spreadsheets, presentations, and images to project knowledge bases. Server-side text extraction makes the content available in conversations.

**New: Search, filter, and sort** — The projects list includes a search bar, a role filter (all, your, team, shared), and a sort control (recent activity, last edited, date created).

**New: Batch save-to-project** — Save multiple conversations to a project at once from the Chat view.

**Renamed: "Knowledge" tab is now "Files"** — The project detail tab that manages knowledge files has been renamed from **Knowledge** to **Files**.

---

## Chat

**New: Session feedback** — Rate any conversation on a 1–5 star scale and add an optional comment using the flag (🚩) icon on each conversation row. Ratings are saved per conversation. See [Chat — Rating a conversation](../admin-ui/chat.md#rating-a-conversation).

**New: Drag-and-drop file upload** — Drag any supported file from your desktop and drop it anywhere on the message area. A blue drop target appears while the file is dragged over the panel. The file is attached exactly as if selected via the paperclip button. See [Chat — Importing a file](../admin-ui/chat.md#importing-a-file).

**New: Processing status indicator** — A spinner and status label appear in the message area between the moment you send a message and the moment the first response token arrives. The label shows what is happening — for example, extracting text from a document or waiting for the model.

**New: Spreadsheet file upload** — Attach spreadsheet files (`.csv`, `.tsv`, `.xlsx`, `.xlsm`, `.ods`) to any chat message. Claude reads and analyses the content and can answer questions about it. Spreadsheet files require an Anthropic provider key on the selected gateway. See [Chat — Importing a file](../admin-ui/chat.md#importing-a-file).

**New: Conversation export** — Download a conversation as a Markdown or PDF file using the export buttons in the chat configuration bar. Both buttons are disabled when no conversation is active. See [Chat — Exporting a conversation](../admin-ui/chat.md#exporting-a-conversation).

**Improved: Long response handling** — Long responses complete automatically without any action required.

**Improved: Conversation auto-title** — Conversation titles generated after the first exchange are more accurate and consistently formatted.

**New: Default system prompt** — The settings drawer opens with a default system prompt already filled in. Edit or clear it as needed.

**New: Code-block copy button** — Code blocks in assistant messages show a language label and a **Copy** button.

**Improved: Chat UI** — Updated message layout, avatar styling, and Markdown typography.

---

## Authentication

**New: Stay logged in** — A **Stay logged in for 30 days on this device** checkbox is available on the Email OTP login step. When selected, the session remains active for 30 days instead of the default 8 hours. See [Authentication — Session duration](../admin-ui/authentication.md#session-duration).

---

## Model prices

**Updated: Anthropic model support** — Pricing is now included for the Claude 4.5 and Claude 4.6 model families, including all dated model aliases. Prices for existing models have been updated to current rates. See [Model Prices](../configuration/model-prices.md).

---

## Chat

**New: Persistent multi-turn chat** — The **Chat** page provides a full conversation UI that routes every message through the gateway. Conversations are saved per user, support multi-turn history, and are completely isolated — no user can access another user's conversations. See [Chat](../admin-ui/chat.md).

**New: File attachments in chat** — Attach images (JPEG, PNG, GIF, WebP), PDFs, and plain text files to any message. Each file type is sent as the appropriate Anthropic content block (image, document, or text).

**New: Word document (.docx) support** — `.docx` files are uploaded to the Anthropic Files API and processed by the Anthropic docx Agent Skill. Claude reads and analyses the document content server-side. The skill header is automatically re-sent on follow-up turns in the same conversation.

**New: Unsupported file error** — Attaching a file type that the gateway cannot forward now shows an explicit error message listing supported formats. Previously, unsupported files were silently ignored.

**New: Chat localStorage persistence** — Tenant, gateway, and model selections are saved to local storage and restored when you return to the Chat page or navigate away and back.

---

## Gateway detail view

**New: Collapsible cards** — Each card on the gateway detail page (Gateway config, Provider Keys, Auth Tokens, Guardrails, Routing Rules, Circuit Breaker) can be individually collapsed and expanded using the ▼/▶ toggle in the card header. Collapsed state is persisted per gateway in local storage.

---

## SIEM integration

**New: SIEM event streaming** — Security events can now be forwarded asynchronously to an external SIEM. Supported backends: Splunk HEC, Elasticsearch / OpenSearch, Vector HTTP source, and Syslog (CEF or RFC 5424). SIEM config can be set at tenant level (default for all gateways) or overridden per gateway. Delivery is fire-and-forget and never adds latency to inference requests. See [SIEM Integration](../configuration/siem.md).

---

## Admin UI — role-based navigation

**New: Management section hidden from member and viewer roles** — The **Management** sidebar section (Tenants, Gateways, Users) is now visible only to `admin` and `tenant_admin` users. `member` and `viewer` users see only the Observability, Config, and Account sections.

---

## Users

**New: Sortable user table** — All columns in the **Users** view are now sortable. Click any column header to sort ascending; click again to sort descending. Sorting is applied server-side. See [User management](../admin-ui/users.md).

**New: Tenant reassignment** — `admin` users can now reassign a user to a different tenant from the Edit User dialog. `tenant_admin` users cannot change another user's tenant.

---

## Analytics dashboard

**New: Analytics tabs** — The analytics view now breaks down activity across five tabs: By Tenant, By Gateway, By Provider, By Model, and By User. Each tab has a filter bar for searching by name or ID.

**New: Overview chart** — A 30-day cost and request chart appears above the analytics tabs. Cost is shown as bars (left axis) and request volume as a line (right axis).

**New: Latency percentile strip** — p50, p95, and p99 latency chips are shown below the overview chart for the selected analytics window.

**New: Expanded hero cards** — The dashboard now shows six cards: Total Spend, Cache Savings, Total Requests, Error Rate, Top Spender, and Budget Warnings (previously three cards).

**New: By Provider tab** — Provider-level breakdown aggregated client-side from top-model data, showing request share, cost, model count, and average latency per provider.

**New: By User tab** — Per-user breakdown (up to 50 users) showing cost, cache rate, error rate, blocked count, and average latency. Only requests with a `user_id` on the auth token are included.

**New: Error rate** — By Tenant and By Gateway tables now show an Error% column counting upstream 4xx/5xx responses per entity.

---

## Tracing

**New: Gateway request tracing** — Gateways can now record step-by-step execution traces for inference requests. Enable with `"tracing": {"enabled": true}` in the gateway config. Steps include request normalisation, routing decisions, guardrail results, upstream calls, and response delivery. See [Request Tracing](../observability/tracing.md).

**New: Tracing config UI** — The gateway Config tab includes a Tracing section to enable tracing and optionally capture request bodies (`include_bodies`).

**New: Traces API** — `GET /gateways/{id}/traces` lists recent traces for a gateway. `GET /traces/{id}` returns the full step list for any trace. See [Traces API](../api-reference/traces.md).

---

## Budgets & quota

> ⚠️ **Caution:** The spend ledger is now persisted in a database table rather than in-memory counters. Spend survives process restarts and worker crashes, but existing in-memory counters are not migrated on upgrade.

**New: Persistent spend ledger** — Spend is now tracked in a `spend_ledger` table rather than shared-dict counters. Spend survives process restarts and worker crashes.

**New: `total` budget period** — A new `"total"` period accumulates spend over the lifetime of the budget without ever auto-resetting. Useful for one-time allowances and trial accounts. Valid period values are now `"daily"`, `"monthly"`, and `"total"` (`"weekly"` is not a valid value).

**New: Actionable QUOTA_EXCEEDED messages** — When a budget is exhausted, the 429 response now includes the configured budget, the current spend, and the exact API endpoint needed to either increase the budget or reset spend for the current period.

---

## Observability

**New: Timeseries stats** — Time-bucketed request counts, block counts, and cost are now available via the Stats API. Supports five bucket sizes (`5m`, `15m`, `30m`, `1h`, `6h`, `1d`) with up to 168 buckets per query. See [Stats API](../api-reference/stats.md).

**New: Multi-day dashboard views** — The dashboard now shows Yesterday and Last 7 days alongside the existing Today, Last hour, and Last minute views.

---

## Providers & routing

**Improved: Streaming reliability** — The gateway now uses a 5-minute read timeout for streaming responses, preventing premature connection drops on long model outputs. Stop-reason normalisation ensures consistent `finish_reason` values (`stop`, `max_tokens`, `tool_use`) across all providers.

**Fixed: Ollama model prefix stripping** — Requests using the `ollama/` model prefix (e.g. `ollama/llama3.2`) now correctly strip the prefix before forwarding to the Ollama API. Previously the prefix was forwarded verbatim, causing model-not-found errors.

**New: Weighted load-balancing** — Routing rules support weighted distribution across multiple providers. Traffic that exceeds a provider's weight is automatically routed to the next entry in the fallback chain.

**New: Per-provider circuit breaker** — After a configurable failure threshold is crossed, the gateway stops routing to the failing provider for a cooldown period before retrying.

---

## Playground

**New: Web search** — The Playground includes a web search toggle. When enabled, the gateway performs a live search and injects results into the model context before responding. A "searched" badge is shown on responses that used web search.

**Fixed: Web search empty results** — Search snippets that were empty or whitespace-only are now skipped; the page description is used as fallback.

**New: Filter non-runnable models** — The model picker can be filtered to show only models with a configured API key, reducing noise in large setups.

**New: Gemini native grounding** — Gemini models use the built-in grounding feature of Google when web search is enabled, rather than the Brave Search path.

---

## Security & guardrails

**New: Human-readable block messages** — Guardrail block responses now include the human-readable harm category name (e.g. "Violent Crimes") alongside the category code (e.g. `S2`).

**New: Anthropic tool use on compat endpoint** — OpenAI-format `tool_calls` sent via the compat endpoint to Anthropic are now automatically converted to the native `tool_use` format of Anthropic.

---

## See also

- [Gateway Configuration Reference](config-reference.md)
- [Stats API](../api-reference/stats.md)
- [Routing Rules API](../api-reference/routing-rules.md)
- [Guardrail Pipeline](../security/guardrails.md)
- [Glossary](glossary.md)
