import { useCallback, useEffect, useRef, useState } from "react";

function GhostModeIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d="M12 2C8.13 2 5 5.13 5 9v8l2-2 2 2 2-2 2 2 2-2 2 2V9c0-3.87-3.13-7-7-7z"/>
      <line x1="2" y1="2" x2="22" y2="22"/>
    </svg>
  );
}

function PaperclipIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" style={{ flexShrink: 0 }}>
      <path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66L9.41 17.41a2 2 0 0 1-2.83-2.83l8.49-8.48"/>
    </svg>
  );
}
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
import ArtifactPanel, { type Artifact, type ArtifactTab } from "../components/ArtifactPanel";
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
 *  Returns e.g. "Claude (claude-sonnet-4-6)" or "Qwen (qwen3.6-35b-a3b)". */
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
    "## Project files\n\n" +
    "You have read_file and write_file tools available. Use them to access files " +
    "in this project's knowledge base.\n\n" +
    "When the user asks to update an existing file, ALWAYS read it first with read_file, " +
    "then write the complete updated file with write_file."
  );
  if (knowledgeFiles.length > 0) {
    const fileList = knowledgeFiles.map((f) => `- ${f.filename}`).join("\n");
    parts.push(
      "## Project Knowledge Files\n\n" +
      "The following files are available in this project's knowledge base:\n\n" +
      fileList
    );
  }
  return parts.join("\n\n");
}

/** Map internal gateway error strings to a user-friendly message. */
function sanitizeGatewayError(msg: string): string {
  if (/parse_response|json decode|internal_error|Internal gateway error/i.test(msg)) {
    return "Something went wrong — please try again.";
  }
  return msg;
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
    "Code and structured output:\n" +
    "- Always wrap code snippets, configuration examples, CLI output, and log excerpts in fenced code blocks (```language).\n" +
    "- Always wrap ASCII art, ASCII diagrams, aligned tables, and any whitespace-dependent layout in fenced code blocks (```). These MUST use a code fence — never render them as plain text paragraphs, because proportional fonts will break alignment.\n" +
    "- For tabular data with more than 3 columns or wide content, prefer a fenced code block over a markdown table to preserve alignment.\n" +
    "- When asked to create a file, emit it as: <write_file filename=\"name.ext\">content</write_file>. This renders as an interactive file card the user can view, copy, or download.\n" +
    "- Never wrap your entire answer, analysis, report, or explanation in a fenced code block. Fences are for the content types listed above — code, config, CLI output, and file contents — not for the prose response itself. Structured prose with headers and lists must be written as plain markdown, never enclosed in a code fence.\n\n" +
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
    thinkingBudget: null,
  });

  // ── Chat input ─────────────────────────────────────────────────────────────
  const chatInputRef = useRef<ChatInputHandle>(null);
  const focusInput = useCallback(() => { chatInputRef.current?.focus(); }, []);
  const [inputValue, setInputValue] = useState("");
  const [pendingAttachments, setPendingAttachments] = useState<PendingAttachment[]>([]);
  const [processingStatus, setProcessingStatus] = useState<string | null>(null);
  // Tokens before the last compaction — passed as X-AIG-Compaction-Baseline so the
  // gateway can log per-turn savings. Resets when the conversation changes.
  const [compactionBaseline, setCompactionBaseline] = useState<number | null>(null);

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
  const [error, setError]     = useState<string | null>(null);
  const [warning, setWarning] = useState<string | null>(null);
  const [guardrailWarning, setGuardrailWarning] = useState<string | null>(null);

  // ── Ghost mode — no DB writes, no request log ──────────────────────────────
  const [ghostMode, setGhostMode] = useState(false);

  function toggleGhostMode() {
    const next = !ghostMode;
    setGhostMode(next);
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

  // ── Artifact panel — multi-tab + versioning ────────────────────────────────
  // artifactMap: key → ordered array of versions (oldest first)
  // artifactVersionIndex: key → currently viewed version index
  const [artifactMap,          setArtifactMap]          = useState<Map<string, Artifact[]>>(new Map());
  const [activeArtifactKey,    setActiveArtifactKey]    = useState<string | null>(null);
  const [artifactVersionIndex, setArtifactVersionIndex] = useState<Map<string, number>>(new Map());

  /** Called by ArtifactCard onClick — opens the artifact, version-stacking if key already exists. */
  function handleOpenArtifact(artifact: Artifact) {
    const key = artifact.key ?? artifact.filename ?? `${artifact.lang}:${artifact.code.trim().slice(0, 60)}`;
    const tagged = { ...artifact, key };
    // Use a single updater pass to avoid stale-closure issues between the two set calls.
    // We compute the new version index from the CURRENT map inside setArtifactMap's updater,
    // then flush setArtifactVersionIndex in the same batch.
    let newVersionIndex = 0;
    setArtifactMap(prev => {
      const next     = new Map(prev);
      const existing = next.get(key) ?? [];
      const lastCode = existing[existing.length - 1]?.code;
      if (lastCode === artifact.code) {
        // Identical — no new version; keep current index
        newVersionIndex = existing.length - 1;
        return prev;
      }
      next.set(key, [...existing, tagged]);
      newVersionIndex = existing.length; // index of the newly appended version
      return next;
    });
    setArtifactVersionIndex(prev => {
      const next = new Map(prev);
      next.set(key, newVersionIndex);
      return next;
    });
    setActiveArtifactKey(key);
  }

  /** Push an updated artifact as a new version (called by ArtifactPanel "Update Artifact"). */
  function handleUpdateArtifact(updated: Artifact) {
    const key = updated.key ?? activeArtifactKey;
    if (!key) return;
    const tagged = { ...updated, key };
    let newIdx = 0;
    setArtifactMap(prev => {
      const next = new Map(prev);
      const existing = next.get(key) ?? [];
      next.set(key, [...existing, tagged]);
      newIdx = existing.length; // index of the newly appended version
      return next;
    });
    setArtifactVersionIndex(prev => {
      const next = new Map(prev);
      next.set(key, newIdx);
      return next;
    });
  }

  /** Build the ArtifactTab array for the panel from current state. */
  const artifactTabs: ArtifactTab[] = Array.from(artifactMap.entries()).map(([key, versions]) => ({
    key,
    label: versions[0]?.filename ?? versions[0]?.lang?.toUpperCase() ?? key,
    versions,
    versionIndex: artifactVersionIndex.get(key) ?? versions.length - 1,
  }));

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
    // Memory load is scope-reactive (see projectIdParam useEffect below)
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

  // ── Memory pool: reload when scope changes (project ↔ standalone) ─────────
  // Clear immediately to prevent stale-scope injection during the reload window.
  // Wrong-scope injection is a data leak; empty injection is safely recoverable.
  useEffect(() => {
    setMemories([]);
    const url = projectIdParam
      ? `/memories?project_id=${encodeURIComponent(projectIdParam)}`
      : `/memories`;
    api.get<ChatMemory[]>(url).then(setMemories).catch(() => setMemories([]));
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
    setGhostMode(false);
    setCompactionBaseline(null); // reset per-conversation compaction baseline
    loadingConvRef.current = id;
    setArtifactMap(new Map());
    setActiveArtifactKey(null);
    setArtifactVersionIndex(new Map());
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
    setGhostMode(false);
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
  async function sendMessage(overrideText?: string) {
    const text = (overrideText ?? inputValue).trim();
    if (!text && pendingAttachments.length === 0) return;

    // Snapshot scope at send-time so auto-extracted <memory> tags are written to the
    // correct pool even if the user navigates away before the stream completes.
    const scopeProjectId = projectIdParam;

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

    // Fetch token on-demand if the background effect hasn't completed yet.
    // IMPORTANT: use the returned token directly — do NOT fall through to
    // `let currentTok = playToken` below, because setPlayToken() is async
    // and `playToken` in this closure is still null until the next render.
    let currentTok: PlaygroundToken | null = playToken;
    if (!currentTok) {
      currentTok = await refreshToken(effectiveGatewayId);
      if (!currentTok) { setError("No gateway token — select a gateway"); return; }
    }

    // Refresh token if expiring soon OR if it belongs to a different gateway
    // (the latter can happen when the user switches presets before the async refresh completes)
    const tokenAge = tokenExpiresAt.current
      ? tokenExpiresAt.current.getTime() - Date.now()
      : null;
    const currentGateway = gateways.find((g) => g.id === effectiveGatewayId);
    const tokenMismatch = currentGateway && currentTok && currentTok.gateway_slug !== currentGateway.slug;
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
    let attachmentWarning: string | null = null;
    if (pendingAttachments.length > 0) {
      // Show message immediately with image thumbnails so user gets feedback during async processing
      const optimisticBlocks: object[] = text ? [{ type: "text", text }] : [];
      for (const att of pendingAttachments) {
        if (att.mime_type.startsWith("image/")) {
          optimisticBlocks.push({ type: "image_url", image_url: { url: `data:${att.mime_type};base64,${att.data}` } });
        } else {
          optimisticBlocks.push({ type: "text", text: att.filename });
        }
      }
      const tempUserMsgOptimistic: ChatMessage = {
        id: "__temp_user__",
        conversation_id: convId,
        parent_message_id: null,
        role: "user",
        content: JSON.stringify(optimisticBlocks),
        input_tokens: null,
        output_tokens: null,
        cost_usd: null,
        latency_ms: null,
        created_at: Math.floor(Date.now() / 1000),
      };
      setMessages((prev) => [...prev, tempUserMsgOptimistic]);
      setInputValue("");
      focusInput();

      // Restore input + remove optimistic message on any processing error
      const undoOptimistic = () => {
        setMessages((prev) => prev.filter((m) => m.id !== "__temp_user__"));
        setInputValue(text);
        setPendingAttachments(pendingAttachments);
      };

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
              const res = await api.post<{ text: string; warning?: string }>("/chat/files", {
                gateway_id: effectiveGatewayId,
                filename: att.filename,
                mime_type: att.mime_type,
                data: att.data,
                extract_text: true,
              });
              description = res.text;
              if (res.warning) attachmentWarning = res.warning;
            } catch (e) {
              undoOptimistic();
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
              undoOptimistic();
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
            undoOptimistic();
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
              undoOptimistic();
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
              undoOptimistic();
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
        undoOptimistic();
        setError(
          `Unsupported file type(s): ${unsupported.join(", ")}. ` +
          `Supported: images (JPEG, PNG, GIF, WebP), PDF, plain text, Markdown (.md), Word (.docx), CSV, TSV, Excel (.xlsx, .xlsm), OpenDocument (.ods), PowerPoint (.pptx).`
        );
        return;
      }
      userContent = JSON.stringify(blocks);
      // Replace optimistic thumbnail content with the real processed content
      setMessages((prev) =>
        prev.map((m) => m.id === "__temp_user__" ? { ...m, content: userContent } : m)
      );
    } else {
      userContent = text;
    }

    // Optimistically append user message to UI (attachment path already did this above)
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
      created_at: Math.floor(Date.now() / 1000),
    };
    if (pendingAttachments.length === 0) {
      setMessages((prev) => [...prev, tempUserMsg]);
      setInputValue("");
      focusInput();
    }
    setPendingAttachments([]);
    setError(null);
    setWarning(attachmentWarning);

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
    const memHeader = projectIdParam
      ? "## What I know about this project"
      : "## What I know about you";
    const memBlock = (!memoryDisabled && memories.length > 0)
      ? `\n\n---\n${memHeader}\nApply the following in your responses:\n` + memories.map(m => `- ${m.content}`).join("\n")
      : "";
    const memInstruction = !memoryDisabled
      ? (projectIdParam
          ? "\n\nWhen the user states a project-relevant fact worth remembering (coding conventions, tech stack decisions, team preferences), emit it exactly as:\n<memory type=\"fact|preference|instruction\">concise fact in third-person</memory>\nThis tag is invisible to the user. Use sparingly — only for durable project facts."
          : "\n\nWhen the user states a personal fact, preference, or instruction worth remembering across conversations, emit it exactly as:\n<memory type=\"fact|preference|instruction\">concise fact in third-person</memory>\nThis tag is invisible to the user. Use sparingly — only for durable facts.")
      : "";
    const systemContent = (drawerSettings.systemPrompt || "") + memBlock + memInstruction;
    // Test hook: expose the system content for E2E inspection without HTTP body capture.
    (window as unknown as Record<string, unknown>).__aig_last_system_content__ = systemContent;

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
    let piiMaskedInfo: import("src/api/types").PiiMaskedInfo | undefined;
    // request_log.id of the LAST leg (the one whose final content the user
    // sees). Captured from the X-Request-Id response header — exposed via
    // Access-Control-Expose-Headers in nginx.{docker,int}.conf. Used when
    // the user clicks "Report" so triage can JOIN to request_log.
    let lastRequestLogId: string | null = null;

    // Build MCP tools header for server-side tool_loop
    const mcpToolsHeader = mcpTools.length > 0
      ? JSON.stringify(mcpTools.map(({ tool, connectorId }) => ({
          type: "function",
          connector_id: connectorId,
          name: tool.name,
          function: { name: tool.name, description: tool.description ?? "", parameters: tool.inputSchema },
        })))
      : undefined;

    const reqHeaders = Object.fromEntries(
      Object.entries({
        "Content-Type": "application/json",
        Authorization: `Bearer ${tok.token}`,
        ...(ghostMode ? { "x-aig-collect-log": "false" } : {}),
        ...(needsSkill ? { "x-aig-skill": needsSkill } : {}),
        "x-aig-web-search": "1",
        ...(drawerSettings.thinkingBudget !== null
          ? { "x-aig-thinking-budget": String(drawerSettings.thinkingBudget) }
          : {}),
        ...(projectIdParam ? { "x-project-id": projectIdParam } : {}),
        ...(mcpToolsHeader ? { "x-mcp-tools": mcpToolsHeader } : {}),
        // Tell the gateway how large the context was before compaction so it can
        // compute and log per-turn token savings for the compaction impact report.
        ...(compactionBaseline !== null
          ? { "x-aig-compaction-baseline": String(compactionBaseline) }
          : {}),
      }).filter(([, v]) => v !== undefined)
    ) as Record<string, string>;

    let continueCount = 0;
    const MAX_CONTINUATIONS = 10;

    streaming: while (true) {
      // On continuation (max_tokens), append assistant partial + "Continue" prompt
      const reqMessages = continueCount === 0
        ? apiMessages
        : [...apiMessages, { role: "assistant", content: accumulated }, { role: "user", content: "Continue" }];

      let finishReason: string | null = null;

      const reqBody = {
        model: effectiveModel,
        messages: reqMessages,
        // Anthropic rejects requests with both temperature and thinking enabled
        ...(drawerSettings.thinkingBudget === null ? { temperature: drawerSettings.temperature } : {}),
        max_tokens: drawerSettings.maxTokens,
        stream: true,
        // Tools are injected server-side by tool_loop.lua based on X-Project-Id,
        // X-MCP-Tools, X-AIG-Web-Search headers.
      };

      // ── Full request/response trace ─────────────────────────────────────
      console.group(`[chat_trace] leg ${continueCount}`);
      console.log("[REQ] POST", compatUrl);
      console.log("[REQ] model:", effectiveModel, "| messages:", reqMessages.length, "| stream:", true);
      if (continueCount > 0) {
        console.log("[REQ] continuation: auto-continue (max_tokens), count:", continueCount);
      }

      const allChunks: unknown[] = [];

      try {
        const res = await fetch(compatUrl, {
          method: "POST",
          signal: abort.signal,
          headers: reqHeaders,
          body: JSON.stringify(reqBody),
        });

        if (!res.ok) {
          const body = await res.text().catch(() => "");
          let msg = `HTTP ${res.status}`;
          try { msg = JSON.parse(body)?.error?.message ?? JSON.parse(body)?.error ?? msg; } catch { /* */ }
          console.error("[RES] HTTP error", res.status, body.slice(0, 500));
          console.groupEnd();
          throw new Error(sanitizeGatewayError(msg));
        }

        console.log("[RES] status:", res.status,
          "| content-type:", res.headers.get("content-type"),
          "| x-aig-provider:", res.headers.get("x-aig-provider"),
          "| x-aig-cache:", res.headers.get("x-aig-cache"));

        // Capture the X-Request-Id header — equals request_log.id (see
        // src/observability/logger.lua: id = ctx.request_id). Updated on
        // each leg so the last successful leg's id wins, which is what the
        // user is reading when they click Report.
        const reqId = res.headers.get("x-request-id");
        if (reqId) lastRequestLogId = reqId;

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
            console.log("[RES] stream done | receivedDone:", receivedDone,
              "| finishReason:", finishReason,
              "| accumulatedChars:", accumulated.length,
              "| chunks:", allChunks.length,
              "| elapsed:", Math.round(performance.now() - legStart), "ms");
            console.log("[RES] accumulated text:", accumulated.slice(0, 500) + (accumulated.length > 500 ? "…" : ""));
            if (allChunks.length <= 20) {
              console.log("[RES] all chunks:", JSON.stringify(allChunks));
            } else {
              console.log("[RES] first 5 chunks:", JSON.stringify(allChunks.slice(0, 5)));
              console.log("[RES] last 5 chunks:", JSON.stringify(allChunks.slice(-5)));
            }
            console.groupEnd();
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
              allChunks.push(chunk);
              const delta = chunk?.choices?.[0]?.delta?.content;
              if (delta != null) {
                if (!accumulated) setProcessingStatus(null); // first token — hide status
                accumulated += delta;
                // While a <write_file> tag is open but not yet closed, hide its
                // raw content from the user (ReactMarkdown would swallow it as
                // an unknown HTML element, making the cursor vanish).  Show a
                // "Writing file…" status instead.
                const openWriteIdx = accumulated.lastIndexOf("<write_file ");
                const closeWriteIdx = accumulated.lastIndexOf("</write_file>");
                if (openWriteIdx >= 0 && (closeWriteIdx < 0 || closeWriteIdx < openWriteIdx)) {
                  // Extract filename from the open tag for the status message
                  const fnMatch = accumulated.slice(openWriteIdx).match(/filename="([^"]+)"/);
                  const fn = fnMatch ? fnMatch[1] : "file";
                  setProcessingStatus(`Writing ${fn}…`);
                  setStreamingContent(accumulated.slice(0, openWriteIdx).trim());
                } else {
                  setStreamingContent(accumulated);
                }
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
              // Tool calls are handled server-side by tool_loop.lua.
              // No client-side tool_calls accumulation needed.
              const reason = chunk?.choices?.[0]?.finish_reason;
              if (reason) finishReason = reason;
              const usage = chunk?.usage;
              if (usage) {
                inputTokens  = (inputTokens  ?? 0) + (usage.prompt_tokens     ?? 0);
                outputTokens = (outputTokens ?? 0) + (usage.completion_tokens ?? 0);
                costUsd      = (costUsd      ?? 0) + (usage.cost_usd          ?? 0);
              }
              // Context compaction event — Anthropic summarised the conversation history.
              // Store tokens_before as the baseline for future per-turn savings logging.
              if (chunk?.aig_status === "compacted") {
                const tokensBefore = chunk.tokens_before as number | undefined;
                if (tokensBefore && tokensBefore > 0) setCompactionBaseline(tokensBefore);
                setProcessingStatus("Context compacted — summary saved");
              }
              // Gateway web-search status event (emitted by web_search.lua before fetching)
              if (chunk?.aig_status === "fetching") {
                const n = chunk.count;
                setProcessingStatus(`Fetching ${n ?? ""} URL${n !== 1 ? "s" : ""}…`.trim());
              }
              // Gateway url-fetch status event (emitted by url_fetch.lua before fetching)
              if (chunk?.aig_status === "fetching_url") {
                const n = chunk.count;
                setProcessingStatus(`Fetching ${n ?? ""} URL${n !== 1 ? "s" : ""}…`.trim());
              }
              // Server-side tool_loop status events
              if (chunk?.aig_status === "tool_call") {
                const toolStatusLabels: Record<string, string> = {
                  read_file:  "Reading",
                  write_file: "Writing",
                  fetch_url:  "Fetching",
                  web_search: "Searching",
                };
                const label = toolStatusLabels[chunk.tool as string] ?? `${chunk.tool}`;
                const argStr = chunk.args?.filename ?? chunk.args?.url ?? chunk.args?.query ?? "";
                setProcessingStatus(`${label}${argStr ? ` ${argStr}` : ""}…`);
              }
              if (chunk?.aig_status === "tool_result") {
                const tool = chunk.tool as string;
                if (tool === "write_file") {
                  // Append a visible note about the save
                  const fn = chunk.filename ?? "";
                  if (fn) accumulated += `\n\n> File saved to project: \`${fn}\`\n`;
                }
              }
              // PII masking event — gateway masked PII in the user message
              if (chunk?.aig_status === "pii_masked") {
                piiMaskedInfo = {
                  types: chunk.types as string | null | undefined,
                  custom_count: chunk.custom_count as number | null | undefined,
                };
              }
              // Native Anthropic tool-use event (forwarded by on_compat_chunk in upstream.lua)
              if (chunk?.aig_tool_call) {
                const toolLabels: Record<string, string> = {
                  web_search:     "Searching the web…",
                  fetch_url:      "Fetching URL…",
                  read_file:      "Reading file…",
                  write_file:     "Writing file…",
                  computer_use:   "Using computer…",
                  code_execution: "Running code…",
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
          setError(sanitizeGatewayError(String(err)));
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

      // All tool execution (read_file, write_file, fetch_url, web_search, MCP)
      // is now handled server-side by tool_loop.lua. The client only receives
      // the final streamed text + status events.

      console.log("[FLOW] breaking out of streaming loop | finishReason:", finishReason,
        "| accumulatedChars:", accumulated.length,
        "| continueCount:", continueCount);
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
          api.post<ChatMemory>("/memories", {
              content, type: mtype, source: "auto",
              ...(scopeProjectId ? { project_id: scopeProjectId } : {}),
            })
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
        created_at: Math.floor(Date.now() / 1000),
        attachments: [],
        ...(piiMaskedInfo ? { pii_masked_info: piiMaskedInfo } : {}),
        ...(lastRequestLogId ? { request_log_id: lastRequestLogId } : {}),
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
          created_at: Math.floor(Date.now() / 1000),
          attachments: [],
          ...(piiMaskedInfo ? { pii_masked_info: piiMaskedInfo } : {}),
          ...(lastRequestLogId ? { request_log_id: lastRequestLogId } : {}),
        };
        if (activeConvIdRef.current === convId) {
          setMessages((prev) => [...prev, assistantMsg]);
        }
        // Update conversation updated_at in list
        setConversations((prev) =>
          prev.map((c) =>
            c.id === convId ? { ...c, updated_at: Math.floor(Date.now() / 1000) } : c
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
  async function regenerate(reason?: string) {
    if (!activeConvId || messages.length === 0) return;
    const last = messages[messages.length - 1];
    if (last.role !== "assistant") return;
    await api.delete(`/conversations/${activeConvId}/messages/${last.id}`).catch(() => {});
    setMessages((prev) => prev.slice(0, -1));
    // Pass the reason directly to sendMessage to avoid the stale-closure problem
    // that arises when setting inputValue then immediately calling sendMessage.
    await sendMessage(reason);
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
        created_at: Math.floor(Date.now() / 1000),
        updated_at: Math.floor(Date.now() / 1000),
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
        created_at: Math.floor(Date.now() / 1000),
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

        {/* Mobile model chip — touch only, replaces the selects above.
            Uses a native <select> so iOS/Android show their system picker. */}
        {(() => {
          const byProvider: Record<string, typeof models> = {};
          for (const m of models) (byProvider[m.provider] ??= []).push(m);
          const chipValue = usePresetMode && selectedPresetId ? `p:${selectedPresetId}` : model;
          return (
            <select
              className={`${s["form-select"]} ${chatS["config-model-chip"]}`}
              value={chipValue}
              onChange={(e) => {
                const val = e.target.value;
                if (val.startsWith("p:")) {
                  const pid = val.slice(2);
                  const preset = tenantPresets.find((p) => p.id === pid);
                  if (preset) {
                    setSelectedPresetId(preset.id);
                    setGatewayId(preset.gateway_id);
                    setModel(preset.model);
                  }
                } else {
                  setModel(val);
                  setSelectedPresetId("");
                }
              }}
              data-cy="model-chip"
            >
              {tenantPresets.length > 0 && (
                <optgroup label="Presets">
                  {tenantPresets.map((p) => (
                    <option key={p.id} value={`p:${p.id}`}>{p.name}</option>
                  ))}
                </optgroup>
              )}
              {Object.entries(byProvider).map(([provider, pModels]) => (
                <optgroup key={provider} label={provider}>
                  {pModels.map((m) => (
                    <option key={m.model} value={m.model} disabled={!runnableProviders.has(m.provider)}>
                      {m.model}
                    </option>
                  ))}
                </optgroup>
              ))}
            </select>
          );
        })()}

        <div className={chatS["config-divider"]} />

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
            <span style={{ fontSize: "9px", position: "absolute", top: 2, right: 2, background: "var(--accent, #7c3aed)", color: "var(--btn-primary-text, #fff)", borderRadius: "50%", width: 12, height: 12, display: "flex", alignItems: "center", justifyContent: "center", lineHeight: 1 }}>
              {memories.length > 9 ? "9+" : memories.length}
            </span>
          )}
        </button>


        {supportsThinking && (
          <button
            className={`${chatS["icon-btn"]} ${chatS["icon-btn--mobile-hidden"]}`}
            title={drawerSettings.thinkingBudget !== null
              ? `Extended thinking ON (${(drawerSettings.thinkingBudget / 1000).toFixed(0)}k tokens) — click to disable`
              : "Enable extended thinking"}
            onClick={() => setDrawerSettings(s => ({
              ...s,
              thinkingBudget: s.thinkingBudget !== null ? null : 10000,
            }))}
            style={drawerSettings.thinkingBudget !== null ? { color: "var(--accent, #0052cc)", opacity: 1 } : {}}
            data-cy="thinking-toggle-toolbar"
          >
            💡
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
          <GhostModeIcon />
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
        <div className={chatS["top-banner"]} data-variant="error">
          {error}
          <button onClick={() => { setError(null); focusInput(); }} className={chatS["top-banner-close"]}>✕</button>
        </div>
      )}

      {warning && (
        <div className={chatS["top-banner"]} data-variant="warning">
          ⚠ {warning}
          <button onClick={() => { setWarning(null); focusInput(); }} className={chatS["top-banner-close"]}>✕</button>
        </div>
      )}

      {guardrailWarning && (
        <div className={chatS["top-banner"]} data-variant="warning" data-cy="guardrail-warning">
          ⚠ {guardrailWarning}
          <button onClick={() => { setGuardrailWarning(null); focusInput(); }} className={chatS["top-banner-close"]}>✕</button>
        </div>
      )}

      {ghostMode && (
        <div className={chatS["ghost-banner"]} data-cy="ghost-banner">
          <GhostModeIcon /> Ghost mode — this conversation is not saved and will not be logged
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
          {/* Feedback flag — bottom of sidebar, hidden in ghost mode */}
          {!ghostMode && (
            <button
              className={chatS["conv-archive-toggle"]}
              onClick={() => { setShowFeedback(true); setFeedbackSaved(false); setFeedbackError(null); }}
              disabled={!activeConvId}
              title="Session feedback"
              data-cy="feedback-flag-btn"
              style={{ display: "flex", alignItems: "center", gap: 6, opacity: activeConvId ? 1 : 0.4 }}
            >
              <FlagIcon />
              Session feedback
            </button>
          )}
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
                    <PaperclipIcon /> Files ({projectKnowledge.length})
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
                    <span className={chatS["files-panel-item-name"]}><PaperclipIcon /> {f.filename}</span>
                    <span className={chatS["files-panel-item-meta"]}>{f.token_count.toLocaleString()} tokens</span>
                  </button>
                ))}
              </div>
            </div>
          )}
          {isDragOver && (
            <div className={chatS["drop-overlay"]}>
              <div className={chatS["drop-zone"]}>
                <span className={chatS["drop-icon"]}><PaperclipIcon /></span>
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
              onOpenArtifact={handleOpenArtifact}
              onCopy={copyToClipboard}
              onEdit={editMessage}
              onRegenerate={regenerate}
              activeProject={activeProject}
              projectKnowledge={projectKnowledge}
            />
            {artifactTabs.length > 0 && activeArtifactKey && (
              <ArtifactPanel
                tabs={artifactTabs}
                activeKey={activeArtifactKey}
                onTabSelect={setActiveArtifactKey}
                onTabClose={(key) => {
                  setArtifactMap(prev => { const n = new Map(prev); n.delete(key); return n; });
                  setArtifactVersionIndex(prev => { const n = new Map(prev); n.delete(key); return n; });
                  setActiveArtifactKey(prev => {
                    if (prev !== key) return prev;
                    const remaining = artifactTabs.filter(t => t.key !== key);
                    return remaining[remaining.length - 1]?.key ?? null;
                  });
                }}
                onVersionNav={(key, idx) => setArtifactVersionIndex(prev => new Map(prev).set(key, idx))}
                isStreaming={isStreaming && activeConvId === streamingConvId}
                onClose={() => { setArtifactMap(new Map()); setActiveArtifactKey(null); setArtifactVersionIndex(new Map()); }}
                projectId={projectIdParam ?? undefined}
                onSave={projectIdParam ? handleFileSaved : undefined}
                onUpdateArtifact={handleUpdateArtifact}
                onSendRevision={(filename, code, instruction) => {
                  const activeTab = artifactTabs.find(t => t.key === activeArtifactKey);
                  const lang = activeTab?.versions[0]?.lang ?? "text";
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
          tenants={tenants}
          tenantId={tenantId}
          onTenantChange={setTenantId}
          gateways={gateways}
          gatewayId={gatewayId}
          onGatewayChange={setGatewayId}
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
              How would you rate this session?{" "}
              <em style={{ color: "var(--text-secondary)", fontStyle: "normal", fontSize: "0.9em" }}>(1 = best, 5 = worst)</em>
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
          projectId={projectIdParam}
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
