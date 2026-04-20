import { useCallback, useEffect, useRef, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { api } from "src/api/client";
import type {
  ChatConversation,
  ChatFeedback,
  ChatMemory,
  ChatMessage,
  ChatPreset,
  ChatProject,
  ConversationSummary,
  Gateway,
  McpConnector,
  McpTool,
  ModelPrice,
  PlaygroundToken,
  ProjectKnowledgeText,
  ProviderMeta,
  SlashCommand,
  Tenant,
  TenantPreset,
} from "src/api/types";
import ModelPicker from "src/common/components/ModelPicker/ModelPicker";
import s from "src/common/components/layout/Layout.module.scss";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { useWakeLock } from "src/common/hooks/useWakeLock";
import { useAuth } from "src/common/contexts/AuthContext";
import ChatInput, { type ChatInputHandle, type PendingAttachment } from "../components/ChatInput";
import ConversationList from "../components/ConversationList";
import MessageThread from "../components/MessageThread";
import SettingsDrawer, { type DrawerSettings } from "../components/SettingsDrawer";
import ArtifactPanel, { type Artifact } from "../components/ArtifactPanel";
import { Modal } from "src/common/components/Modal";
import { VariableFillModal } from "../components/VariableFillModal";
import MemoriesPanel from "../components/MemoriesPanel";
import { ProjectFilePreview } from "src/modules/projects/components/ProjectFilePreview";
import chatS from "./Chat.module.scss";

// ── Gear icon ──────────────────────────────────────────────────────────────
function GearIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
    </svg>
  );
}

function DownloadIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4" />
      <polyline points="7 10 12 15 17 10" />
      <line x1="12" y1="15" x2="12" y2="3" />
    </svg>
  );
}
function GlobeIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="12" cy="12" r="10" />
      <line x1="2" y1="12" x2="22" y2="12" />
      <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" />
    </svg>
  );
}

function PdfIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
      <polyline points="14 2 14 8 20 8" />
      <line x1="9" y1="15" x2="15" y2="15" />
      <line x1="9" y1="11" x2="11" y2="11" />
    </svg>
  );
}

function FlagIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M4 15s1-1 4-1 5 2 8 2 4-1 4-1V3s-1 1-4 1-5-2-8-2-4 1-4 1z" />
      <line x1="4" y1="22" x2="4" y2="15" />
    </svg>
  );
}

function ShareIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="18" cy="5" r="3" />
      <circle cx="6" cy="12" r="3" />
      <circle cx="18" cy="19" r="3" />
      <line x1="8.59" y1="13.51" x2="15.42" y2="17.49" />
      <line x1="15.41" y1="6.51" x2="8.59" y2="10.49" />
    </svg>
  );
}

function ClipboardIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  );
}

function MemoryIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 2a7 7 0 0 1 7 7c0 2.38-1.19 4.47-3 5.74V17a2 2 0 0 1-2 2h-4a2 2 0 0 1-2-2v-2.26A7 7 0 0 1 12 2z" />
      <line x1="10" y1="20" x2="14" y2="20" />
      <line x1="10" y1="22" x2="14" y2="22" />
    </svg>
  );
}

const GATEWAY_URL = import.meta.env.VITE_GATEWAY_URL ?? "";

/** Derive a human-readable AI label from a model string.
 *  Returns e.g. "Claude (claude-sonnet-4-6)" or "Qwen (qwen3-30b-a3b)". */
function aiLabel(model: string): string {
  const m = model.toLowerCase();
  let name: string;
  if (m.startsWith("claude"))        name = "Claude";
  else if (m.startsWith("gpt") || m.startsWith("o1") || m.startsWith("o3")) name = "GPT";
  else if (m.startsWith("gemini"))   name = "Gemini";
  else if (m.startsWith("qwen"))     name = "Qwen";
  else if (m.startsWith("llama"))    name = "Llama";
  else if (m.startsWith("mistral"))  name = "Mistral";
  else                               name = "Assistant";
  return model ? `${name} (${model})` : name;
}

/** Models that support native vision (image_url blocks) via vLLM.
 *  Text-only models not listed here have images routed through MinerU instead.
 *  Extend this set as vision-capable models are deployed. */
const VLLM_VISION_MODELS = new Set<string>([
  // e.g. "qwen2.5-vl-7b-instruct",
]);

/**
 * Approximate context window size for a model.
 * Used to determine when to trigger context summarization.
 * Returns tokens; summarization fires at 75% of limit.
 */
function contextWindowTokens(model: string): number {
  const m = model.toLowerCase();
  if (m.startsWith("claude")) return 200_000;
  if (m.startsWith("gpt-4o") || m.startsWith("gpt-4-turbo")) return 128_000;
  if (m.startsWith("gpt-4")) return 128_000;
  if (m.startsWith("gpt-3.5")) return 16_000;
  if (m.startsWith("o1") || m.startsWith("o3")) return 128_000;
  if (m.startsWith("gemini-1.5") || m.startsWith("gemini-2")) return 1_000_000;
  if (m.startsWith("gemini")) return 128_000;
  // Local / vLLM models — conservative default
  return 32_000;
}

function isVisionCapable(model: string): boolean {
  const bare = model.startsWith("vllm/") ? model.slice(5) : model;
  return VLLM_VISION_MODELS.has(bare) || /[-_]vl[-_\d]/i.test(bare);
}

/** Build the system prompt for a project by combining instructions + knowledge files. */
function buildProjectSystemPrompt(project: ChatProject, knowledgeFiles: ProjectKnowledgeText[]): string {
  const parts: string[] = [];
  if (project.instructions) parts.push(project.instructions.trim());
  // Guide the model to annotate code blocks with filenames so they can be saved back
  parts.push(
    "When the user asks you to create or update a file, output it as a fenced code block " +
    "where the very first line INSIDE the code fence is a comment containing only the filename. " +
    "Do NOT put the filename as a heading or text outside/before the code block. " +
    "The filename comment must be literally the first line inside the fence. Examples:\n" +
    "```bash\n# check_ssh.sh\n#!/bin/sh\n...\n```\n" +
    "```typescript\n// api.ts\nexport const api = {};\n```\n" +
    "```sql\n-- schema.sql\nCREATE TABLE users (id INT);\n```"
  );
  if (knowledgeFiles.length > 0) {
    const fileList = knowledgeFiles.map((f) => `- ${f.filename}`).join("\n");
    parts.push(
      "## Project Knowledge Files\n\n" +
      "The following files are available in this project's knowledge base. " +
      "To read the full content of a file, emit exactly: <read_file>filename</read_file>\n\n" +
      fileList
    );
  }
  return parts.join("\n\n");
}

export default function Chat() {
  useDocumentTitle("Chat");

  const { user: me } = useAuth();
  const [searchParams, setSearchParams] = useSearchParams();

  // ── Project context (from ?project_id= URL param) ─────────────────────────
  const projectIdParam = searchParams.get("project_id");
  const convParam      = searchParams.get("conv");
  const [activeProject, setActiveProject] = useState<ChatProject | null>(null);
  const [projectKnowledge, setProjectKnowledge] = useState<ProjectKnowledgeText[]>([]);

  // ── Data ───────────────────────────────────────────────────────────────────
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [gateways, setGateways] = useState<Gateway[]>([]);
  const [models, setModels] = useState<ModelPrice[]>([]);
  const [providerMeta, setProviderMeta] = useState<ProviderMeta[]>([]);
  const [conversations, setConversations] = useState<ChatConversation[]>([]);
  const [showArchived, setShowArchived] = useState(false);
  const [presets, setPresets] = useState<ChatPreset[]>([]);

  // ── Config bar state (persisted to localStorage) ───────────────────────────
  const [tenantId, setTenantId] = useState(() => localStorage.getItem("aig-chat-tenant") ?? "");
  const [gatewayId, setGatewayId] = useState(() => localStorage.getItem("aig-chat-gateway") ?? "");
  const [model, setModel] = useState(() => localStorage.getItem("aig-chat-model") ?? "");
  const [selectedPresetId, setSelectedPresetId] = useState(() => localStorage.getItem("aig-chat-preset") ?? "");

  useEffect(() => { localStorage.setItem("aig-chat-tenant",  tenantId);  }, [tenantId]);
  useEffect(() => { localStorage.setItem("aig-chat-gateway", gatewayId); }, [gatewayId]);
  useEffect(() => { localStorage.setItem("aig-chat-model",   model);     }, [model]);
  useEffect(() => { localStorage.setItem("aig-chat-preset",  selectedPresetId); }, [selectedPresetId]);

  // Reset thinking budget when model changes to one that doesn't support it
  useEffect(() => {
    const modelEntry = models.find((m) => m.model === model);
    if (modelEntry && !modelEntry.supports_thinking) {
      setDrawerSettings((prev) => ({ ...prev, thinkingBudget: null }));
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [model, models]);

  // ── Active conversation ────────────────────────────────────────────────────
  const [activeConvId, setActiveConvId] = useState<string | null>(null);
  const activeConvIdRef = useRef<string | null>(null);
  useEffect(() => { activeConvIdRef.current = activeConvId; }, [activeConvId]);
  // Tracks which conversation ID is currently being fetched — prevents double-load
  // when onSelect calls setSearchParams+loadConversation and the effect fires a second time.
  const loadingConvRef = useRef<string | null>(null);
  const [messages, setMessages] = useState<ChatMessage[]>([]);

  // ── Settings drawer ────────────────────────────────────────────────────────
  const [showSettings, setShowSettings] = useState(false);

  // ── Mobile conversation list drawer ────────────────────────────────────────
  const [showConvList, setShowConvList] = useState(false);
  const DEFAULT_SYSTEM_PROMPT =
    "Today's date is " + new Date().toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" }) + ".\n\n" +
    "You are Claude, an AI assistant made by Anthropic.\n\n" +
    "Respond in the language the user writes in.\n\n" +
    "Formatting:\n" +
    "- Use markdown (headers, bold, lists, code blocks) when it genuinely aids clarity — not for simple conversational replies.\n" +
    "- Calibrate length to the question: short answers for simple questions, detailed answers for complex ones. Avoid padding.\n\n" +
    "Behavior:\n" +
    "- Be direct and confident. State your view clearly rather than hedging everything.\n" +
    "- If you're uncertain about a fact, say so — don't fabricate.\n" +
    "- For critical factual or technical claims (algorithms, API behaviour, benchmarks, statistics), cross-check against what you know from multiple angles before stating them. If sources conflict or confidence is low, say so explicitly rather than picking the more plausible-sounding answer.\n" +
    "- When the user's *intent* is ambiguous, make a reasonable assumption and proceed rather than asking multiple clarifying questions. Ask at most one follow-up question at the end if genuinely needed.\n" +
    "- Don't moralize or add unsolicited ethical commentary unless the topic directly calls for it.\n\n" +
    "Decision tables:\n" +
    "- When evaluating, comparing, or rating options across multiple dimensions or criteria (Bewertung), always present the results as a markdown table.\n" +
    "- Use ✅ (meets / strong), 🟡 (partial / acceptable), ❌ (does not meet / weak) as the rating symbols — never substitute with text or other symbols.\n" +
    "- Include a summary row or concluding sentence after the table.\n" +
    "- For priority, urgency, or risk level (Ampel / traffic light), use 🟢 (low / on track), 🟡 (medium / at risk), 🔴 (high / critical / blocked) — both inline and in tables.\n\n" +
    "Enumerated lists:\n" +
    "- When a numbered list covers distinct topics, categories, or properties, prefix each entry with a single emoji that iconically represents the subject of that specific item — not a generic or decorative one.\n" +
    "- The emoji goes immediately after the number and period: '1. 🐕 Beagles are scent hounds…', '2. 💤 Sleep contact is a warmth-seeking instinct…'\n" +
    "- Skip the emoji for purely procedural or sequential steps where the number implies order (installation steps, recipe instructions, numbered code steps).";

  const [drawerSettings, setDrawerSettings] = useState<DrawerSettings>({
    systemPrompt: DEFAULT_SYSTEM_PROMPT,
    temperature: 0.7,
    maxTokens: 8192,
    webSearch: false,
    thinkingBudget: null,
  });

  // ── Chat input ─────────────────────────────────────────────────────────────
  const chatInputRef = useRef<ChatInputHandle>(null);
  const focusInput = useCallback(() => { chatInputRef.current?.focus(); }, []);
  const [inputValue, setInputValue] = useState("");
  const [pendingAttachments, setPendingAttachments] = useState<PendingAttachment[]>([]);
  const [processingStatus, setProcessingStatus] = useState<string | null>(null);

  // ── Drag-and-drop ──────────────────────────────────────────────────────────
  const [isDragOver, setIsDragOver] = useState(false);
  const dragCounterRef = useRef(0);

  // ── Streaming state ────────────────────────────────────────────────────────
  const [isStreaming, setIsStreaming] = useState(false);
  useWakeLock(isStreaming);
  // Re-focus input when streaming ends (response complete or user stopped)
  const prevIsStreamingRef = useRef(false);
  useEffect(() => {
    if (prevIsStreamingRef.current && !isStreaming) focusInput();
    prevIsStreamingRef.current = isStreaming;
  }, [isStreaming, focusInput]);
  const [streamingContent, setStreamingContent] = useState<string | null>(null);
  const [streamingConvId, setStreamingConvId] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  // ── Thinking phase timing ──────────────────────────────────────────────────
  const thinkBlockStartRef = useRef<number | null>(null);
  const thinkBlockDurationRef = useRef<number | null>(null);
  const [streamingThinkingDurationMs, setStreamingThinkingDurationMs] = useState<number | null>(null);

  // ── Context summaries (Infinite Chats) ────────────────────────────────────
  const [conversationSummaries, setConversationSummaries] = useState<ConversationSummary[]>([]);
  const [summarizing, setSummarizing] = useState(false);

  // ── Play token ─────────────────────────────────────────────────────────────
  const [playToken, setPlayToken] = useState<PlaygroundToken | null>(null);
  const tokenExpiresAt = useRef<Date | null>(null);

  // ── UI ─────────────────────────────────────────────────────────────────────
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [guardrailWarning, setGuardrailWarning] = useState<string | null>(null);

  // ── Ghost mode — no DB writes, no request log ──────────────────────────────
  const [ghostMode, setGhostMode] = useState<boolean>(() =>
    localStorage.getItem("aig-chat-ghost") === "1"
  );

  function toggleGhostMode() {
    const next = !ghostMode;
    setGhostMode(next);
    localStorage.setItem("aig-chat-ghost", next ? "1" : "0");
    // A ghost conversation and a normal conversation cannot share state
    setActiveConvId(null);
    setMessages([]);
    focusInput();
  }

  const [showFeedback, setShowFeedback]       = useState(false);
  const [feedbackRating, setFeedbackRating]   = useState<number | null>(null);
  const [feedbackComment, setFeedbackComment] = useState("");
  const [feedbackSaving, setFeedbackSaving]   = useState(false);
  const [feedbackError, setFeedbackError]     = useState<string | null>(null);
  const [feedbackSaved, setFeedbackSaved]     = useState(false);

  // ── Share modal ────────────────────────────────────────────────────────────
  const [showShareModal, setShowShareModal]   = useState(false);
  const [shareUrl, setShareUrl]               = useState<string | null>(null);
  const [shareToken, setShareToken]           = useState<string | null>(null);
  const [shareLoading, setShareLoading]       = useState(false);
  const [shareCopied, setShareCopied]         = useState(false);

  // ── Share to project feed ──────────────────────────────────────────────────
  const [sharedInProject, setSharedInProject] = useState(false);
  const [shareProjectLoading, setShareProjectLoading] = useState(false);

  // ── Memories ───────────────────────────────────────────────────────────────
  const [memories, setMemories] = useState<ChatMemory[]>([]);
  const [showMemories, setShowMemories] = useState(false);
  const [memToast, setMemToast] = useState<string | null>(null);
  const [showInstructionsModal, setShowInstructionsModal] = useState(false);
  const [showFilesPanel, setShowFilesPanel] = useState(false);
  const [previewFileFromChat, setPreviewFileFromChat] = useState<ProjectKnowledgeText | null>(null);

  // ── Artifact panel ─────────────────────────────────────────────────────────
  const [activeArtifact, setActiveArtifact] = useState<Artifact | null>(null);

  // ── Slash commands ─────────────────────────────────────────────────────────
  const [userCommands, setUserCommands] = useState<SlashCommand[]>([]);
  const [pendingCommand, setPendingCommand] = useState<SlashCommand | null>(null);

  // ── MCP connectors ──────────────────────────────────────────────────────────
  // mcpTools: flat list of { connectorId, tool } ready to inject into requests
  const [mcpConnectors, setMcpConnectors] = useState<McpConnector[]>([]);
  const [mcpTools, setMcpTools] = useState<Array<{ connectorId: string; tool: McpTool }>>([]);

  // ── Initial data load ──────────────────────────────────────────────────────
  useEffect(() => {
    api.get<Tenant[]>("/tenants").then(setTenants).catch(() => {});
    api.get<ModelPrice[]>("/models").then(setModels).catch(() => {});
    api.get<ProviderMeta[]>("/providers").then(setProviderMeta).catch(() => {});
    api.get<ChatConversation[]>("/conversations").then(setConversations).catch(() => {});
    api.get<ChatPreset[]>("/chat-presets").then(setPresets).catch(() => {});
    api.get<SlashCommand[]>("/chat-commands").then(setUserCommands).catch(() => {});
    api.get<ChatMemory[]>("/memories").then(setMemories).catch(() => {});
    // Load MCP connectors and fetch their tool lists
    api.get<McpConnector[]>("/mcp").then(async (connectors) => {
      setMcpConnectors(connectors);
      const toolEntries: Array<{ connectorId: string; tool: McpTool }> = [];
      await Promise.allSettled(connectors.map(async (c) => {
        try {
          const res = await api.post<{ result?: { tools?: McpTool[] } }>(
            `/mcp/${c.id}/call`,
            { jsonrpc: "2.0", id: 1, method: "tools/list", params: {} }
          );
          for (const t of res.result?.tools ?? []) {
            toolEntries.push({ connectorId: c.id, tool: t });
          }
        } catch { /* connector unreachable — skip */ }
      }));
      setMcpTools(toolEntries);
    }).catch(() => {});
  }, []);

  // ── Project context: load project + knowledge when ?project_id= changes ───
  useEffect(() => {
    if (!projectIdParam) { setActiveProject(null); setProjectKnowledge([]); return; }
    api.get<ChatProject>(`/projects/${projectIdParam}`)
      .then((p) => {
        setActiveProject(p);
        if (p.default_gateway_id) setGatewayId(p.default_gateway_id);
        if (p.default_model) setModel(p.default_model);
      })
      .catch(() => setActiveProject(null));
    api.get<ProjectKnowledgeText[]>(`/projects/${projectIdParam}/knowledge-text`)
      .then(setProjectKnowledge)
      .catch(() => setProjectKnowledge([]));
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectIdParam]);

  // Auto-load a specific conversation when ?conv= is present in the URL
  useEffect(() => {
    if (!convParam || conversations.length === 0) return;
    if (activeConvId === convParam) return;
    if (loadingConvRef.current === convParam) return; // already loading — skip duplicate
    if (conversations.find((c) => c.id === convParam)) {
      loadConversation(convParam);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [convParam, conversations]);

  // Sync drawer system prompt when project or knowledge files change
  useEffect(() => {
    if (!activeProject) return;
    const built = buildProjectSystemPrompt(activeProject, projectKnowledge);
    if (built) setDrawerSettings((prev) => ({ ...prev, systemPrompt: built }));
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeProject, projectKnowledge]);

  // ── Load gateways when tenant changes ─────────────────────────────────────
  useEffect(() => {
    if (!tenantId) { setGateways([]); setGatewayId(""); return; }
    api.get<Gateway[]>(`/tenants/${tenantId}/gateways`).then((rows) => {
      setGateways(rows);
      if (!gatewayId || !rows.find((r) => r.id === gatewayId)) {
        setGatewayId(rows[0]?.id ?? "");
      }
    }).catch(() => {});
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [tenantId]);

  // Validate stored tenant — fall back to user's own tenant, then first in list
  useEffect(() => {
    if (tenants.length === 0) return;
    if (tenantId && tenants.find((t) => t.id === tenantId)) return;
    // Prefer the user's own tenant_id so admins land on their home tenant,
    // not on the most-recently-created tenant (which may be a temporary test fixture).
    const preferred = (me?.tenant_id && tenants.find((t) => t.id === me.tenant_id))
      ? me.tenant_id
      : tenants[0].id;
    setTenantId(preferred);
  }, [tenants, tenantId, me?.tenant_id]);

  // ── Fetch play token when gateway changes ──────────────────────────────────
  const refreshToken = useCallback(async (gId: string): Promise<PlaygroundToken | null> => {
    try {
      const tok = await api.post<PlaygroundToken>("/playground/token", { gateway_id: gId });
      setPlayToken(tok);
      tokenExpiresAt.current = new Date(tok.expires_at);
      return tok;
    } catch (e) {
      setError("Could not create gateway token: " + String(e));
      return null;
    }
  }, []);

  useEffect(() => {
    if (!gatewayId) { setPlayToken(null); return; }
    refreshToken(gatewayId);
  }, [gatewayId, refreshToken]);

  // ── Derived: runnable providers ────────────────────────────────────────────
  const configuredProviders = new Set<string>(
    ((gateways.find((g) => g.id === gatewayId) as any)?.configured_providers ?? []) as string[]
  );

  const freeProviders = new Set(providerMeta.filter((p) => !p.requires_key).map((p) => p.name));
  const runnableProviders = new Set<string>([...freeProviders, ...configuredProviders]);

  // Thinking capability: look up the current model in the price/capability list.
  // Falls back to false if the model isn't in the list yet.
  const supportsThinking = models.find((m) => m.model === model)?.supports_thinking ?? false;

  // ── Tenant presets (member/viewer restriction) ────────────────────────────
  const selectedTenant = tenants.find((t) => t.id === tenantId);
  const tenantPresets: TenantPreset[] = selectedTenant?.chat_presets ?? [];
  const usePresetMode = tenantPresets.length > 0;

  // When preset mode activates or tenant changes, sync gateway+model from preset
  useEffect(() => {
    if (!usePresetMode || tenantPresets.length === 0) return;
    const preset = tenantPresets.find((p) => p.id === selectedPresetId) ?? tenantPresets[0];
    if (preset) {
      setSelectedPresetId(preset.id);
      setGatewayId(preset.gateway_id);
      setModel(preset.model);
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [usePresetMode, tenantId]);

  // ── Load conversation messages ─────────────────────────────────────────────
  async function loadConversation(id: string) {
    loadingConvRef.current = id;
    setActiveArtifact(null);
    setConversationSummaries([]);
    try {
      const conv = await api.get<ChatConversation>(`/conversations/${id}`);
      setActiveConvId(id);
      setMessages(conv.messages ?? []);
      setSharedInProject(conv.shared_in_project === 1);
      // Load any context summaries for this conversation
      api.get<ConversationSummary[]>(`/conversations/${id}/summaries`)
        .then(setConversationSummaries)
        .catch(() => setConversationSummaries([]));
      // Sync settings from conversation — but never override gateway/model in preset mode
      // (the active preset owns those; loadConversation must not stomp the user's selection)
      if (!usePresetMode) {
        if (conv.model) setModel(conv.model);
        if (conv.gateway_id && conv.gateway_id !== gatewayId) {
          setGatewayId(conv.gateway_id);
        }
      }
      setDrawerSettings({
        systemPrompt: conv.system_prompt ?? "",
        temperature: conv.temperature ?? 0.7,
        maxTokens: conv.max_tokens ?? 2048,
        webSearch: false,
        thinkingBudget: null,
      });
      // Load existing feedback (silently — 404 means none yet)
      api.get<ChatFeedback>(`/conversations/${id}/feedback`)
        .then((fb) => { setFeedbackRating(fb.rating); setFeedbackComment(fb.comment ?? ""); })
        .catch(() => { setFeedbackRating(null); setFeedbackComment(""); });
      setFeedbackSaved(false);
      setFeedbackError(null);
      focusInput();
    } catch (e) {
      setError(String(e));
    } finally {
      if (loadingConvRef.current === id) loadingConvRef.current = null;
    }
  }

  // ── Create conversation ────────────────────────────────────────────────────
  async function createConversation() {
    if (!gatewayId) { setError("Select a gateway first"); return; }
    setCreating(true);
    try {
      const conv = await api.post<ChatConversation>("/conversations", {
        gateway_id: gatewayId,
        model: model,
        system_prompt: drawerSettings.systemPrompt || null,
        temperature: drawerSettings.temperature,
        max_tokens: drawerSettings.maxTokens,
        ...(projectIdParam ? { project_id: projectIdParam } : {}),
      });
      setConversations((prev) => [conv, ...prev]);
      setSearchParams((prev) => { const p = new URLSearchParams(prev); p.set("conv", conv.id); return p; });
      await loadConversation(conv.id);
      focusInput();
    } catch (e) {
      setError(String(e));
    } finally {
      setCreating(false);
    }
  }

  // ── Rename conversation ────────────────────────────────────────────────────
  async function renameConversation(id: string, title: string) {
    await api.patch(`/conversations/${id}`, { title }).catch(() => {});
    setConversations((prev) => prev.map((c) => c.id === id ? { ...c, title } : c));
  }

  // ── Auto-title generation (fires after first exchange, non-blocking) ────────
  async function generateTitle(convId: string, firstUserText: string, firstAssistantText: string, tok: PlaygroundToken, currentModel: string) {
    try {
      const compatUrl = `${GATEWAY_URL}/v1/${tok.tenant_slug}/${tok.gateway_slug}/compat/chat/completions`;
      const abort = new AbortController();
      const timer = setTimeout(() => abort.abort(), 90_000); // 90s timeout for slow local models
      const res = await fetch(compatUrl, {
        method: "POST",
        signal: abort.signal,
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${tok.token}`,
        },
        body: JSON.stringify({
          model: currentModel,
          messages: [
            {
              role: "system",
              // Qwen3 thinking models require /no_think to skip the <think> block;
              // for all other models (Claude, etc.) the prefix is harmless or absent.
              content: (currentModel.toLowerCase().includes("qwen") ? "/no_think\n" : "") +
                "Generate a short title (3–6 words) for the conversation the user provides. " +
                "The assistant excerpt may be incomplete or cut off mid-sentence — infer the topic from context. " +
                "Reply with only the title — no quotes, no punctuation at the end. " +
                "Use natural phrasing, like a topic jotted in a notebook, not a document heading.",
            },
            {
              role: "user",
              content: "User: " + firstUserText.slice(0, 400) +
              "\n\nAssistant (excerpt, may be incomplete): " + firstAssistantText.slice(0, 400),
            },
          ],
          max_tokens: 500,
          temperature: 0,
          stream: false,
        }),
      });
      clearTimeout(timer);
      if (!res.ok) {
        console.warn("[generateTitle] title request failed:", res.status, await res.text().catch(() => ""));
        return;
      }
      const json = await res.json();
      const raw: string | undefined = json?.choices?.[0]?.message?.content?.trim();
      if (!raw) { console.warn("[generateTitle] empty content in response", json); return; }
      // Strip <think>...</think> blocks that reasoning models (e.g. local Qwen) leak into
      // their output. Remove both complete blocks and any unclosed opening tag + trailing text.
      const stripped = raw
        .replace(/<think>[\s\S]*?<\/think>/gi, "")   // complete <think>…</think>
        .replace(/<think>[\s\S]*/gi, "")              // unclosed <think>… to end of string
        .trim();
      // Strip surrounding quotes and trailing sentence-ending punctuation models sometimes add
      const title = stripped.replace(/^["'「]|["'」]$/g, "").replace(/[.!?]$/, "").trim();
      if (!title) return;
      await renameConversation(convId, title);
    } catch (err) {
      console.warn("[generateTitle] error:", err);
    }
  }

  // ── Delete conversation ────────────────────────────────────────────────────
  function buildExportMarkdown(): { markdown: string; slug: string } | null {
    const conv = conversations.find((c) => c.id === activeConvId);
    if (!conv || messages.length === 0) return null;

    const today = new Date().toLocaleDateString("en-US", { year: "numeric", month: "long", day: "numeric" });
    const lines: string[] = [`# ${conv.title}`, ``, `*Exported on ${today}*`, ``, `---`];

    const convModel = conv.model ?? model;

    for (const msg of messages) {
      let label: string;
      if (msg.role === "user") {
        label = "**You**";
      } else {
        const msgModel = msg.model ?? convModel;
        const gwId = msg.gateway_id ?? conv.gateway_id;
        const gw = gwId ? gateways.find((g) => g.id === gwId) : null;
        const gwLabel = gw?.slug ?? gwId ?? "";
        label = gwLabel
          ? `**${aiLabel(msgModel)} via ${gwLabel}**`
          : `**${aiLabel(msgModel)}**`;
      }
      lines.push("", label, "");

      let text = msg.content;
      try {
        const parsed = JSON.parse(msg.content);
        if (Array.isArray(parsed)) {
          const parts: string[] = [];
          for (const b of parsed as any[]) {
            if (b.type === "text") {
              const t = (b.text ?? "").trim();
              if (t) parts.push(t);                              // skip empty text blocks
            } else if (b.type === "image_url") {
              parts.push("*[Image attached]*");
            } else if (b.type === "image") {
              parts.push(`*[Image: ${b.filename}]*`);
            } else if (b.type === "docx") {
              parts.push(`*[Document: ${b.filename}]*`);        // reference only — no inline text dump
            } else if (b.type === "md") {
              parts.push(`*[Markdown: ${b.filename}]*`);
            } else if (b.type === "document" && b.source?.type === "file") {
              parts.push(`*[Spreadsheet: ${b.filename ?? "file"}]*`);
            } else if (b.type === "document") {
              parts.push(`*[File: ${b.filename ?? "file"}]*`);
            }
          }
          text = parts.join("\n\n");
        }
      } catch { /* plain text — keep as-is */ }

      lines.push(text, "", "---");
    }

    const slug = conv.title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 60) || "conversation";
    return { markdown: lines.join("\n"), slug };
  }

  function exportMarkdown() {
    const result = buildExportMarkdown();
    if (!result) return;
    const date = new Date().toISOString().slice(0, 10);
    const blob = new Blob([result.markdown], { type: "text/markdown" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url; a.download = `${result.slug}-${date}.md`; a.click();
    URL.revokeObjectURL(url);
  }

  async function exportPdf() {
    const result = buildExportMarkdown();
    if (!result) return;
    const date = new Date().toISOString().slice(0, 10);
    const filename = `${result.slug}-${date}`;
    try {
      const res = await fetch(`${import.meta.env.VITE_ADMIN_URL ?? "/admin/v1"}/chat/export-pdf`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(document.cookie.match(/aig_session=([^;]+)/)
            ? {} : {}),                                         // auth handled by cookie / existing session
        },
        credentials: "include",
        body: JSON.stringify({ markdown: result.markdown, filename }),
      });
      if (!res.ok) {
        const err = await res.json().catch(() => ({ error: `HTTP ${res.status}` }));
        setError("PDF export failed: " + (err.error ?? res.status));
        return;
      }
      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url; a.download = `${filename}.pdf`; a.click();
      URL.revokeObjectURL(url);
    } catch (e) {
      setError("PDF export failed: " + String(e));
    }
  }

  const [markdownCopied, setMarkdownCopied] = useState(false);

  function copyMarkdown() {
    const result = buildExportMarkdown();
    if (!result) return;
    navigator.clipboard.writeText(result.markdown).then(() => {
      setMarkdownCopied(true);
      setTimeout(() => setMarkdownCopied(false), 2000);
    }).catch(() => {
      setError("Failed to copy to clipboard");
    });
  }

  async function saveFeedback() {
    if (!activeConvId || feedbackRating === null) return;
    setFeedbackSaving(true);
    setFeedbackError(null);
    try {
      await api.put(`/conversations/${activeConvId}/feedback`, {
        rating: feedbackRating,
        comment: feedbackComment,
      });
      setFeedbackSaved(true);
      setTimeout(() => { setShowFeedback(false); focusInput(); }, 800);
    } catch (e: unknown) {
      setFeedbackError(e instanceof Error ? e.message : "Failed to save feedback");
    } finally {
      setFeedbackSaving(false);
    }
  }

  // ── Command selection ──────────────────────────────────────────────────────
  const activeTenant = tenants.find((t) => t.id === tenantId);
  const tenantCommands: SlashCommand[] = activeTenant?.slash_commands ?? [];
  const allCommands = [...tenantCommands, ...userCommands];

  function handleCommandSelect(cmd: SlashCommand) {
    setInputValue("");
    const vars: string[] = [];
    const re = /\{\{(\w+)\}\}/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(cmd.template)) !== null) {
      if (!vars.includes(m[1])) vars.push(m[1]);
    }
    if (vars.length === 0) {
      setInputValue(cmd.template);
      focusInput();
    } else {
      setPendingCommand(cmd);
    }
  }

  async function deleteConversation(id: string) {
    if (!window.confirm("Delete this conversation?")) return;
    await api.delete(`/conversations/${id}`).catch(() => {});
    setConversations((prev) => prev.filter((c) => c.id !== id));
    if (activeConvId === id) {
      setActiveConvId(null);
      setMessages([]);
    }
  }

  async function starConversation(id: string, starred: boolean) {
    setConversations((prev) => prev.map((c) => c.id === id ? { ...c, starred: starred ? 1 : 0 } : c));
    await api.patch(`/conversations/${id}`, { starred: starred ? 1 : 0 }).catch(() => {});
  }

  async function archiveConversation(id: string) {
    setConversations((prev) => prev.filter((c) => c.id !== id));
    if (activeConvId === id) { setActiveConvId(null); setMessages([]); }
    await api.patch(`/conversations/${id}`, { archived_at: Math.floor(Date.now() / 1000) }).catch(() => {});
  }

  async function unarchiveConversation(id: string) {
    await api.patch(`/conversations/${id}`, { archived_at: null }).catch(() => {});
    setShowArchived(false);
    api.get<ChatConversation[]>("/conversations").then(setConversations).catch(() => {});
  }

  function toggleArchivedView() {
    const next = !showArchived;
    setShowArchived(next);
    const url = next ? "/conversations?archived=1" : "/conversations";
    api.get<ChatConversation[]>(url).then(setConversations).catch(() => {});
  }

  // ── Share conversation ─────────────────────────────────────────────────────
  async function openShareModal() {
    if (!activeConvId) return;
    setShowShareModal(true);
    setShareUrl(null);
    setShareToken(null);
    setShareCopied(false);
    setShareLoading(true);
    try {
      const data = await api.post<{ token: string; url: string }>(
        `/conversations/${activeConvId}/share`, {}
      );
      setShareUrl(data.url);
      setShareToken(data.token);
    } catch {
      // ignore — shareUrl stays null, modal shows error
    } finally {
      setShareLoading(false);
    }
  }

  async function revokeShare() {
    if (!activeConvId) return;
    await api.delete(`/conversations/${activeConvId}/share`).catch(() => {});
    setShareUrl(null);
    setShareToken(null);
  }

  async function toggleShareToProject() {
    if (!activeConvId || !projectIdParam) return;
    setShareProjectLoading(true);
    try {
      if (sharedInProject) {
        await api.delete(`/conversations/${activeConvId}/share-project`);
        setSharedInProject(false);
        setMemToast("Removed from project feed");
      } else {
        await api.post(`/conversations/${activeConvId}/share-project`, {});
        setSharedInProject(true);
        setMemToast("Shared to project feed");
      }
      setTimeout(() => setMemToast(null), 3000);
    } catch (e) {
      setError("Failed to update project sharing: " + String(e));
    } finally {
      setShareProjectLoading(false);
    }
  }
  async function sendMessage() {
    const text = inputValue.trim();
    if (!text && pendingAttachments.length === 0) return;

    // In preset mode: derive gateway + model directly from the selected preset.
    // This is the authoritative source — never use gatewayId/model state which
    // may have been transiently overridden by loadConversation.
    const activePreset = usePresetMode
      ? (tenantPresets.find((p) => p.id === selectedPresetId) ?? tenantPresets[0])
      : null;
    const effectiveGatewayId = activePreset?.gateway_id ?? gatewayId;
    const effectiveModel     = activePreset?.model      ?? model;

    if (!effectiveGatewayId) { setError("Select a gateway first"); return; }
    if (!effectiveModel) { setError("Select a model first"); return; }

    // Fetch token on-demand if the background effect hasn't completed yet
    // (can happen when the user sends before the async refresh finishes on first load)
    if (!playToken) {
      const tok = await refreshToken(effectiveGatewayId);
      if (!tok) { setError("No gateway token — select a gateway"); return; }
    }

    // Refresh token if expiring soon OR if it belongs to a different gateway
    // (the latter can happen when the user switches presets before the async refresh completes)
    const tokenAge = tokenExpiresAt.current
      ? tokenExpiresAt.current.getTime() - Date.now()
      : null;
    let currentTok: PlaygroundToken | null = playToken;
    const currentGateway = gateways.find((g) => g.id === effectiveGatewayId);
    const tokenMismatch = currentGateway && playToken && playToken.gateway_slug !== currentGateway.slug;
    const tokenExpiring = tokenAge !== null && tokenAge < 60_000;
    if (tokenMismatch || tokenExpiring) {
      currentTok = await refreshToken(effectiveGatewayId);
    }
    if (!currentTok) { setError("No gateway token — could not refresh"); return; }

    // Track whether this is the very first message (for auto-title)
    const isFirstMessage = messages.length === 0;
    // Was a conversation pre-created via the "New Conversation" button?
    const hadExistingConv = !!activeConvId;

    // Create conversation on first message if none active
    let convId = activeConvId;
    if (!convId) {
      if (ghostMode) {
        // Ghost mode: keep conversation in memory only — no DB row
        convId = `ghost-${crypto.randomUUID()}`;
        setActiveConvId(convId);
      } else {
        setCreating(true);
        try {
          const conv = await api.post<ChatConversation>("/conversations", {
            gateway_id: effectiveGatewayId,
            model: effectiveModel,
            system_prompt: drawerSettings.systemPrompt || null,
            temperature: drawerSettings.temperature,
            max_tokens: drawerSettings.maxTokens,
            title: text.slice(0, 60) || "New conversation",
            ...(projectIdParam ? { project_id: projectIdParam } : {}),
          });
          convId = conv.id;
          setConversations((prev) => [conv, ...prev]);
          setActiveConvId(convId);
          setSearchParams((prev) => { const p = new URLSearchParams(prev); p.set("conv", convId!); return p; });
        } catch (e) {
          setError("Failed to create conversation: " + String(e));
          setCreating(false);
          return;
        } finally {
          setCreating(false);
        }
      }
    }

    // If the user's first message goes into a pre-created "New conversation", immediately
    // rename it from the message text so there's always a meaningful fallback title
    // even if generateTitle() later fails or the stream errors out.
    if (!ghostMode && isFirstMessage && hadExistingConv && convId && text) {
      renameConversation(convId, text.slice(0, 60));
    }

    // Build content — plain text or content blocks if attachments
    let userContent: string;
    let hasSkill: string | null = null; // reserved for future skill-based providers
    if (pendingAttachments.length > 0) {
      const blocks: object[] = [{ type: "text", text }];
      const unsupported: string[] = [];
      for (const att of pendingAttachments) {
        if (att.mime_type.startsWith("image/")) {
          if (effectiveModel.startsWith("claude-") || isVisionCapable(effectiveModel)) {
            // Anthropic and vision-capable vLLM models: send image_url directly
            blocks.push({
              type: "image_url",
              image_url: { url: `data:${att.mime_type};base64,${att.data}` },
            });
          } else {
            // Text-only vLLM model: describe image via MinerU
            let description: string;
            try {
              setProcessingStatus(`Analyzing image "${att.filename}" with MinerU…`);
              const res = await api.post<{ text: string }>("/chat/files", {
                gateway_id: effectiveGatewayId,
                filename: att.filename,
                mime_type: att.mime_type,
                data: att.data,
                extract_text: true,
              });
              description = res.text;
            } catch (e) {
              setError("Failed to process image: " + String(e));
              return;
            }
            blocks.push({ type: "image", filename: att.filename, text: description });
          }
        } else if (att.mime_type === "text/markdown" || att.filename.endsWith(".md")) {
          // Markdown is plain text — decode base64 → UTF-8 in-browser, no server round-trip needed
          const raw = atob(att.data);
          const bytes = new Uint8Array(raw.length);
          for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
          const decoded = new TextDecoder("utf-8").decode(bytes);
          blocks.push({ type: "md", filename: att.filename, text: decoded });
        } else if (att.mime_type === "application/pdf" || att.mime_type === "text/plain") {
          if (att.mime_type === "application/pdf" && !effectiveModel.startsWith("claude-")) {
            // Non-Anthropic model: extract PDF text via MinerU
            let extractedText: string;
            try {
              setProcessingStatus(`Extracting text from "${att.filename}" with MinerU…`);
              const res = await api.post<{ text: string }>("/chat/files", {
                gateway_id: effectiveGatewayId,
                filename: att.filename,
                mime_type: att.mime_type,
                data: att.data,
                extract_text: true,
              });
              extractedText = res.text;
            } catch (e) {
              setError("Failed to extract PDF: " + String(e));
              return;
            }
            blocks.push({ type: "pdf", filename: att.filename, text: extractedText });
          } else {
            // Anthropic-native path: inline base64 document block
            blocks.push({
              type: "document",
              source: { type: "base64", media_type: att.mime_type, data: att.data },
            });
          }
        } else if (att.mime_type === "application/vnd.openxmlformats-officedocument.wordprocessingml.document") {
          // Gateway extracts plain text from the docx server-side and returns { text }
          let extractedText: string;
          try {
            setProcessingStatus(`Extracting text from "${att.filename}"…`);
            const res = await api.post<{ text: string }>("/chat/files", {
              gateway_id: effectiveGatewayId,
              filename: att.filename,
              mime_type: att.mime_type,
              data: att.data,
            });
            extractedText = res.text;
          } catch (e) {
            setError("Failed to extract text from .docx: " + String(e));
            return;
          }
          blocks.push({
            type: "docx",
            filename: att.filename,
            text: extractedText,
          });
        } else if (
          att.mime_type === "text/csv" ||
          att.mime_type === "text/tab-separated-values" ||
          att.mime_type === "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" ||
          att.mime_type === "application/vnd.ms-excel.sheet.macroenabled.12" ||
          att.mime_type === "application/vnd.oasis.opendocument.spreadsheet" ||
          att.mime_type === "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        ) {
          if (effectiveModel.startsWith("claude-")) {
            // Anthropic path: upload to Files API, reference via file_id document block
            let fileId: string;
            try {
              setProcessingStatus(`Uploading "${att.filename}"…`);
              const res = await api.post<{ file_id: string }>("/chat/files", {
                gateway_id: effectiveGatewayId,
                filename: att.filename,
                mime_type: att.mime_type,
                data: att.data,
              });
              fileId = res.file_id;
            } catch (e) {
              setError("Failed to upload file: " + String(e));
              return;
            }
            blocks.push({ type: "document", source: { type: "file", file_id: fileId } });
            hasSkill = "xlsx";
          } else {
            // Non-Anthropic path: extract text server-side and embed inline
            let extractedText: string;
            try {
              setProcessingStatus(`Extracting text from "${att.filename}"…`);
              const res = await api.post<{ text: string }>("/chat/files", {
                gateway_id: effectiveGatewayId,
                filename: att.filename,
                mime_type: att.mime_type,
                data: att.data,
                extract_text: true,
              });
              extractedText = res.text;
            } catch (e) {
              setError("Failed to extract text from file: " + String(e));
              return;
            }
            blocks.push({ type: "text", text: `[File: ${att.filename}]\n\n${extractedText}` });
          }
        } else {
          unsupported.push(att.filename);
        }
      }
      if (unsupported.length > 0) {
        setError(
          `Unsupported file type(s): ${unsupported.join(", ")}. ` +
          `Supported: images (JPEG, PNG, GIF, WebP), PDF, plain text, Markdown (.md), Word (.docx), CSV, TSV, Excel (.xlsx, .xlsm), OpenDocument (.ods), PowerPoint (.pptx).`
        );
        return;
      }
      userContent = JSON.stringify(blocks);
    } else {
      userContent = text;
    }

    // Optimistically append user message to UI
    const tempUserMsg: ChatMessage = {
      id: "__temp_user__",
      conversation_id: convId,
      parent_message_id: null,
      role: "user",
      content: userContent,
      input_tokens: null,
      output_tokens: null,
      cost_usd: null,
      latency_ms: null,
      created_at: new Date().toISOString(),
    };
    setMessages((prev) => [...prev, tempUserMsg]);
    setInputValue("");
    setPendingAttachments([]);
    setError(null);
    focusInput();

    // Persist user message (skip in ghost mode)
    let userMsgId: string | null = null;
    if (ghostMode) {
      userMsgId = `ghost-msg-${crypto.randomUUID()}`;
      setMessages((prev) =>
        prev.map((m) => m.id === "__temp_user__" ? { ...m, id: userMsgId! } : m)
      );
    } else {
      try {
        const res = await api.post<{ id: string }>(`/conversations/${convId}/messages`, {
          role: "user",
          content: userContent,
        });
        userMsgId = res.id;
        setMessages((prev) =>
          prev.map((m) => m.id === "__temp_user__" ? { ...m, id: userMsgId! } : m)
        );
      } catch (e) {
        setError("Failed to save message: " + String(e));
        setMessages((prev) => prev.filter((m) => m.id !== "__temp_user__"));
        return;
      }

      // Upload any attachments (binary storage skipped in ghost mode;
      // text extraction via /chat/files was already done above and is temp-only)
      if (pendingAttachments.length > 0 && userMsgId) {
        for (const att of pendingAttachments) {
          await api.post(`/conversations/${convId}/attachments`, {
            message_id: userMsgId,
            filename: att.filename,
            mime_type: att.mime_type,
            data: att.data,
          }).catch(() => {});
        }
      }
    }

    // Build message history for inference
    const history = messages
      .filter((m) => m.id !== "__temp_user__")
      .concat({ ...tempUserMsg, id: userMsgId ?? "__temp_user__" });

    const activeConv = conversations.find(c => c.id === activeConvId);
    const memoryDisabled = activeConv?.memory_disabled === 1;
    const memBlock = (!memoryDisabled && memories.length > 0)
      ? "\n\n---\n## What I know about you\n" + memories.map(m => `- ${m.content}`).join("\n")
      : "";
    const memInstruction = !memoryDisabled
      ? "\n\nWhen the user states a personal fact, preference, or instruction worth remembering across conversations, emit it exactly as:\n<memory type=\"fact|preference|instruction\">concise fact in third-person</memory>\nThis tag is invisible to the user. Use sparingly — only for durable facts."
      : "";
    const systemContent = (drawerSettings.systemPrompt || "") + memBlock + memInstruction;

    // Build the ID set of messages already covered by summaries so we can skip them
    const summarizedUpToIds = new Set(conversationSummaries.map((s) => s.last_message_id));
    const latestSummary = conversationSummaries.length > 0
      ? conversationSummaries[conversationSummaries.length - 1]
      : null;
    // Find messages NOT yet summarized
    let historyToSend = history;
    if (latestSummary) {
      const cutIdx = history.findIndex((m) => m.id === latestSummary.last_message_id);
      if (cutIdx >= 0) {
        historyToSend = history.slice(cutIdx + 1);
      }
    }

    // Build summary preamble if summaries exist
    const summaryPreamble = conversationSummaries.length > 0
      ? conversationSummaries.map((s) => s.summary_text).join("\n\n---\n\n")
      : null;

    const apiMessages = [
      ...(systemContent
        ? [{ role: "system", content: systemContent }]
        : []),
      // Inject summaries of older context as a synthetic message pair
      ...(summaryPreamble
        ? [
            { role: "user" as const, content: `[Context summary of earlier conversation]\n\n${summaryPreamble}` },
            { role: "assistant" as const, content: "Understood. I have the context from our earlier conversation." },
          ]
        : []),
      ...historyToSend.map((m) => {
        let content: unknown = m.content;
        try {
          const parsed = JSON.parse(m.content);
          if (Array.isArray(parsed)) {
            // Convert docx/pdf blocks back to plain text for the LLM
            content = parsed.map((b: { type: string; filename?: string; text?: string; [k: string]: unknown }) => {
              if (b.type === "docx" || b.type === "pdf" || b.type === "md") {
                return { type: "text", text: `[Document: ${b.filename}]\n\n${b.text ?? ""}` };
              }
              if (b.type === "image") {
                return { type: "text", text: `[Image: ${b.filename}]\n\n${b.text ?? ""}` };
              }
              return b;
            });
          }
        } catch { /* plain text — keep as string */ }
        return { role: m.role, content };
      }),
    ];

    // Re-apply skill header if this or any prior message in the conversation used the Files API
    const needsSkill = hasSkill ?? (history.some((m) => {
      try {
        const p = JSON.parse(m.content);
        return Array.isArray(p) && p.some((b: any) => b?.source?.type === "file");
      } catch { return false; }
    }) ? "xlsx" : null);

    // Stream inference
    const tok = currentTok;
    const compatUrl = `${GATEWAY_URL}/v1/${tok.tenant_slug}/${tok.gateway_slug}/compat/chat/completions`;
    const abort = new AbortController();
    abortRef.current = abort;

    setProcessingStatus("Waiting for model response…");
    setIsStreaming(true);
    setStreamingContent("");
    setStreamingConvId(convId);
    thinkBlockStartRef.current = null;
    thinkBlockDurationRef.current = null;
    setStreamingThinkingDurationMs(null);

    const start = performance.now();
    let accumulated = "";
    let inputTokens: number | null = null;
    let outputTokens: number | null = null;
    let costUsd: number | null = null;

    const reqHeaders = Object.fromEntries(
      Object.entries({
        "Content-Type": "application/json",
        Authorization: `Bearer ${tok.token}`,
        ...(ghostMode ? { "x-aig-collect-log": "false" } : {}),
        ...(needsSkill ? { "x-aig-skill": needsSkill } : {}),
        ...(drawerSettings.webSearch ? { "x-aig-web-search": "1" } : {}),
        ...(drawerSettings.thinkingBudget !== null
          ? { "x-aig-thinking-budget": String(drawerSettings.thinkingBudget) }
          : {}),
      }).filter(([, v]) => v !== undefined)
    ) as Record<string, string>;

    let continueCount = 0;
    const MAX_CONTINUATIONS = 10;
    let fileReadCount = 0;
    const MAX_FILE_READS = 5;
    let pendingFileInjection: string | null = null;
    // MCP tool call loop: extra messages to append (assistant + tool_result pairs)
    const mcpExtraMessages: Array<{ role: string; content: unknown }> = [];
    let mcpToolCallCount = 0;
    const MAX_MCP_TOOL_CALLS = 10;

    streaming: while (true) {
      const reqMessages = (() => {
        if (continueCount === 0 && pendingFileInjection === null && mcpExtraMessages.length === 0) return apiMessages;
        const msgs = [...apiMessages, ...mcpExtraMessages];
        if (pendingFileInjection !== null || (continueCount > 0 && mcpExtraMessages.length === 0)) {
          msgs.push({ role: "assistant", content: accumulated });
          msgs.push({ role: "user", content: pendingFileInjection ?? "Continue" });
        }
        return msgs;
      })();
      pendingFileInjection = null; // consumed

      // Accumulate tool_calls deltas across SSE chunks
      // Shape: { [index]: { id, name, argumentsAccum } }
      const pendingToolCalls: Record<number, { id: string; name: string; argumentsAccum: string }> = {};

      let finishReason: string | null = null;

      try {
        const res = await fetch(compatUrl, {
          method: "POST",
          signal: abort.signal,
          headers: reqHeaders,
          body: JSON.stringify({
            model: effectiveModel,
            messages: reqMessages,
            // Anthropic rejects requests with both temperature and thinking enabled
            ...(drawerSettings.thinkingBudget === null ? { temperature: drawerSettings.temperature } : {}),
            max_tokens: drawerSettings.maxTokens,
            stream: true,
            // Inject MCP tools if any are loaded
            ...(mcpTools.length > 0 ? {
              tools: mcpTools.map(({ tool }) => ({
                type: "function",
                function: {
                  name: tool.name,
                  description: tool.description ?? "",
                  parameters: tool.inputSchema,
                },
              })),
            } : {}),
          }),
        });

        if (!res.ok) {
          const body = await res.text().catch(() => "");
          let msg = `HTTP ${res.status}`;
          try { msg = JSON.parse(body)?.error?.message ?? JSON.parse(body)?.error ?? msg; } catch { /* */ }
          throw new Error(msg);
        }

        // Surface guardrail degradation (fail_open path on the gateway) as a
        // non-blocking banner. The gateway exposes this header via CORS, so it
        // arrives here for both same-origin and cross-origin requests.
        const grWarn = res.headers.get("x-aig-guardrail-warning");
        if (grWarn) setGuardrailWarning(grWarn);

        const reader = res.body!.getReader();
        const decoder = new TextDecoder();
        let buf = "";
        let receivedDone = false;
        const legStart = performance.now();

        while (true) {
          const { value, done } = await reader.read();
          if (done) {
            if (!receivedDone && !abort.signal.aborted) {
              console.warn(
                "[stream_truncated] SSE stream body closed without [DONE] token",
                {
                  continueCount,
                  accumulatedChars: accumulated.length,
                  outputTokens,
                  finishReason,
                  elapsedMs: Math.round(performance.now() - legStart),
                  gateway: tok.gateway_slug,
                  tenant: tok.tenant_slug,
                  model,
                },
              );
              // If no content arrived at all, the silent-failure symptom:
              // raise an explicit error so the user is not left staring at
              // an empty chat window.
              if (accumulated.length === 0 && continueCount === 0) {
                throw new Error(
                  grWarn
                    ? `Guardrail degraded and no response was received: ${grWarn}`
                    : "Connection to the AI gateway was interrupted before a response arrived.",
                );
              }
            }
            break;
          }
          buf += decoder.decode(value, { stream: true });
          const lines = buf.split("\n");
          buf = lines.pop() ?? "";
          for (const line of lines) {
            if (!line.startsWith("data: ")) continue;
            const data = line.slice(6).trim();
            if (data === "[DONE]") { receivedDone = true; continue; }
            try {
              const chunk = JSON.parse(data);
              const delta = chunk?.choices?.[0]?.delta?.content;
              if (delta != null) {
                if (!accumulated) setProcessingStatus(null); // first token — hide status
                accumulated += delta;
                setStreamingContent(accumulated);
                // Track <think> block duration
                if (thinkBlockStartRef.current === null && accumulated.includes("<think>")) {
                  thinkBlockStartRef.current = performance.now();
                }
                if (
                  thinkBlockStartRef.current !== null &&
                  thinkBlockDurationRef.current === null &&
                  accumulated.includes("</think>")
                ) {
                  thinkBlockDurationRef.current = Math.round(performance.now() - thinkBlockStartRef.current);
                  setStreamingThinkingDurationMs(thinkBlockDurationRef.current);
                }
              }
              // Accumulate OpenAI-compat tool_calls deltas
              const toolCallDeltas = chunk?.choices?.[0]?.delta?.tool_calls;
              if (Array.isArray(toolCallDeltas)) {
                for (const tc of toolCallDeltas) {
                  const idx: number = tc.index ?? 0;
                  if (!pendingToolCalls[idx]) {
                    pendingToolCalls[idx] = { id: tc.id ?? "", name: tc.function?.name ?? "", argumentsAccum: "" };
                  } else {
                    if (tc.id) pendingToolCalls[idx].id = tc.id;
                    if (tc.function?.name) pendingToolCalls[idx].name = tc.function.name;
                  }
                  if (tc.function?.arguments) {
                    pendingToolCalls[idx].argumentsAccum += tc.function.arguments;
                  }
                }
              }
              const reason = chunk?.choices?.[0]?.finish_reason;
              if (reason) finishReason = reason;
              const usage = chunk?.usage;
              if (usage) {
                inputTokens  = (inputTokens  ?? 0) + (usage.prompt_tokens     ?? 0);
                outputTokens = (outputTokens ?? 0) + (usage.completion_tokens ?? 0);
                costUsd      = (costUsd      ?? 0) + (usage.cost_usd          ?? 0);
              }
              // Gateway web-search status event (emitted by web_search.lua before fetching)
              if (chunk?.aig_status === "fetching") {
                const n = chunk.count;
                setProcessingStatus(`🔎 Fetching ${n ?? ""} URL${n !== 1 ? "s" : ""}…`.trim());
              }
              // Gateway url-fetch status event (emitted by url_fetch.lua before fetching)
              if (chunk?.aig_status === "fetching_url") {
                const n = chunk.count;
                setProcessingStatus(`🔗 Fetching ${n ?? ""} URL${n !== 1 ? "s" : ""}…`.trim());
              }
              // Native Anthropic tool-use event (forwarded by on_compat_chunk in upstream.lua)
              if (chunk?.aig_tool_call) {
                const toolLabels: Record<string, string> = {
                  web_search:     "🔎 Searching the web…",
                  fetch_url:      "🔗 Fetching URL…",
                  computer_use:   "🖥️ Using computer…",
                  code_execution: "⚙️ Running code…",
                };
                setProcessingStatus(toolLabels[chunk.aig_tool_call as string] ?? `⚙️ ${chunk.aig_tool_call}…`);
              }
            } catch { /* skip malformed */ }
          }
        }

        // Per-leg diagnostics
        const legElapsedMs = Math.round(performance.now() - legStart);
        const legCtx = {
          continueCount,
          accumulatedChars: accumulated.length,
          outputTokens,
          finishReason,
          receivedDone,
          elapsedMs: legElapsedMs,
          gateway: tok.gateway_slug,
          tenant: tok.tenant_slug,
          model,
        };
        if (finishReason === "error") {
          console.error("[stream_truncated] backend signalled finish_reason=error", legCtx);
        } else if (!finishReason && !abort.signal.aborted) {
          console.warn("[stream_truncated] stream ended with no finish_reason", legCtx);
        } else {
          console.info("[stream_ok] SSE leg completed", legCtx);
        }
      } catch (err: unknown) {
        if ((err as Error)?.name === "AbortError") {
          break streaming; // User stopped — save partial content
        } else {
          // Still attempt auto-title on error — generateTitle makes a separate gateway request
          // and fails silently, so this is safe even if the main request failed.
          if (!ghostMode && isFirstMessage && convId && text) {
            generateTitle(convId, text, accumulated, tok, model);
          }
          setProcessingStatus(null);
          setError(String(err));
          setIsStreaming(false);
          setStreamingContent(null);
          return;
        }
      }

      // Auto-continue if the model hit the token limit and user hasn't aborted
      if ((finishReason === "max_tokens" || finishReason === "length") && !abort.signal.aborted && continueCount < MAX_CONTINUATIONS) {
        continueCount++;
        continue streaming;
      }

      // MCP tool call loop: model requested tool(s) — call MCP servers and send results back
      if (
        !abort.signal.aborted &&
        (finishReason === "tool_calls" || finishReason === "tool_use") &&
        mcpToolCallCount < MAX_MCP_TOOL_CALLS
      ) {
        const calls = Object.values(pendingToolCalls);
        if (calls.length > 0) {
          // Status: show which tools are being called
          setProcessingStatus(`⚙️ Calling ${calls.map((c) => c.name).join(", ")}…`);
          // Build assistant message with tool_calls
          mcpExtraMessages.push({
            role: "assistant",
            content: accumulated || null,
            // OpenAI-compat format
            // @ts-expect-error extra field
            tool_calls: calls.map((c) => ({
              id: c.id || `call_${c.name}_${mcpToolCallCount}`,
              type: "function",
              function: { name: c.name, arguments: c.argumentsAccum },
            })),
          });
          // Execute each tool call
          const toolResults = await Promise.allSettled(calls.map(async (c) => {
            // Find which connector exposes this tool
            const entry = mcpTools.find((t) => t.tool.name === c.name);
            if (!entry) {
              return { call: c, result: { error: `Tool "${c.name}" not found in any connector` } };
            }
            let args: unknown = {};
            try { args = JSON.parse(c.argumentsAccum); } catch { /* leave empty */ }
            try {
              const res = await api.post<{ result?: unknown; error?: unknown }>(
                `/mcp/${entry.connectorId}/call`,
                { jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: c.name, arguments: args } }
              );
              return { call: c, result: res.result ?? res };
            } catch (e) {
              return { call: c, result: { error: String(e) } };
            }
          }));
          // Append tool_result messages (one per call in OpenAI format)
          for (const r of toolResults) {
            const { call: c, result } = r.status === "fulfilled" ? r.value : { call: calls[0], result: { error: "tool execution failed" } };
            mcpExtraMessages.push({
              role: "tool",
              // @ts-expect-error extra field
              tool_call_id: c.id || `call_${c.name}_${mcpToolCallCount}`,
              content: typeof result === "string" ? result : JSON.stringify(result),
            });
          }
          mcpToolCallCount++;
          // Reset streaming content for next leg
          accumulated = "";
          setStreamingContent("");
          continue streaming;
        }
      }

      // Detect <read_file> tags emitted by the model — only in project context
      if (!abort.signal.aborted && projectKnowledge.length > 0 && fileReadCount < MAX_FILE_READS) {
        const readFileRe = /<read_file>([\s\S]*?)<\/read_file>/g;
        const fileMatches: RegExpExecArray[] = [];
        let fm: RegExpExecArray | null;
        while ((fm = readFileRe.exec(accumulated)) !== null) fileMatches.push(fm);

        if (fileMatches.length > 0) {
          let cleaned = accumulated;
          const injectionParts: string[] = [];
          for (const m of fileMatches) {
            const requestedName = m[1].trim();
            cleaned = cleaned.replace(m[0], "");
            const kf = projectKnowledge.find(
              (f) => f.filename === requestedName || f.filename.endsWith("/" + requestedName)
            );
            if (kf) {
              injectionParts.push(`## File: ${kf.filename}\n\n\`\`\`\n${kf.extracted_text.trim()}\n\`\`\``);
            } else {
              injectionParts.push(`## File: ${requestedName}\n\n[File not found in project knowledge]`);
            }
          }
          accumulated = cleaned.trim();
          setStreamingContent(accumulated);
          pendingFileInjection = injectionParts.join("\n\n---\n\n");
          fileReadCount += fileMatches.length;
          setProcessingStatus(`Reading ${fileMatches.map((m) => m[1].trim()).join(", ")}…`);
          continue streaming;
        }
      }

      break streaming;
    }

    const latencyMs = Math.round(performance.now() - start);
    setProcessingStatus(null);
    setIsStreaming(false);
    setStreamingContent(null);
    setStreamingConvId(null);

    // Auto-generate title (skip in ghost mode — no conversation row exists in DB)
    if (!ghostMode && isFirstMessage && convId && text) {
      generateTitle(convId, text, accumulated, tok, model);
    }

    if (!accumulated) return;

    // Extract <memory> tags emitted by the model, strip them from visible content
    {
      const memTagRe = /<memory(?:\s+type="([^"]+)")?>([\s\S]*?)<\/memory>/g;
      let visibleContent = accumulated;
      let match;
      const currentMemoryDisabled = conversations.find(c => c.id === convId)?.memory_disabled === 1;
      while ((match = memTagRe.exec(accumulated)) !== null) {
        const mtype = (match[1] || "fact") as ChatMemory["type"];
        const content = match[2].trim();
        visibleContent = visibleContent.replace(match[0], "");
        if (!currentMemoryDisabled && content) {
          api.post<ChatMemory>("/memories", { content, type: mtype, source: "auto" })
            .then((m) => {
              setMemories((prev) => [...prev, m]);
              setMemToast(`Remembered: ${content}`);
              setTimeout(() => setMemToast(null), 3000);
            })
            .catch(() => {}); // silent — never block response path
        }
      }
      accumulated = visibleContent.trim();
    }

    if (!accumulated) return;

    // Persist assistant message (skip in ghost mode)
    if (ghostMode) {
      const assistantMsg: ChatMessage = {
        id: `ghost-msg-${crypto.randomUUID()}`,
        conversation_id: convId,
        parent_message_id: null,
        role: "assistant",
        content: accumulated,
        input_tokens: inputTokens,
        output_tokens: outputTokens,
        cost_usd: costUsd,
        latency_ms: latencyMs,
        gateway_id: gatewayId,
        model: model,
        created_at: new Date().toISOString(),
        attachments: [],
      };
      if (activeConvIdRef.current === convId) {
        setMessages((prev) => [...prev, assistantMsg]);
      }
    } else {
      try {
        const res = await api.post<{ id: string }>(`/conversations/${convId}/messages`, {
          role: "assistant",
          content: accumulated,
          input_tokens: inputTokens,
          output_tokens: outputTokens,
          cost_usd: costUsd,
          latency_ms: latencyMs,
          gateway_id: gatewayId,
          model: model,
        });
        const assistantMsg: ChatMessage = {
          id: res.id,
          conversation_id: convId,
          parent_message_id: null,
          role: "assistant",
          content: accumulated,
          input_tokens: inputTokens,
          output_tokens: outputTokens,
          cost_usd: costUsd,
          latency_ms: latencyMs,
          gateway_id: gatewayId,
          model: model,
          created_at: new Date().toISOString(),
          attachments: [],
        };
        if (activeConvIdRef.current === convId) {
          setMessages((prev) => [...prev, assistantMsg]);
        }
        // Update conversation updated_at in list
        setConversations((prev) =>
          prev.map((c) =>
            c.id === convId ? { ...c, updated_at: new Date().toISOString() } : c
          )
        );
      } catch (e) {
        setError("Failed to save assistant message: " + String(e));
      }
    }

    // Auto-summarize if input token count approaches the context window limit.
    // This runs after each response and is non-blocking / non-disruptive.
    if (!ghostMode && convId && inputTokens !== null) {
      const limit = contextWindowTokens(model);
      const threshold = Math.floor(limit * 0.75);
      if (inputTokens > threshold) {
        // Find messages not yet summarized to decide which to compress
        const allMsgs = await api.get<ChatMessage[]>(`/conversations/${convId}/messages`).catch(() => [] as ChatMessage[]);
        const latestSummary = conversationSummaries[conversationSummaries.length - 1] ?? null;
        const cutIdx = latestSummary
          ? allMsgs.findIndex((m) => m.id === latestSummary.last_message_id)
          : -1;
        const unsummarized = cutIdx >= 0 ? allMsgs.slice(cutIdx + 1) : allMsgs;
        // Only summarize if there are at least 6 messages to compress (leave at least 4 recent)
        const KEEP_RECENT = 4;
        const toCompress = unsummarized.slice(0, Math.max(0, unsummarized.length - KEEP_RECENT));
        if (toCompress.length >= 4) {
          setSummarizing(true);
          try {
            const summary = await api.post<ConversationSummary>(`/conversations/${convId}/summarize`, {
              gateway_id: gatewayId,
              model: model,
              messages: toCompress.map((m) => ({ role: m.role, content: m.content })),
              first_message_id: toCompress[0].id,
              last_message_id: toCompress[toCompress.length - 1].id,
            });
            setConversationSummaries((prev) => [...prev, summary]);
          } catch {
            // Silent — summarization failure must never block the user
          } finally {
            setSummarizing(false);
          }
        }
      }
    }
  }

  function stopStreaming() {
    abortRef.current?.abort();
  }

  // ── Drag-and-drop handlers ─────────────────────────────────────────────────
  function handleDragEnter(e: React.DragEvent) {
    if (!e.dataTransfer.types.includes("Files")) return;
    e.preventDefault();
    dragCounterRef.current++;
    if (dragCounterRef.current === 1) setIsDragOver(true);
  }

  function handleDragOver(e: React.DragEvent) {
    if (!e.dataTransfer.types.includes("Files")) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "copy";
  }

  function handleDragLeave() {
    dragCounterRef.current--;
    if (dragCounterRef.current === 0) setIsDragOver(false);
  }

  function handleDrop(e: React.DragEvent) {
    e.preventDefault();
    dragCounterRef.current = 0;
    setIsDragOver(false);
    const file = e.dataTransfer.files[0];
    if (!file) return;
    const reader = new FileReader();
    reader.onload = () => {
      const base64 = (reader.result as string).split(",")[1];
      setPendingAttachments((prev) => [
        ...prev,
        { filename: file.name, mime_type: file.type, data: base64 },
      ]);
      focusInput();
    };
    reader.readAsDataURL(file);
  }

  // ── Edit message ───────────────────────────────────────────────────────────
  async function editMessage(id: string, content: string) {
    if (!activeConvId) return;
    await api.patch(`/conversations/${activeConvId}/messages/${id}`, { content }).catch(() => {});
    setMessages((prev) => prev.map((m) => m.id === id ? { ...m, content } : m));
  }

  // ── Regenerate last response ───────────────────────────────────────────────
  async function regenerate() {
    if (!activeConvId || messages.length === 0) return;
    const last = messages[messages.length - 1];
    if (last.role !== "assistant") return;
    // Remove last assistant message and re-send
    await api.delete(`/conversations/${activeConvId}/messages/${last.id}`).catch(() => {});
    setMessages((prev) => prev.slice(0, -1));
    // Re-trigger send with last user message (no new input text, just history)
    const userMsg = [...messages].reverse().find((m) => m.role === "user");
    if (!userMsg) return;
    setInputValue(""); // user message already in history
    // Just re-run inference with current history minus the removed assistant message
    // This is done by calling sendMessage with empty input but the history is already set
    // We need to trigger the streaming directly here
    await sendMessage();
  }

  // ── Save settings to active conversation ──────────────────────────────────
  async function saveSettings() {
    if (!activeConvId) return;
    await api.patch(`/conversations/${activeConvId}`, {
      model,
      system_prompt: drawerSettings.systemPrompt || null,
      temperature: drawerSettings.temperature,
      max_tokens: drawerSettings.maxTokens,
    }).catch(() => {});
  }

  // ── Preset operations ──────────────────────────────────────────────────────
  async function savePreset(name: string) {
    try {
      const res = await api.post<{ id: string }>("/chat-presets", {
        name,
        model,
        system_prompt: drawerSettings.systemPrompt || null,
        temperature: drawerSettings.temperature,
        max_tokens: drawerSettings.maxTokens,
      });
      const preset: ChatPreset = {
        id: res.id,
        name,
        model,
        system_prompt: drawerSettings.systemPrompt || null,
        temperature: drawerSettings.temperature,
        max_tokens: drawerSettings.maxTokens,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };
      setPresets((prev) => [...prev, preset]);
    } catch (e) {
      setError(String(e));
    }
  }

  function applyPreset(preset: ChatPreset) {
    if (preset.model) setModel(preset.model);
    setDrawerSettings({
      systemPrompt: preset.system_prompt ?? "",
      temperature: preset.temperature ?? 0.7,
      maxTokens: preset.max_tokens ?? 2048,
      webSearch: false,
      thinkingBudget: null,
    });
  }

  async function deletePreset(id: string) {
    await api.delete(`/chat-presets/${id}`).catch(() => {});
    setPresets((prev) => prev.filter((p) => p.id !== id));
  }

  function copyToClipboard(text: string) {
    navigator.clipboard.writeText(text).catch(() => {});
  }

  // ── File-saved injection: post a user message so the model knows the file ───
  async function handleFileSaved(filename: string, _content: string, _lang: string) {
    const convId = activeConvId;
    if (!convId) return; // no conversation yet — system prompt will pick up the new file on next load
    const msgContent = `[File saved to project: ${filename}]`;
    try {
      const { id } = await api.post<{ id: string }>(`/conversations/${convId}/messages`, {
        role: "user",
        content: msgContent,
      });
      const injected: ChatMessage = {
        id,
        conversation_id: convId,
        parent_message_id: null,
        role: "user",
        content: msgContent,
        input_tokens: null,
        output_tokens: null,
        cost_usd: null,
        latency_ms: null,
        created_at: new Date().toISOString(),
      };
      setMessages((prev) => [...prev, injected]);
    } catch {
      // non-critical — save already succeeded, just couldn't inject context
    }
  }

  // ── Render ─────────────────────────────────────────────────────────────────
  return (
    <div className={chatS["chat-page"]}>
      <div className={chatS["top-bar"]}>
      {/* Config bar */}
      <div className={chatS["config-bar"]} data-testid="config-bar">
        {tenants.length > 1 && (
          <div className={chatS["config-select"]}>
            <span className={chatS["config-label"]}>Tenant</span>
            <select
              className={s["form-select"]}
              data-testid="config-tenant-select"
              value={tenantId}
              onChange={(e) => setTenantId(e.target.value)}
              style={{ margin: 0 }}
            >
              <option value="">— select —</option>
              {tenants.map((t) => (
                <option key={t.id} value={t.id}>{t.slug}</option>
              ))}
            </select>
          </div>
        )}

        {usePresetMode ? (
          <div className={chatS["preset-options"]} data-testid="config-preset-options">
            {tenantPresets.map((p) => (
              <button
                key={p.id}
                data-testid="config-preset-btn"
                className={`${chatS["preset-btn"]}${selectedPresetId === p.id ? ` ${chatS["preset-btn--selected"]}` : ""}`}
                onClick={() => {
                  setSelectedPresetId(p.id);
                  setGatewayId(p.gateway_id);
                  setModel(p.model);
                }}
              >
                {p.name}
              </button>
            ))}
          </div>
        ) : (
          <>
            <div className={chatS["config-select"]}>
              <span className={chatS["config-label"]}>Gateway</span>
              <select
                className={s["form-select"]}
                value={gatewayId}
                onChange={(e) => setGatewayId(e.target.value)}
                style={{ margin: 0 }}
              >
                <option value="">— select —</option>
                {gateways.map((g) => (
                  <option key={g.id} value={g.id}>{(g as any).slug ?? g.id}</option>
                ))}
              </select>
            </div>

            <div className={chatS["config-model"]}>
              <span className={chatS["config-label"]}>Model</span>
              <ModelPicker
                models={models}
                value={model}
                onChange={setModel}
                runnableProviders={runnableProviders}
              />
            </div>
          </>
        )}

        <div className={chatS["config-divider"]} />

        <button
          className={chatS["icon-btn"]}
          title={drawerSettings.webSearch ? "Web search: ON (click to disable)" : "Enable web search"}
          onClick={() => setDrawerSettings(s => ({ ...s, webSearch: !s.webSearch }))}
          style={drawerSettings.webSearch ? { color: "var(--accent, #0052cc)" } : {}}
        >
          <GlobeIcon />
        </button>

        <button
          className={`${chatS["icon-btn"]} ${chatS["icon-btn--mobile-hidden"]}`}
          title="Download PDF"
          onClick={exportPdf}
          disabled={!activeConvId || messages.length === 0}
        >
          <PdfIcon />
        </button>

        <button
          className={`${chatS["icon-btn"]} ${chatS["icon-btn--mobile-hidden"]}`}
          title={markdownCopied ? "Copied!" : "Copy conversation as Markdown"}
          onClick={copyMarkdown}
          disabled={!activeConvId || messages.length === 0}
          data-cy="copy-markdown-btn"
          style={markdownCopied ? { color: "var(--accent, #0052cc)" } : {}}
        >
          <ClipboardIcon />
        </button>

        <button
          className={`${chatS["icon-btn"]} ${chatS["icon-btn--mobile-hidden"]}`}
          title="Download Markdown"
          onClick={exportMarkdown}
          disabled={!activeConvId || messages.length === 0}
        >
          <DownloadIcon />
        </button>

        {!ghostMode && (
          <button
            className={`${chatS["icon-btn"]} ${chatS["icon-btn--mobile-hidden"]}`}
            title="Share conversation"
            onClick={openShareModal}
            disabled={!activeConvId}
            data-cy="share-btn"
          >
            <ShareIcon />
          </button>
        )}

        {!ghostMode && projectIdParam && (
          <button
            className={`${chatS["icon-btn"]} ${chatS["icon-btn--mobile-hidden"]}`}
            title={sharedInProject ? "Remove from project feed" : "Share to project feed"}
            onClick={toggleShareToProject}
            disabled={!activeConvId || shareProjectLoading}
            data-cy="share-project-btn"
            style={sharedInProject ? { color: "var(--accent, #0052cc)" } : {}}
          >
            {/* People/team icon */}
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" />
              <circle cx="9" cy="7" r="4" />
              <path d="M23 21v-2a4 4 0 0 0-3-3.87" />
              <path d="M16 3.13a4 4 0 0 1 0 7.75" />
            </svg>
          </button>
        )}

        <button
          className={`${chatS["icon-btn"]} ${chatS["icon-btn--mobile-hidden"]}`}
          title={`Memories${memories.length > 0 ? ` (${memories.length})` : ""}`}
          onClick={() => setShowMemories(true)}
          data-cy="memories-btn"
          style={{ position: "relative" }}
        >
          <MemoryIcon />
          {memories.length > 0 && (
            <span style={{ fontSize: "9px", position: "absolute", top: 2, right: 2, background: "var(--accent, #7c3aed)", color: "#fff", borderRadius: "50%", width: 12, height: 12, display: "flex", alignItems: "center", justifyContent: "center", lineHeight: 1 }}>
              {memories.length > 9 ? "9+" : memories.length}
            </span>
          )}
        </button>

        {!ghostMode && (
          <button
            className={`${chatS["icon-btn"]} ${chatS["icon-btn--mobile-hidden"]}`}
            title="Session feedback"
            onClick={() => { setShowFeedback(true); setFeedbackSaved(false); setFeedbackError(null); }}
            disabled={!activeConvId}
          >
            <FlagIcon />
          </button>
        )}

        <button
          className={chatS["icon-btn"]}
          title={ghostMode
            ? "Ghost mode on — conversation not saved or logged. Click to disable."
            : "Enable ghost mode — conversation will not be saved or logged"}
          onClick={toggleGhostMode}
          style={ghostMode ? { color: "var(--accent, #0052cc)", opacity: 1 } : {}}
          data-cy="ghost-mode-toggle"
        >
          👻
        </button>

        <button
          className={chatS["icon-btn"]}
          title="Settings"
          onClick={() => setShowSettings(true)}
        >
          <GearIcon />
        </button>

        <button
          className={`${chatS["icon-btn"]} ${chatS["conv-list-toggle"]}`}
          title="Conversations"
          onClick={() => setShowConvList(true)}
        >
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
            <line x1="3" y1="6" x2="21" y2="6" />
            <line x1="3" y1="12" x2="21" y2="12" />
            <line x1="3" y1="18" x2="21" y2="18" />
          </svg>
        </button>
      </div>

      {error && (
        <div
          style={{
            padding: "6px 16px",
            background: "#fff0f0",
            color: "#c62828",
            fontSize: 13,
            borderBottom: "1px solid #ffcdd2",
            flexShrink: 0,
          }}
        >
          {error}
          <button
            onClick={() => { setError(null); focusInput(); }}
            style={{ marginLeft: 8, background: "none", border: "none", cursor: "pointer", color: "#c62828" }}
          >
            ✕
          </button>
        </div>
      )}

      {guardrailWarning && (
        <div
          data-cy="guardrail-warning"
          style={{
            padding: "6px 16px",
            background: "#fef9c3",
            color: "#854d0e",
            fontSize: 13,
            borderBottom: "1px solid #ca8a04",
            flexShrink: 0,
          }}
        >
          ⚠ {guardrailWarning}
          <button
            onClick={() => { setGuardrailWarning(null); focusInput(); }}
            style={{ marginLeft: 8, background: "none", border: "none", cursor: "pointer", color: "#854d0e" }}
          >
            ✕
          </button>
        </div>
      )}

      {ghostMode && (
        <div
          style={{
            padding: "4px 0",
            background: "#1a1a2e",
            color: "#8888aa",
            fontSize: 12,
            textAlign: "center",
            letterSpacing: "0.03em",
            flexShrink: 0,
          }}
          data-cy="ghost-banner"
        >
          👻 Ghost mode — this conversation is not saved and will not be logged
        </div>
      )}
      </div>{/* /top-bar */}

      <div className={chatS["chat-body"]}>
        {/* Conversation sidebar — mobile backdrop */}
        {showConvList && (
          <div
            className={chatS["conv-sidebar-backdrop"]}
            onClick={() => { setShowConvList(false); focusInput(); }}
          />
        )}

        {/* Conversation sidebar */}
        <div className={`${chatS["conv-sidebar"]} ${showConvList ? chatS["conv-sidebar--open"] : ""}`}>
          {activeProject && (
            <div style={{ padding: "8px 12px", borderBottom: "1px solid var(--card-border)", background: "var(--accent-subtle)", fontSize: 12 }}>
              <a href={`/projects/${activeProject.id}`} style={{ fontWeight: 600, color: "var(--accent)", textDecoration: "none" }}>{activeProject.icon} {activeProject.name}</a>
              {" — "}
              <a href="/projects" style={{ color: "var(--text-secondary)" }}>all projects</a>
            </div>
          )}
          <ConversationList
            conversations={activeProject
              ? conversations.filter((c) => c.project_id === activeProject.id)
              : conversations.filter((c) => !c.project_id)
            }
            activeId={activeConvId}
            onSelect={(id) => { setSearchParams((prev) => { const p = new URLSearchParams(prev); p.set("conv", id); return p; }); loadConversation(id); setShowConvList(false); }}
            onCreate={() => { createConversation(); setShowConvList(false); }}
            onRename={renameConversation}
            onDelete={deleteConversation}
            onStar={starConversation}
            onArchive={archiveConversation}
            onUnarchive={unarchiveConversation}
            showArchived={showArchived}
            onToggleArchived={toggleArchivedView}
            creating={creating}
            streamingConvId={streamingConvId}
            newChatLabel={activeProject ? "New project chat" : undefined}
          />
        </div>

        {/* Message area */}
        <div
          className={chatS["message-area"]}
          style={{ position: "relative" }}
          onDragEnter={handleDragEnter}
          onDragOver={handleDragOver}
          onDragLeave={handleDragLeave}
          onDrop={handleDrop}
        >
          {/* Project context banner */}
          {activeProject && (
            <div
              className={chatS["project-banner"]}
              style={{ borderLeft: `3px solid ${activeProject.color || "var(--accent)"}` }}
            >
              <a
                href={`/projects/${activeProject.id}`}
                className={chatS["project-banner-name"]}
              >
                <span>{activeProject.icon}</span>
                <span>{activeProject.name}</span>
              </a>
              {projectKnowledge.length > 0 && (
                <span className={chatS["project-banner-meta"]}>
                  · {projectKnowledge.length} file{projectKnowledge.length !== 1 ? "s" : ""}
                </span>
              )}
              {activeProject.instructions && (
                <button
                  className={chatS["project-banner-meta"]}
                  style={{ background: "none", border: "none", cursor: "pointer", padding: 0, font: "inherit", textDecoration: "underline", textDecorationStyle: "dotted", textUnderlineOffset: 2 }}
                  onClick={() => setShowInstructionsModal(true)}
                  title="Click to view project instructions"
                >
                  · instructions active
                </button>
              )}
              <div className={chatS["project-banner-actions"]}>
                {projectKnowledge.length > 0 && (
                  <button
                    className={chatS["project-banner-link"]}
                    style={{ background: "none", border: "none", cursor: "pointer", padding: 0, font: "inherit" }}
                    onClick={() => setShowFilesPanel((v) => !v)}
                    title="View project files"
                  >
                    📎 Files ({projectKnowledge.length})
                  </button>
                )}
                <a href={`/projects/${activeProject.id}`} className={chatS["project-banner-link"]}>Open project</a>
                <a href="/chat" className={chatS["project-banner-exit"]}>Exit project ×</a>
              </div>
            </div>
          )}
          {showFilesPanel && activeProject && projectKnowledge.length > 0 && (
            <div className={chatS["files-panel"]} data-cy="chat-files-panel">
              <div className={chatS["files-panel-header"]}>
                <span>Project Files</span>
                <button
                  className={chatS["files-panel-close"]}
                  onClick={() => setShowFilesPanel(false)}
                  type="button"
                  aria-label="Close files panel"
                >×</button>
              </div>
              <div className={chatS["files-panel-list"]}>
                {projectKnowledge.map((f) => (
                  <button
                    key={f.id}
                    className={chatS["files-panel-item"]}
                    onClick={() => setPreviewFileFromChat(f)}
                    type="button"
                    data-cy="chat-file-item"
                  >
                    <span className={chatS["files-panel-item-name"]}>📎 {f.filename}</span>
                    <span className={chatS["files-panel-item-meta"]}>{f.token_count.toLocaleString()} tokens</span>
                  </button>
                ))}
              </div>
            </div>
          )}
          {isDragOver && (
            <div className={chatS["drop-overlay"]}>
              <div className={chatS["drop-zone"]}>
                <span className={chatS["drop-icon"]}>📎</span>
                <span className={chatS["drop-label"]}>Drop file here</span>
                <span className={chatS["drop-hint"]}>
                  Images · PDF · DOCX · XLSX · ODS · CSV · TXT · MD
                </span>
              </div>
            </div>
          )}
          <div className={chatS["thread-artifact-row"]}>
            <MessageThread
              messages={messages}
              streamingContent={activeConvId === streamingConvId ? streamingContent : null}
              isStreaming={isStreaming && activeConvId === streamingConvId}
              processingStatus={activeConvId === streamingConvId ? processingStatus : null}
              streamingThinkingDurationMs={activeConvId === streamingConvId ? streamingThinkingDurationMs : null}
              projectId={projectIdParam}
              onFileSaved={projectIdParam ? handleFileSaved : null}
              onOpenArtifact={setActiveArtifact}
              onCopy={copyToClipboard}
              onEdit={editMessage}
              onRegenerate={regenerate}
              activeProject={activeProject}
              projectKnowledge={projectKnowledge}
            />
            {activeArtifact && (
              <ArtifactPanel
                artifact={activeArtifact}
                isStreaming={isStreaming && activeConvId === streamingConvId}
                onClose={() => setActiveArtifact(null)}
                projectId={projectIdParam ?? undefined}
                onSave={projectIdParam ? handleFileSaved : undefined}
                onUpdateArtifact={setActiveArtifact}
                onSendRevision={(filename, code, instruction) => {
                  const lang = activeArtifact.lang;
                  const msg = `Re: \`${filename}\`\n\n\`\`\`${lang}\n${code}\n\`\`\`\n\n${instruction}`;
                  setInputValue(msg);
                  chatInputRef.current?.focus();
                }}
              />
            )}
          </div>

          <ChatInput
            ref={chatInputRef}
            value={inputValue}
            onChange={setInputValue}
            onSend={sendMessage}
            onStop={stopStreaming}
            isStreaming={isStreaming}
            disabled={!gatewayId || !model || creating}
            projectContext={activeProject ? { icon: activeProject.icon, name: activeProject.name, color: activeProject.color } : undefined}
            pendingAttachments={pendingAttachments}
            onAttach={(att) => setPendingAttachments((prev) => [...prev, att])}
            onRemoveAttachment={(idx) =>
              setPendingAttachments((prev) => prev.filter((_, i) => i !== idx))
            }
            commands={allCommands}
            onCommandSelect={handleCommandSelect}
          />
        </div>
      </div>

      {/* Settings drawer */}
      {showSettings && (
        <SettingsDrawer
          settings={drawerSettings}
          onChange={setDrawerSettings}
          onSave={saveSettings}
          onClose={() => { setShowSettings(false); focusInput(); }}
          presets={presets}
          onApplyPreset={applyPreset}
          onSavePreset={savePreset}
          onDeletePreset={deletePreset}
          supportsThinking={supportsThinking}
        />
      )}

      {/* Variable fill modal for slash commands */}
      {pendingCommand && (
        <VariableFillModal
          command={pendingCommand}
          onInsert={(text) => { setInputValue(text); setPendingCommand(null); focusInput(); }}
          onCancel={() => { setPendingCommand(null); focusInput(); }}
        />
      )}

      {/* Feedback modal */}
      {showFeedback && (
        <Modal
          title="Session Feedback"
          onClose={() => { setShowFeedback(false); focusInput(); }}
          error={feedbackError}
        >
          <div className={s["form-group"]}>
            <label className={s["form-label"]}>
              How would you rate this session? <em>(1 = best, 5 = worst)</em>
            </label>
            <div className={s["picker-options"]}>
              {[1, 2, 3, 4, 5].map((n) => (
                <button
                  key={n}
                  type="button"
                  className={`${s["picker-btn"]} ${feedbackRating === n ? s["picker-btn--selected"] : ""}`}
                  onClick={() => setFeedbackRating(n)}
                >{n}</button>
              ))}
            </div>
          </div>
          <div className={s["form-group"]}>
            <label className={s["form-label"]}>Comments</label>
            <textarea
              className={s["form-input"]}
              rows={6}
              placeholder="What could be better? (optional)"
              value={feedbackComment}
              onChange={(e) => setFeedbackComment(e.target.value)}
              style={{ resize: "vertical" }}
            />
          </div>
          <div className={s["form-actions"]}>
            {feedbackSaved && (
              <span className={s["form-hint"]} style={{ color: "var(--badge-success-text)", marginRight: "auto" }}>
                Saved ✓
              </span>
            )}
            <button
              className={`${s.btn} ${s["btn--secondary"]}`}
              onClick={() => { setShowFeedback(false); focusInput(); }}
            >
              Cancel
            </button>
            <button
              className={`${s.btn} ${s["btn--primary"]}`}
              onClick={saveFeedback}
              disabled={feedbackRating === null || feedbackSaving}
            >
              {feedbackSaving ? "Saving…" : "Save feedback"}
            </button>
          </div>
        </Modal>
      )}

      {showShareModal && (
        <Modal title="Share conversation" onClose={() => setShowShareModal(false)}>
          {shareLoading ? (
            <p style={{ color: "var(--text-secondary)", fontSize: 14 }}>Generating link…</p>
          ) : shareUrl ? (
            <>
              <div style={{ display: "flex", gap: 8, marginBottom: 12 }}>
                <input
                  readOnly
                  value={shareUrl}
                  data-cy="share-url-input"
                  style={{
                    flex: 1, padding: "7px 10px", fontSize: 13,
                    border: "1px solid var(--card-border)", borderRadius: 6,
                    background: "var(--input-bg)", color: "var(--text-primary)",
                    outline: "none",
                  }}
                  onFocus={e => e.target.select()}
                />
                <button
                  className={s["btn"] + " " + s["btn--primary"] + " " + s["btn--sm"]}
                  data-cy="share-copy-btn"
                  onClick={() => {
                    navigator.clipboard.writeText(shareUrl).then(() => {
                      setShareCopied(true);
                      setTimeout(() => setShareCopied(false), 2000);
                    });
                  }}
                >
                  {shareCopied ? "Copied!" : "Copy"}
                </button>
              </div>
              <div style={{ display: "flex", justifyContent: "flex-end" }}>
                <button
                  className={s["btn"] + " " + s["btn--danger"] + " " + s["btn--sm"]}
                  data-cy="share-revoke-btn"
                  onClick={revokeShare}
                >
                  Revoke link
                </button>
              </div>
            </>
          ) : (
            <p style={{ color: "var(--text-secondary)", fontSize: 14 }}>
              Failed to generate share link.
            </p>
          )}
        </Modal>
      )}

      {previewFileFromChat && activeProject && (
        <ProjectFilePreview
          file={previewFileFromChat}
          projectId={activeProject.id}
          onClose={() => setPreviewFileFromChat(null)}
        />
      )}

      {showInstructionsModal && activeProject?.instructions && (
        <Modal title="Project Instructions" onClose={() => setShowInstructionsModal(false)}>
          <pre style={{ whiteSpace: "pre-wrap", wordBreak: "break-word", fontFamily: "inherit", fontSize: 14, lineHeight: 1.6, margin: 0, color: "var(--text-primary)" }}>
            {activeProject.instructions}
          </pre>
        </Modal>
      )}

      {showMemories && (
        <MemoriesPanel
          memories={memories}
          activeConvId={activeConvId}
          onClose={() => setShowMemories(false)}
          onMemoriesChange={setMemories}
          onConvMemoryDisabledChange={(convId, disabled) => {
            setConversations(prev => prev.map(c => c.id === convId ? { ...c, memory_disabled: disabled ? 1 : 0 } : c));
          }}
        />
      )}

      {memToast && (
        <div data-cy="memory-toast" style={{
          position: "fixed", bottom: 80, left: "50%", transform: "translateX(-50%)",
          background: "var(--surface-2, #222)", color: "var(--text-primary, #fff)",
          padding: "8px 16px", borderRadius: 8, fontSize: 13, zIndex: 9999,
          boxShadow: "0 2px 12px rgba(0,0,0,0.25)", pointerEvents: "none",
        }}>
          {memToast}
        </div>
      )}

      {summarizing && (
        <div data-cy="summarizing-toast" style={{
          position: "fixed", bottom: 80, left: "50%", transform: "translateX(-50%)",
          background: "var(--surface-2, #222)", color: "var(--text-secondary, #aaa)",
          padding: "6px 14px", borderRadius: 8, fontSize: 12, zIndex: 9998,
          boxShadow: "0 2px 12px rgba(0,0,0,0.25)", pointerEvents: "none",
          display: "flex", alignItems: "center", gap: 8,
        }}>
          <span style={{ display: "inline-block", width: 10, height: 10, borderRadius: "50%", border: "1.5px solid var(--text-secondary)", borderTopColor: "var(--accent, #0052cc)", animation: "spin 0.7s linear infinite" }} />
          Summarizing earlier context…
        </div>
      )}

      {conversationSummaries.length > 0 && (
        <div data-cy="summary-indicator" style={{
          position: "fixed", bottom: 44, left: "50%", transform: "translateX(-50%)",
          background: "var(--card-bg)", color: "var(--text-secondary)",
          padding: "3px 10px", borderRadius: 6, fontSize: 11, zIndex: 9997,
          border: "1px solid var(--card-border)", pointerEvents: "none",
        }}>
          ∞ {conversationSummaries.length} earlier turn{conversationSummaries.length > 1 ? "s" : ""} summarized
        </div>
      )}
    </div>
  );
}
