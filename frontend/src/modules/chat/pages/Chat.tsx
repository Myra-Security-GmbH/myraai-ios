import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "src/api/client";
import type {
  ChatConversation,
  ChatMessage,
  ChatPreset,
  Gateway,
  ModelPrice,
  PlaygroundToken,
  ProviderMeta,
  Tenant,
  TenantPreset,
} from "src/api/types";
import ModelPicker from "src/common/components/ModelPicker/ModelPicker";
import s from "src/common/components/layout/Layout.module.scss";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { useAuth } from "src/common/contexts/AuthContext";
import ChatInput, { type PendingAttachment } from "../components/ChatInput";
import ConversationList from "../components/ConversationList";
import MessageThread from "../components/MessageThread";
import SettingsDrawer, { type DrawerSettings } from "../components/SettingsDrawer";
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

const GATEWAY_URL = import.meta.env.VITE_GATEWAY_URL ?? "";

/** Models that support native vision (image_url blocks) via vLLM.
 *  Text-only models not listed here have images routed through MinerU instead.
 *  Extend this set as vision-capable models are deployed. */
const VLLM_VISION_MODELS = new Set<string>([
  // e.g. "qwen2.5-vl-7b-instruct",
]);

function isVisionCapable(model: string): boolean {
  const bare = model.startsWith("vllm/") ? model.slice(5) : model;
  return VLLM_VISION_MODELS.has(bare) || /[-_]vl[-_\d]/i.test(bare);
}

export default function Chat() {
  useDocumentTitle("Chat");

  const { user: me } = useAuth();

  // ── Data ───────────────────────────────────────────────────────────────────
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [gateways, setGateways] = useState<Gateway[]>([]);
  const [models, setModels] = useState<ModelPrice[]>([]);
  const [providerMeta, setProviderMeta] = useState<ProviderMeta[]>([]);
  const [conversations, setConversations] = useState<ChatConversation[]>([]);
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

  // ── Active conversation ────────────────────────────────────────────────────
  const [activeConvId, setActiveConvId] = useState<string | null>(null);
  const [messages, setMessages] = useState<ChatMessage[]>([]);

  // ── Settings drawer ────────────────────────────────────────────────────────
  const [showSettings, setShowSettings] = useState(false);
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
    "- When something is ambiguous, make a reasonable assumption and proceed rather than asking multiple clarifying questions. Ask at most one follow-up question at the end if genuinely needed.\n" +
    "- Don't moralize or add unsolicited ethical commentary unless the topic directly calls for it.\n\n" +
    "Decision tables:\n" +
    "- When evaluating, comparing, or rating options across multiple dimensions or criteria (Bewertung), always present the results as a markdown table.\n" +
    "- Use ✅ (meets / strong), 🟡 (partial / acceptable), ❌ (does not meet / weak) as the rating symbols — never substitute with text or other symbols.\n" +
    "- Include a summary row or concluding sentence after the table.\n" +
    "- For priority, urgency, or risk level (Ampel / traffic light), use 🟢 (low / on track), 🟡 (medium / at risk), 🔴 (high / critical / blocked) — both inline and in tables.";

  const [drawerSettings, setDrawerSettings] = useState<DrawerSettings>({
    systemPrompt: DEFAULT_SYSTEM_PROMPT,
    temperature: 0.7,
    maxTokens: 8192,
    webSearch: false,
  });

  // ── Chat input ─────────────────────────────────────────────────────────────
  const [inputValue, setInputValue] = useState("");
  const [pendingAttachments, setPendingAttachments] = useState<PendingAttachment[]>([]);
  const [processingStatus, setProcessingStatus] = useState<string | null>(null);

  // ── Drag-and-drop ──────────────────────────────────────────────────────────
  const [isDragOver, setIsDragOver] = useState(false);
  const dragCounterRef = useRef(0);

  // ── Streaming state ────────────────────────────────────────────────────────
  const [isStreaming, setIsStreaming] = useState(false);
  const [streamingContent, setStreamingContent] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  // ── Play token ─────────────────────────────────────────────────────────────
  const [playToken, setPlayToken] = useState<PlaygroundToken | null>(null);
  const tokenExpiresAt = useRef<Date | null>(null);

  // ── UI ─────────────────────────────────────────────────────────────────────
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // ── Initial data load ──────────────────────────────────────────────────────
  useEffect(() => {
    api.get<Tenant[]>("/tenants").then(setTenants).catch(() => {});
    api.get<ModelPrice[]>("/models").then(setModels).catch(() => {});
    api.get<ProviderMeta[]>("/providers").then(setProviderMeta).catch(() => {});
    api.get<ChatConversation[]>("/conversations").then(setConversations).catch(() => {});
    api.get<ChatPreset[]>("/chat-presets").then(setPresets).catch(() => {});
  }, []);

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

  // Validate stored tenant — fall back to first if missing or no longer accessible
  useEffect(() => {
    if (tenants.length === 0) return;
    if (tenantId && tenants.find((t) => t.id === tenantId)) return;
    setTenantId(tenants[0].id);
  }, [tenants, tenantId]);

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
    try {
      const conv = await api.get<ChatConversation>(`/conversations/${id}`);
      setMessages(conv.messages ?? []);
      setActiveConvId(id);
      // Sync settings from conversation
      if (conv.model) setModel(conv.model);
      setDrawerSettings({
        systemPrompt: conv.system_prompt ?? "",
        temperature: conv.temperature ?? 0.7,
        maxTokens: conv.max_tokens ?? 2048,
        webSearch: false,
      });
      if (conv.gateway_id && conv.gateway_id !== gatewayId) {
        // Find tenant for this gateway
        setGatewayId(conv.gateway_id);
      }
    } catch (e) {
      setError(String(e));
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
      });
      setConversations((prev) => [conv, ...prev]);
      await loadConversation(conv.id);
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
      const res = await fetch(compatUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${tok.token}`,
        },
        body: JSON.stringify({
          model: currentModel,
          messages: [
            {
              role: "system",
              content:
                "Write a short title (3-6 words) for this conversation. Use natural, conversational phrasing — like a topic someone would jot down in a notebook, not a document heading. No quotes. No punctuation at the end. Reply with only the title.",
            },
            { role: "user",      content: firstUserText.slice(0, 500) },
            { role: "assistant", content: firstAssistantText.slice(0, 500) },
          ],
          max_tokens: 30,
          temperature: 0,
          stream: false,
        }),
      });
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

    for (const msg of messages) {
      const label = msg.role === "user" ? "**You**" : "**Claude**";
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

  async function deleteConversation(id: string) {
    if (!window.confirm("Delete this conversation?")) return;
    await api.delete(`/conversations/${id}`).catch(() => {});
    setConversations((prev) => prev.filter((c) => c.id !== id));
    if (activeConvId === id) {
      setActiveConvId(null);
      setMessages([]);
    }
  }

  // ── Send message ───────────────────────────────────────────────────────────
  async function sendMessage() {
    const text = inputValue.trim();
    if (!text && pendingAttachments.length === 0) return;
    if (!gatewayId) { setError("Select a gateway first"); return; }
    if (!model) { setError("Select a model first"); return; }
    if (!playToken) { setError("No gateway token — select a gateway"); return; }

    // Refresh token if expiring soon; use the returned token directly to avoid stale state
    const tokenAge = tokenExpiresAt.current
      ? tokenExpiresAt.current.getTime() - Date.now()
      : null;
    let currentTok: PlaygroundToken | null = playToken;
    if (tokenAge !== null && tokenAge < 60_000) {
      currentTok = await refreshToken(gatewayId);
    }
    if (!currentTok) { setError("No gateway token — could not refresh"); return; }

    // Track whether this is the very first message (for auto-title)
    const isFirstMessage = messages.length === 0;

    // Create conversation on first message if none active
    let convId = activeConvId;
    if (!convId) {
      setCreating(true);
      try {
        const conv = await api.post<ChatConversation>("/conversations", {
          gateway_id: gatewayId,
          model,
          system_prompt: drawerSettings.systemPrompt || null,
          temperature: drawerSettings.temperature,
          max_tokens: drawerSettings.maxTokens,
          title: text.slice(0, 60) || "New conversation",
        });
        convId = conv.id;
        setConversations((prev) => [conv, ...prev]);
        setActiveConvId(convId);
      } catch (e) {
        setError("Failed to create conversation: " + String(e));
        setCreating(false);
        return;
      } finally {
        setCreating(false);
      }
    }

    // Build content — plain text or content blocks if attachments
    let userContent: string;
    let hasSkill: string | null = null; // reserved for future skill-based providers
    if (pendingAttachments.length > 0) {
      const blocks: object[] = [{ type: "text", text }];
      const unsupported: string[] = [];
      for (const att of pendingAttachments) {
        if (att.mime_type.startsWith("image/")) {
          if (model.startsWith("claude-") || isVisionCapable(model)) {
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
                gateway_id: gatewayId,
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
        } else if (att.mime_type === "application/pdf" || att.mime_type === "text/plain") {
          if (att.mime_type === "application/pdf" && !model.startsWith("claude-")) {
            // Non-Anthropic model: extract PDF text via MinerU
            let extractedText: string;
            try {
              setProcessingStatus(`Extracting text from "${att.filename}" with MinerU…`);
              const res = await api.post<{ text: string }>("/chat/files", {
                gateway_id: gatewayId,
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
              gateway_id: gatewayId,
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
          att.mime_type === "application/vnd.oasis.opendocument.spreadsheet"
        ) {
          let fileId: string;
          try {
            setProcessingStatus(`Uploading "${att.filename}"…`);
            const res = await api.post<{ file_id: string }>("/chat/files", {
              gateway_id: gatewayId,
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
          unsupported.push(att.filename);
        }
      }
      if (unsupported.length > 0) {
        setError(
          `Unsupported file type(s): ${unsupported.join(", ")}. ` +
          `Supported: images (JPEG, PNG, GIF, WebP), PDF, plain text, Word (.docx), CSV, TSV, Excel (.xlsx, .xlsm), OpenDocument (.ods).`
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

    // Persist user message
    let userMsgId: string | null = null;
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

    // Upload any attachments
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

    // Build message history for inference
    const history = messages
      .filter((m) => m.id !== "__temp_user__")
      .concat({ ...tempUserMsg, id: userMsgId ?? "__temp_user__" });

    const apiMessages = [
      ...(drawerSettings.systemPrompt
        ? [{ role: "system", content: drawerSettings.systemPrompt }]
        : []),
      ...history.map((m) => {
        let content: unknown = m.content;
        try {
          const parsed = JSON.parse(m.content);
          if (Array.isArray(parsed)) {
            // Convert docx/pdf blocks back to plain text for the LLM
            content = parsed.map((b: { type: string; filename?: string; text?: string; [k: string]: unknown }) => {
              if (b.type === "docx" || b.type === "pdf") {
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

    const start = performance.now();
    let accumulated = "";
    let inputTokens: number | null = null;
    let outputTokens: number | null = null;
    let costUsd: number | null = null;

    const reqHeaders = Object.fromEntries(
      Object.entries({
        "Content-Type": "application/json",
        Authorization: `Bearer ${tok.token}`,
        ...(needsSkill ? { "x-aig-skill": needsSkill } : {}),
        ...(drawerSettings.webSearch ? { "x-aig-web-search": "1" } : {}),
      }).filter(([, v]) => v !== undefined)
    ) as Record<string, string>;

    let continueCount = 0;
    const MAX_CONTINUATIONS = 10;

    streaming: while (true) {
      const reqMessages = continueCount === 0
        ? apiMessages
        : [...apiMessages, { role: "assistant", content: accumulated }, { role: "user", content: "Continue" }];

      let finishReason: string | null = null;

      try {
        const res = await fetch(compatUrl, {
          method: "POST",
          signal: abort.signal,
          headers: reqHeaders,
          body: JSON.stringify({
            model,
            messages: reqMessages,
            temperature: drawerSettings.temperature,
            max_tokens: drawerSettings.maxTokens,
            stream: true,
          }),
        });

        if (!res.ok) {
          const body = await res.text().catch(() => "");
          let msg = `HTTP ${res.status}`;
          try { msg = JSON.parse(body)?.error?.message ?? JSON.parse(body)?.error ?? msg; } catch { /* */ }
          throw new Error(msg);
        }

        const reader = res.body!.getReader();
        const decoder = new TextDecoder();
        let buf = "";

        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          buf += decoder.decode(value, { stream: true });
          const lines = buf.split("\n");
          buf = lines.pop() ?? "";
          for (const line of lines) {
            if (!line.startsWith("data: ")) continue;
            const data = line.slice(6).trim();
            if (data === "[DONE]") continue;
            try {
              const chunk = JSON.parse(data);
              const delta = chunk?.choices?.[0]?.delta?.content;
              if (delta != null) {
                if (!accumulated) setProcessingStatus(null); // first token — hide status
                accumulated += delta;
                setStreamingContent(accumulated);
              }
              const reason = chunk?.choices?.[0]?.finish_reason;
              if (reason) finishReason = reason;
              const usage = chunk?.usage;
              if (usage) {
                inputTokens  = (inputTokens  ?? 0) + (usage.prompt_tokens     ?? 0);
                outputTokens = (outputTokens ?? 0) + (usage.completion_tokens ?? 0);
                costUsd      = (costUsd      ?? 0) + (usage.cost_usd          ?? 0);
              }
            } catch { /* skip malformed */ }
          }
        }
      } catch (err: unknown) {
        if ((err as Error)?.name === "AbortError") {
          break streaming; // User stopped — save partial content
        } else {
          setProcessingStatus(null);
          setError(String(err));
          setIsStreaming(false);
          setStreamingContent(null);
          return;
        }
      }

      // Auto-continue if the model hit the token limit and user hasn't aborted
      if (finishReason === "max_tokens" && !abort.signal.aborted && continueCount < MAX_CONTINUATIONS) {
        continueCount++;
        continue streaming;
      }
      break streaming;
    }

    const latencyMs = Math.round(performance.now() - start);
    setProcessingStatus(null);
    setIsStreaming(false);
    setStreamingContent(null);

    if (!accumulated) return;

    // Persist assistant message
    try {
      const res = await api.post<{ id: string }>(`/conversations/${convId}/messages`, {
        role: "assistant",
        content: accumulated,
        input_tokens: inputTokens,
        output_tokens: outputTokens,
        cost_usd: costUsd,
        latency_ms: latencyMs,
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
        created_at: new Date().toISOString(),
        attachments: [],
      };
      setMessages((prev) => [...prev, assistantMsg]);
      // Update conversation updated_at in list
      setConversations((prev) =>
        prev.map((c) =>
          c.id === convId ? { ...c, updated_at: new Date().toISOString() } : c
        )
      );

      // Auto-generate title after the first exchange (fire-and-forget)
      if (isFirstMessage && convId) {
        generateTitle(convId, text, accumulated, tok, model);
      }
    } catch (e) {
      setError("Failed to save assistant message: " + String(e));
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
    });
  }

  async function deletePreset(id: string) {
    await api.delete(`/chat-presets/${id}`).catch(() => {});
    setPresets((prev) => prev.filter((p) => p.id !== id));
  }

  function copyToClipboard(text: string) {
    navigator.clipboard.writeText(text).catch(() => {});
  }

  // ── Render ─────────────────────────────────────────────────────────────────
  return (
    <div className={chatS["chat-page"]}>
      {/* Config bar */}
      <div className={chatS["config-bar"]}>
        <span className={chatS["config-label"]}>Tenant</span>
        <div className={chatS["config-select"]}>
          <select
            className={s["form-select"]}
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

        {usePresetMode ? (
          <>
            <span className={chatS["config-label"]}>Mode</span>
            <div style={{ display: "flex", gap: "6px", flexWrap: "wrap", alignItems: "center" }}>
              {tenantPresets.map((p) => (
                <button
                  key={p.id}
                  type="button"
                  onClick={() => {
                    setSelectedPresetId(p.id);
                    setGatewayId(p.gateway_id);
                    setModel(p.model);
                  }}
                  style={{
                    padding: "4px 10px",
                    borderRadius: "6px",
                    border: selectedPresetId === p.id
                      ? "2px solid var(--accent, #0052cc)"
                      : "1px solid var(--border, #ccc)",
                    background: selectedPresetId === p.id
                      ? "var(--accent-light, #e8f0fe)"
                      : "transparent",
                    fontWeight: selectedPresetId === p.id ? 600 : 400,
                    fontSize: "13px",
                    cursor: "pointer",
                    whiteSpace: "nowrap",
                  }}
                >
                  {p.name}
                </button>
              ))}
            </div>
          </>
        ) : (
          <>
            <span className={chatS["config-label"]}>Gateway</span>
            <div className={chatS["config-select"]}>
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

            <span className={chatS["config-label"]}>Model</span>
            <div className={chatS["config-model"]}>
              <ModelPicker
                models={models}
                value={model}
                onChange={setModel}
                runnableProviders={runnableProviders}
              />
            </div>
          </>
        )}

        <div className={chatS["config-spacer"]} />

        <button
          className={chatS["icon-btn"]}
          title={drawerSettings.webSearch ? "Web search: ON (click to disable)" : "Enable web search"}
          onClick={() => setDrawerSettings(s => ({ ...s, webSearch: !s.webSearch }))}
          style={drawerSettings.webSearch ? { color: "var(--accent, #0052cc)" } : {}}
        >
          <GlobeIcon />
        </button>

        <button
          className={chatS["icon-btn"]}
          title="Download PDF"
          onClick={exportPdf}
          disabled={!activeConvId || messages.length === 0}
        >
          <PdfIcon />
        </button>

        <button
          className={chatS["icon-btn"]}
          title="Download Markdown"
          onClick={exportMarkdown}
          disabled={!activeConvId || messages.length === 0}
        >
          <DownloadIcon />
        </button>

        <button
          className={chatS["icon-btn"]}
          title="Settings"
          onClick={() => setShowSettings(true)}
        >
          <GearIcon />
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
            onClick={() => setError(null)}
            style={{ marginLeft: 8, background: "none", border: "none", cursor: "pointer", color: "#c62828" }}
          >
            ✕
          </button>
        </div>
      )}

      <div className={chatS["chat-body"]}>
        {/* Conversation sidebar */}
        <div className={chatS["conv-sidebar"]}>
          <ConversationList
            conversations={conversations}
            activeId={activeConvId}
            onSelect={loadConversation}
            onCreate={createConversation}
            onRename={renameConversation}
            onDelete={deleteConversation}
            creating={creating}
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
          {isDragOver && (
            <div className={chatS["drop-overlay"]}>
              <div className={chatS["drop-zone"]}>
                <span className={chatS["drop-icon"]}>📎</span>
                <span className={chatS["drop-label"]}>Drop file here</span>
                <span className={chatS["drop-hint"]}>
                  Images · PDF · DOCX · XLSX · ODS · CSV · TXT
                </span>
              </div>
            </div>
          )}
          <MessageThread
            messages={messages}
            streamingContent={streamingContent}
            isStreaming={isStreaming}
            processingStatus={processingStatus}
            onCopy={copyToClipboard}
            onEdit={editMessage}
            onRegenerate={regenerate}
          />

          <ChatInput
            value={inputValue}
            onChange={setInputValue}
            onSend={sendMessage}
            onStop={stopStreaming}
            isStreaming={isStreaming}
            disabled={!gatewayId || !model || creating}
            pendingAttachments={pendingAttachments}
            onAttach={(att) => setPendingAttachments((prev) => [...prev, att])}
            onRemoveAttachment={(idx) =>
              setPendingAttachments((prev) => prev.filter((_, i) => i !== idx))
            }
          />
        </div>
      </div>

      {/* Settings drawer */}
      {showSettings && (
        <SettingsDrawer
          settings={drawerSettings}
          onChange={setDrawerSettings}
          onSave={saveSettings}
          onClose={() => setShowSettings(false)}
          presets={presets}
          onApplyPreset={applyPreset}
          onSavePreset={savePreset}
          onDeletePreset={deletePreset}
        />
      )}
    </div>
  );
}
