# Claude.ai vs Our Chat Window — Gap Analysis

**Scope:** What Claude.ai (claude.ai web app) offers that our Chat Console UI (`/chat`) does not yet implement.

Each feature is rated on two axes:

- **Importance** — `critical` / `high` / `medium` / `low` from an enterprise user's perspective
- **Effort** — estimated engineering days (backend + frontend combined, single experienced developer)

---

## Table of Contents

1. [Projects](#1-projects)
2. [Skills (Slash Commands + Integrations + MCP)](#2-skills-slash-commands--integrations--mcp)
3. [Memory System](#3-memory-system)
4. [Artifacts — Enhanced Capabilities](#4-artifacts--enhanced-capabilities)
5. [Conversation Sharing & Cowork (Team Collaboration)](#5-conversation-sharing--cowork-team-collaboration)
6. [Extended Thinking Toggle](#6-extended-thinking-toggle)
7. [Conversation Organization (Starred, Archived, Semantic Search)](#7-conversation-organization-starred-archived-semantic-search)
8. [Message Branching](#8-message-branching)
9. [Feedback & Reactions](#9-feedback--reactions)
10. [Model Switching Mid-Conversation](#10-model-switching-mid-conversation)
11. [Agent Orchestration (Claude Code Teams)](#11-agent-orchestration-claude-code-teams)
12. [Minor UX Gaps](#12-minor-ux-gaps)
12a. [Our Differentiators (not in Claude.ai)](#12a-our-differentiators-not-in-claudeai)
13. [Summary Table](#13-summary-table)

---

## 1. Projects

**Importance: critical | Effort: ~15–20 days | ✅ SHIPPED**

### What Claude.ai does

Projects are the central organizational primitive in Claude.ai. A Project is a named container that groups related conversations under a shared persistent context. Every conversation created inside a project automatically inherits:

1. **Project Instructions** — a dedicated system prompt that is prepended to every conversation in the project. Unlike a per-conversation system prompt, project instructions are edited once and apply everywhere. Users use this for role definition ("You are a senior Python engineer helping our team…"), constraints, output format rules, and company context.

2. **Project Knowledge** — a document store attached to the project. Users upload PDFs, `.txt`, `.md`, code files, Google Docs links, or web pages. Claude reads the knowledge base as part of every conversation context window — no manual pasting required. Knowledge files are visible in the UI as a browsable list with upload/delete controls.

3. **Shared conversations** — in the Teams/Enterprise tier, multiple users can see and contribute to a project's conversation list. The project becomes a shared AI workspace rather than a personal chat history.

Projects appear as a top-level item in the left sidebar above individual conversations. Clicking a project shows the project instructions, the knowledge base, and the list of conversations grouped under it. Starting a new conversation from within a project pre-loads the project context automatically.

### What we have

**Fully shipped.** Backend: `admin/projects.lua` with full CRUD (`GET/POST/PATCH/DELETE /projects`, `/projects/{id}/members`, `/projects/{id}/knowledge`, `/projects/{id}/conversations`). Frontend: `Projects.tsx` list/detail page, `ProjectCreateModal`, `ProjectDetail` panel, `KnowledgePanel` with drag-and-drop upload, `MembersDrawer` for role management. Project instructions are injected into every conversation that belongs to the project; knowledge files are prepended as context.

### Remaining gaps vs Claude.ai

- "Move conversation to project" context menu action (the API exists; UI not yet wired)
- Project knowledge file chips shown in the chat input bar when the active conversation is inside a project

---

## 2. Skills (Slash Commands + Integrations + MCP)

**Importance: high | Effort: ~12–18 days**

### What Claude.ai does

The word "skills" spans three related but distinct features in the Claude ecosystem:

#### 2a. Slash Commands (prompt templates) — ✅ SHIPPED

Typing `/` in the chat input opens an autocomplete menu of saved prompt templates. Each slash command has a short name, a description, and a template body that may include `{{placeholder}}` variables. Selecting a command fills the input box with the expanded template, which the user can edit before sending. Users can define their own commands; admins can define organization-wide commands.

Example: `/summarize` → `Summarize the following in 3 bullet points:\n\n{{text}}`

This is distinct from our current presets (which set the whole conversation configuration) — slash commands are per-message prompt shortcuts.

**Shipped implementation:** Commands are stored as JSON on the tenant record (`slash_commands` field). The chat input intercepts `/` and renders a `CommandPicker` autocomplete popover; selecting a command with `{{variable}}` placeholders opens a `VariableFillModal` for tab-navigable placeholder filling before insertion. A dedicated `Commands.tsx` management page lives in the admin sidebar. Scope is tenant-wide (not per-user personal commands — that remains a gap vs Claude.ai).

#### 2b. Integrations (native connectors to external services)

Claude.ai Teams/Enterprise offers pre-built integrations activated at the project or workspace level:

| Integration | What it provides |
|---|---|
| Google Drive | Browse/attach documents directly from Drive without downloading |
| Google Docs/Sheets | Live doc context; Claude can read current content |
| GitHub | Attach repo files or GitHub issues as context |
| Jira | Attach ticket content |
| Confluence | Attach pages from Confluence |
| Slack | Context from Slack threads (read-only) |
| Zapier / Make | Trigger workflows from chat |

When activated, these appear as attachment-type buttons in the chat input toolbar. The integration fetches content server-side and injects it into the conversation context — the user does not need to manually export or copy.

#### 2c. Model Context Protocol (MCP) — local tools

Claude.ai desktop supports connecting arbitrary local MCP servers. An MCP server is a process (local or remote) that exposes tools Claude can call. This is the Anthropic-defined open standard for extending Claude with custom capabilities: file system access, database queries, custom API calls, browser control, etc.

In claude.ai web, MCP connections are configured per-user. Once connected, the tool names appear alongside web search in the tool-use status bar. Claude decides autonomously when to call them.

Our gateway's anthropic provider already forwards native tool calls and surfaces `aig_tool_call` SSE events. What we lack is the UI layer to configure and display MCP connections in the Chat interface.

#### 2d. Skills (Claude Code CLI context)

In the Claude Code CLI, skills are markdown files in `.claude/commands/` that define invocable `/skill-name` prompts. They are the CLI equivalent of slash commands — reusable prompt fragments that can be triggered by name. This is not directly in the chat UI but the concept should map to our slash commands implementation.

### What we have

We have presets (whole-conversation configuration templates), file attachments, and the server-side `x-aig-skill` header for DOCX/XLSX/PPTX/PDF processing (Anthropic Skills API). **Slash commands are now shipped** (tenant-wide `/` autocomplete with `{{variable}}` support). We do not have per-user personal commands, external service connectors, or MCP configuration in the UI.

### Why it matters

- **Slash commands** dramatically reduce repetitive typing for power users and teams. A customer support team that uses the same 10 prompt patterns daily will see 5–10× productivity improvement.
- **Integrations** eliminate the "copy from Jira / paste to Claude / copy back" loop that plagues enterprise AI adoption. They turn our chat into a connected workflow tool rather than an isolated chat box.
- **MCP** is the Anthropic open standard that the entire Claude Code ecosystem (and many third-party tools) is building on. Not supporting it in the chat UI creates a capability gap compared to the CLI experience.

### Implementation plan

**Slash commands — ✅ SHIPPED (~4 days as estimated)**

Implemented as tenant-level JSON on the `tenants` table (not a separate `chat_commands` table). Management via the Commands admin page. Chat input intercepts `/`, shows `CommandPicker` popover, `VariableFillModal` handles `{{placeholder}}` expansion. Remaining gap: per-user personal commands (currently commands are tenant-wide only).

**External integrations — ~10 days each for major connectors**

Each connector is a server-side OAuth flow + a content-fetch adapter. Architecture:

1. `integration_tokens` table: `(user_id, provider, access_token_enc, refresh_token_enc, expires_at)`
2. Per-provider adapter in a new `src/integrations/` directory: `google_drive.lua`, `github.lua`, `jira.lua` — each exposes `list_files(query)` and `get_content(file_id)`
3. New admin API routes: `GET/POST /integrations/connect/{provider}` (OAuth redirect), `GET /integrations/{provider}/files?q=`
4. Frontend: toolbar button per connected integration; file browser modal; selected files appear as attachment chips

Priority order: GitHub (developer audience) → Google Drive (universal) → Jira (enterprise workflow).

**MCP configuration UI — ~5 days**

The gateway already handles MCP tool calls at the model level (via native Anthropic tool use). The missing piece is a settings panel where users can register named MCP server endpoints (URL, auth header, tool list description) that are stored per-user and sent as pre-loaded tools in the system context or as tool definitions injected by the gateway.

---

## 3. Memory System

**Importance: high | Effort: ~8–10 days**

### What Claude.ai does

Claude.ai has a two-tier memory system:

**Automatic memory** — During conversations, Claude proactively identifies facts worth remembering and saves them without being asked: user's name, job title, preferred programming language, time zone, project names, technical stack, recurring preferences. These appear in a "Memories" panel accessible from the user profile. They are injected into subsequent conversations as a prepended context block.

**Manual memory** — The user can say "Remember that I prefer TypeScript over JavaScript" and Claude stores it. The user can also open the Memories panel and add/edit/delete individual memory items at any time.

**Memory scoping** — Memories are per-user and cross-conversation (not scoped to a project or gateway). They are injected automatically into every new conversation.

Memory entries look like:
```
- Prefers concise, technical answers without preamble
- Working language: Python 3.12 with type hints
- Project name: "Orion" (internal analytics platform)
- Team: Platform Engineering at Acme Corp
```

### What we have

Nothing. Each conversation starts cold. The only persistent context available is the project system prompt (which we don't have yet) or manually pasted information.

### Why it matters

Memory is what transforms Claude from a stateless chatbot into a persistent AI collaborator. Without it, power users must re-introduce themselves and their preferences in every conversation. For enterprise users who chat dozens of times daily, this is a significant friction point. Memory also enables personalization across gateways and models — since memories are user-level, they apply regardless of which model the user selects.

Note: Memory interacts with Projects — in Claude.ai, memories are injected alongside project instructions, building a rich automatically-maintained context.

### Implementation plan

**Backend — ~5 days**

```sql
user_memories (
  id TEXT PK, user_id TEXT FK, content TEXT,
  source TEXT,          -- 'auto' | 'manual'
  created_at INTEGER, updated_at INTEGER, deleted_at INTEGER
)
```

API: `GET/POST /memories` (list + create), `PATCH/DELETE /memories/{id}`.

Memory injection: in `admin/api.lua`'s conversation message handler, load the user's active memories and prepend them to the system prompt as a `<memory>` block (or as a separate user-role system message in Anthropic format) before forwarding to the gateway.

Auto-memory extraction: after each assistant turn, fire an `ngx.timer.at` background request to the same model with a short extraction prompt ("Extract any user facts or preferences from this exchange as a JSON array"). If the result is non-empty, upsert into `user_memories`. Deduplication guard: SHA-256 the content before inserting.

**Frontend — ~3 days**

- "Memories" section in the sidebar or user profile dropdown
- List view: show all memories with timestamp, source badge (auto/manual), delete button
- "Add memory" form (plain text)
- Per-conversation opt-out toggle ("Don't use memories in this conversation")
- Toast notification when a memory is auto-saved: "💾 Remembered: you prefer TypeScript"

---

## 4. Artifacts — Enhanced Capabilities

**Importance: high | Effort: ~8–12 days**

### What Claude.ai does beyond our current artifact panel

Our artifact panel shows a sandboxed `<iframe>` for HTML/SVG blocks ≥ 8 lines. Claude.ai's artifact system is significantly more capable:

#### 4a. Multiple artifacts per conversation

Claude.ai maintains a persistent artifact panel on the right side of the conversation. Each distinct artifact (code file, document, HTML preview) is listed as a tab. Multiple artifacts can exist simultaneously and remain accessible as the conversation scrolls — they are not tied to the specific message that generated them.

We currently show only the most-recent HTML/SVG artifact and dismiss it on Dismiss button click.

#### 4b. Artifact versioning

Each time Claude revises an artifact (updates code, improves a document), Claude.ai creates a new version. A version history indicator (`v1 → v2 → v3`) appears at the bottom of the artifact panel. Users can navigate back to any prior version, compare them, or fork from an older version.

We have no versioning.

#### 4c. Inline artifact editing ("Improve" / "Fix" buttons)

Claude.ai shows action buttons overlaid on the artifact: **Improve**, **Fix issue**, **Update**. Clicking "Fix issue" opens a floating text field where the user describes the change; Claude applies the diff directly to the artifact without re-reading the whole conversation, and the artifact updates in-place.

We have no editing — the user must ask in the chat input and Claude regenerates the whole message.

#### 4d. React component rendering

Beyond HTML/SVG, Claude.ai can render interactive React components in a sandboxed environment. The artifact type `application/vnd.ant.react` is supported with a limited subset of React hooks and Tailwind CSS. This enables Claude to generate live UI mockups, interactive data visualizations, and mini-apps.

We currently only support HTML/SVG (no React runtime in the iframe).

#### 4e. Code artifact with syntax highlight and run button

`application/vnd.ant.code` artifacts display syntax-highlighted code with a "Copy" button. For Python specifically, Claude.ai (via code execution beta) can run the code in a sandboxed container and display stdout/stderr inline in the artifact panel.

We have code blocks with syntax highlighting and copy buttons in the message stream, but no separate artifact panel for pure code, and no execution.

#### 4f. Document artifacts

`application/vnd.ant.markdown` artifacts display rich Markdown documents (longer form output — essays, reports, READMEs) in a focused reading pane separate from the conversation thread. Editing the document opens a split view.

### Implementation plan

**Multiple artifacts + panel persistence — ~3 days**
Extract artifact state from "most recent HTML block" to an array per conversation. Render as tabs in the artifact panel. Scroll-independence: the panel persists as a fixed right-side pane even as the message thread scrolls.

**Artifact versioning — ~2 days**
Add `artifact_versions` array per artifact (stored in conversation message metadata). Version navigation controls (prev/next chevrons, version counter).

**Inline editing / Improve button — ~3 days**
Floating edit bar with text input. On submit, send a system-injected message: `Update the artifact: {user instruction}`. Gate the request to include only the artifact content as context (not the full conversation) for efficiency.

**React rendering — ~4 days**
Ship a small static bundle containing React 18, ReactDOM, and Tailwind CDN into the iframe sandbox. Claude's output is evaluated as a module. Security constraints: no `fetch`, no `window.open`, no `localStorage`. Add a new code fence language tag `react` that triggers this renderer instead of the HTML renderer.

---

## 5. Conversation Sharing & Cowork (Team Collaboration)

**Importance: high | Effort: ~10–15 days**

### What Claude.ai does

#### 5a. Conversation sharing (public read-only links)

Any conversation can be shared as a snapshot. Clicking "Share" generates a public URL (`claude.ai/share/...`) that shows the full conversation in a read-only view — no login required for the recipient. The snapshot is taken at the moment of sharing; subsequent messages are not reflected unless the user re-shares.

This is a lightweight but extremely useful feature for: sharing AI-generated reports with stakeholders, showing a debugging session to a colleague, citing a Claude output in documentation.

#### 5b. Cowork (real-time collaborative sessions)

Announced in early 2026, Cowork allows multiple Claude.ai users to join the same conversation simultaneously. One user is the "driver" (can type and submit); others are "observers" who see the conversation update live. Any participant can take the driver seat. This is analogous to Google Docs collaboration but for AI conversations.

Cowork sessions are ephemeral (not stored as normal conversations) and require all participants to have Claude.ai accounts.

#### 5c. Project sharing (Teams tier)

Within a team workspace, projects are shared at the organization level. All team members with access see the same project knowledge base and conversation list. Project instructions can only be edited by the project owner or organization admins.

### What we have

No sharing. Conversations are private to the creating user.

### Why it matters

Conversation sharing is a zero-cost viral growth driver — every shared link is a marketing touchpoint. For enterprise customers, the ability to share an AI-generated analysis or action plan with people outside the AI gateway is critical; it replaces "copy to email" with a clean hosted view.

Cowork is more complex but addresses the "we're having a meeting and want to use AI together" scenario that currently forces one person to share their screen.

### Implementation plan

**Conversation sharing — ~4 days**

Add `share_token TEXT UNIQUE` column to `conversations`. Generate on `POST /conversations/{id}/share`; nullify on `DELETE /conversations/{id}/share`.

New public route (no auth): `GET /share/{token}` — returns conversation title + messages (sanitized: strip system prompts, strip cost/token metadata). Render as a simple read-only chat view with no input box; "Open in Chat" button for logged-in users.

Frontend: "Share" button in the conversation header → modal showing the share URL with copy button and "Revoke" option.

**Cowork — ~8–10 days**

Real-time multi-user sessions require a WebSocket or SSE broadcast channel. Architecture:

1. `cowork_sessions` table: `(id, conversation_id, host_user_id, started_at, ended_at)`
2. `cowork_participants` table: `(session_id, user_id, joined_at, is_driver)`
3. A lightweight Nginx-side pub/sub: incoming messages from the driver are broadcast to all participants via `ngx.shared.dict` + long-poll or a Redis pub/sub channel
4. Frontend: "Start Cowork" button generates an invite link. Participants see a live-updating conversation view. Driver indicator ("Alice is typing…") shown above the input box; non-drivers see a "Request driver" button.

---

## 6. Extended Thinking Toggle

**Importance: medium | Effort: ~2 days**

### What Claude.ai does

Claude.ai shows a "Extended thinking" toggle (or a "Think" button on Claude 3.7+/4.x) directly in the chat input toolbar. Clicking it appends `anthropic-beta: interleaved-thinking-2025-05-14` and injects `"thinking": {"type": "enabled", "budget_tokens": 10000}` into the request body. The chat UI shows the thinking block as a collapsible "Thought process" panel above the response (which we already render).

Claude.ai also auto-detects when a model supports thinking and only shows the toggle for capable models.

### What we have

Users can enable extended thinking by adding `x-aig-provider-anthropic-beta: interleaved-thinking-2025-05-14` as a manual header override. The `<think>` rendering is in place. There is no UI toggle.

### Implementation plan

**~2 days**

- In the configuration bar, add a "Think" toggle button (lightbulb icon, shown only when the selected model is `claude-*-sonnet-4-*` or later)
- When enabled: store `extendedThinking: true` in conversation state; inject `x-aig-provider-anthropic-beta: interleaved-thinking-2025-05-14` header on send + add `thinking: {type: "enabled", budget_tokens: N}` to the request body (configurable via a `thinkingBudget` settings field, default 10000)
- The existing thinking-block rendering handles display

---

## 7. Conversation Organization (Starred, Archived, Semantic Search)

**Importance: medium | Effort: ~5–7 days**

### What Claude.ai does

**Starring** — a star icon on each conversation pins it to a "Starred" section at the top of the sidebar. Starred conversations are exempt from auto-archiving.

**Archiving** — conversations not interacted with for 30 days are automatically moved to an "Archive" section (collapsed by default). Users can manually archive/unarchive. Archived conversations still appear in search but not in the main list.

**Semantic search** — the search bar in the sidebar uses vector similarity to find conversations by topic, not just by title keyword. A search for "AWS deployment issue" finds conversations where the title says "prod problem Tuesday" if the content is about AWS.

**Conversation pinning inside a project** — within a project, specific conversations can be pinned to the top of the project's conversation list.

### What we have

Title-only text search (`LIKE '%q%'` SQL query on the `conversations` table). No starring, no archiving, no semantic indexing.

### Why it matters

As conversation history grows to hundreds of entries, discoverability degrades rapidly. Starring and archiving are basic housekeeping features users expect from any modern app. Semantic search is the feature that justifies storing conversation history at all — without it, users cannot find old conversations by what was discussed.

### Implementation plan

**Starring and archiving — ~2 days**

Add `starred BOOLEAN DEFAULT 0` and `archived_at INTEGER` columns to `conversations`. API: `PATCH /conversations/{id}` already exists — add these fields. Frontend: star icon in the conversation list item; "Archive" in the context menu; sidebar sections "Starred" and "Archive".

**Semantic search — ~5 days**

Reuse the existing semantic cache infrastructure. On conversation completion (or message save), fire an `ngx.timer.at` background request to the configured embedding API to embed the conversation title + first user message. Store in a `conversation_embeddings` table. On search, if the query is non-empty embed it and cosine-search the table; merge results with SQL `LIKE` title search, deduplicate. Return a ranked list.

This requires the embedding API to be configured (same as the semantic cache feature, which already has a UI for it).

---

## 8. Message Branching

**Importance: medium | Effort: ~6–8 days**

### What Claude.ai does

When a user edits a past message, Claude.ai creates a **branch** — a parallel version of the conversation from that point forward. The original messages are preserved; the edited version generates new responses. At the branch point, a left/right navigation control (`< 1/2 >`) appears in the message bubble, letting the user switch between the original and the edited branch.

This makes conversation editing non-destructive. Users can explore "what if I had asked differently" without losing the original answer.

We currently implement editing as a destructive in-place update: editing a user message overwrites the original and deletes all subsequent messages.

### Why it matters

For research and writing workflows, branching is essential. A user drafting an email with Claude's help might want to compare a formal version vs a casual version without manually re-running both. Branching enables this at zero extra typing cost.

### Implementation plan

**~6–8 days**

Change the `messages` schema: add `parent_message_id TEXT` (null = root) and `branch_index INTEGER`. A message is the "canonical" version if `branch_index = 0`; alternate branches have `branch_index > 0`.

`PATCH /conversations/{id}/messages/{mid}` with `content` now creates a new message row with the same `parent_message_id` and `branch_index = max(branch_index)+1` rather than mutating the existing row. The response continues from the new branch message.

Frontend: render branch navigation controls at the edit point. Load the canonical branch by default; switching branches loads the alternate message chain from that point. The branch selector only appears at messages where `max(branch_index) > 0`.

---

## 9. Feedback & Reactions

**Importance: low–medium | Effort: ~3 days**

### What Claude.ai does

**Per-message thumbs up / thumbs down** — each assistant message has a 👍/👎 pair. Clicking one opens an optional free-text comment field ("What was wrong?"). This feedback is sent to Anthropic for model improvement.

**Regeneration with feedback** — the "Regenerate" button (which we have) in Claude.ai shows a dropdown: "Regenerate" (neutral), "Regenerate — too long", "Regenerate — too short", "Regenerate — too formal", etc. The selected reason is appended to a hidden re-run instruction.

### What we have

We have a Regenerate button (deletes last assistant message, re-runs) and a feedback modal accessible from the conversation settings (star rating 1–5 + comment stored in the DB). There is no per-message feedback and no reason-annotated regeneration.

### Implementation plan

**Per-message feedback — ~2 days**

Add `feedback` JSON column to `messages`. `PATCH /conversations/{id}/messages/{mid}` accepts `{"feedback": {"rating": "up"|"down", "comment": "..."}}`. Frontend: thumbs icons visible on assistant message hover; comment popover on click.

**Reason-annotated regeneration — ~1 day**

Extend the Regenerate button into a split button with a dropdown of preset reasons. Prepend the selected reason as a hidden system message before the re-run.

---

## 10. Model Switching Mid-Conversation

**Importance: low–medium | Effort: ~1 day**

### What Claude.ai does

Claude.ai allows switching models mid-conversation (e.g. from Haiku to Sonnet) at any point. The new model sees the full conversation history — the switch takes effect from the next user message. A banner shows which model generated each message when the model changed during the conversation.

### What we have

Model switching is available via the configuration bar dropdown but only before starting a new conversation or at the start. The UI does not prevent or warn when switching mid-stream.

### Implementation plan

Allow `PATCH /conversations/{id}` to change `model` at any time (already allowed at the DB level). Frontend: show per-message model badge when the model differs from the current setting (compare `message.model` against `conversation.model`). Grey separator line between model-switch points.

---

## 11. Agent Orchestration (Claude Code Teams)

**Importance: medium (developer-focused) | Effort: ~20–30 days**

### What Claude.ai does

Claude Code (the CLI product) has an **agent teams** mode where one orchestrator Claude instance spins up multiple sub-agents, each working on a sub-task in parallel, with results aggregated by the orchestrator. This is not in the claude.ai web UI directly, but the claude.ai interface increasingly exposes long-running agentic tasks:

- **Tasks panel** — shows active and completed multi-step Claude Code sessions, their status (running/paused/done), and allows interrupting or resuming
- **Background agents** — a Claude Code agent can run in the background while the user continues chatting; a notification appears when the task completes
- **Tool call audit trail** — the UI shows every tool call made during an agentic session (files read, commands run, web searches) as an expandable list

### What we have

Our gateway supports native Anthropic tool use and surfaces `aig_tool_call` SSE events. The Chat UI shows live tool-use status labels. We do not have multi-step agentic task management, task history, or sub-agent orchestration.

### Why it matters

Agentic tasks that run for minutes or hours (code review across a repository, data pipeline validation, document generation from a knowledge base) require a different UX than turn-by-turn chat. This is emerging functionality even in claude.ai — the gap here is less acute today but will widen rapidly through 2026.

### Implementation plan

This is a significant greenfield feature. High-level architecture:

1. `agent_tasks` table: `(id, conversation_id, status, tool_calls JSON, created_at, completed_at)`
2. A long-running task endpoint: `POST /conversations/{id}/tasks` — accepts a goal; starts a background `ngx.timer` loop that runs the agentic chain, persisting each tool call and intermediate message
3. Task status streaming: `GET /conversations/{id}/tasks/{tid}/events` (SSE) — pushes each tool call, each intermediate message, and the final result
4. Frontend: "Tasks" panel in the chat sidebar showing running and completed tasks; each task expands to show the tool call audit trail; cancel/resume buttons

---

## 12. Minor UX Gaps

These are individually small but collectively important for product polish.

| Feature | Effort | Description |
|---|---|---|
| **Conversation pinning** | 0.5 d | Pin up to 5 conversations to sidebar top regardless of recency |
| **Keyboard shortcuts** | 1 d | `Cmd+K` new conversation, `Cmd+/` focus input, `Cmd+E` edit last message |
| **Dark/light mode per-user** | 1 d | User preference stored in profile (we only have a global CSS variable) |
| **Mobile-responsive layout** | 3–4 d | Sidebar collapses to a drawer on small viewports; input area is tap-friendly |
| **Token/cost usage summary** | 1 d | Per-conversation total token and cost rollup displayed in conversation header |
| **"Continue in new conversation"** | 0.5 d | Button to start a new conversation pre-populated with a summary of the current one |
| **Smart reply suggestions** | 2 d | After each assistant message, show 2–3 suggested follow-up prompt chips |
| **Message copy as Markdown/HTML** | 0.5 d | Copy button dropdown: "Copy as Markdown" or "Copy as HTML" |
| **Interrupted stream recovery** | 2 d | If SSE connection drops mid-stream, auto-retry from last received token (resume header) |
| **Notification on background response** | 1 d | Browser notification when a background-streaming conversation completes |

---

## 12a. Our Differentiators (not in Claude.ai)

Features we ship that Claude.ai does not offer:

| Feature | Description |
|---|---|
| **Ghost mode** | Ephemeral chat toggle (👻) — no DB writes, no request log, no attachment storage. Unique privacy feature for sensitive conversations. Claude.ai has no equivalent. |
| **Multi-provider routing** | Any conversation can transparently route to 22 providers (OpenAI, Anthropic, Gemini, Bedrock, vLLM, Ollama, …) with automatic fallback, load balancing, and circuit breaker — all within the same chat UI. Claude.ai is Claude-only. |
| **Cost visibility** | Per-message token count + cost (USD) shown inline. Budget caps enforced at gateway level. Claude.ai shows no cost information. |
| **Bring Your Own Key** | Users/tenants supply their own provider API keys. Claude.ai has no BYOK concept. |
| **Admin observability** | Full request logs, Prometheus metrics, SIEM integration, OTel tracing. Enterprise-grade audit trail Claude.ai does not expose. |
| **On-premise / self-hosted** | The entire stack (including Chat UI) runs in a Docker container on private infrastructure. Claude.ai requires a cloud account. |

---

## 13. Summary Table

| Feature | Claude.ai | Us | Importance | Effort |
|---|---|---|---|---|
| **Projects** (grouping, knowledge base, shared instructions) | ✅ | ✅ | critical | ~~15–20 d~~ shipped |
| **Slash commands** (per-message prompt templates) | ✅ | ✅ (tenant-wide) | high | ~~4 d~~ shipped |
| **Ghost mode** (ephemeral no-log chat) | ❌ | ✅ | medium | shipped — our differentiator |
| **Memory system** (auto + manual, cross-conversation) | ✅ | ✅ | high | ~~8–10 d~~ shipped |
| **Conversation share links** | ✅ | ✅ | high | ~~4 d~~ shipped |
| **Conversation starring + archiving** | ✅ | ✅ | medium | ~~2 d~~ shipped |
| **Extended thinking toggle** | ✅ | ✅ | medium | ~~2 d~~ shipped |
| **Semantic conversation search** | ✅ | ✅ | medium | ~~5 d~~ shipped |
| **External integrations** (GitHub, Drive, Jira…) | ✅ | ❌ | high | 10–15 d each |
| **MCP server connections** | ✅ | ❌ | high | 5 d |
| **Multiple artifacts + persistence** | ✅ | partial | high | 3 d |
| **Artifact versioning** | ✅ | ❌ | high | 2 d |
| **Artifact inline editing** | ✅ | ❌ | high | 3 d |
| **React component rendering** | ✅ | ❌ | medium | 4 d |
| **Cowork (real-time collaboration)** | ✅ | ❌ | high | 8–10 d |
| **Message branching** | ✅ | ❌ | medium | 6–8 d |
| **Per-message feedback** | ✅ | ❌ | low–medium | 2 d |
| **Reason-annotated regeneration** | ✅ | ❌ | low | 1 d |
| **Model badge per message** | ✅ | ❌ | low | 1 d |
| **Agent task panel** | ✅ | ❌ | medium | 20–30 d |
| **Mobile-responsive layout** | ✅ | ❌ | medium | 3–4 d |
| **Keyboard shortcuts** | ✅ | partial | medium | 1 d |
| **Smart reply suggestions** | ✅ | ❌ | low | 2 d |

### Priority order for implementation

**Phase 1 — Structural:** ✅ **COMPLETE**
1. ~~Projects (~15–20 d)~~ ✅ **SHIPPED**
2. ~~Memory (~8–10 d)~~ ✅ **SHIPPED**

**Phase 2 — Collaboration and discovery:** ✅ **COMPLETE**
3. ~~Conversation share links (~4 d)~~ ✅ **SHIPPED**
4. ~~Slash commands (~4 d)~~ ✅ **SHIPPED** (tenant-wide; per-user personal commands still outstanding)
5. ~~Starring + archiving (~2 d)~~ ✅ **SHIPPED**
6. ~~Semantic search (~5 d)~~ ✅ **SHIPPED**
7. ~~Extended thinking toggle (~2 d)~~ ✅ **SHIPPED**

**Phase 3 — Artifact and interaction depth:**
8. Multi-artifact panel + versioning (~5 d combined)
9. Artifact inline editing (~3 d)
10. Message branching (~6–8 d)

**Phase 4 — Integrations and agent workflows:**
11. GitHub integration (~10 d) — highest value for our developer audience
12. MCP server connection UI (~5 d)
13. Google Drive integration (~10 d)
14. Agent task panel (~20–30 d) — long runway; begin architecture now

**Total estimated effort to reach feature parity with Claude.ai web:**
~~130–160~~ → ~~110–130~~ → now **~85–100 engineering-days** remaining.
~~60–70~~ → ~~45–50~~ → now **~25–30 days** to reach the most impactful remaining scope (Artifacts + Integrations).
