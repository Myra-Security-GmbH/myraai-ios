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
} from "src/api/types";
import ModelPicker from "src/common/components/ModelPicker/ModelPicker";
import s from "src/common/components/layout/Layout.module.scss";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
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

const GATEWAY_URL = import.meta.env.VITE_GATEWAY_URL ?? "";

export default function Chat() {
  useDocumentTitle("Chat");

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

  useEffect(() => { localStorage.setItem("aig-chat-tenant",  tenantId);  }, [tenantId]);
  useEffect(() => { localStorage.setItem("aig-chat-gateway", gatewayId); }, [gatewayId]);
  useEffect(() => { localStorage.setItem("aig-chat-model",   model);     }, [model]);

  // ── Active conversation ────────────────────────────────────────────────────
  const [activeConvId, setActiveConvId] = useState<string | null>(null);
  const [messages, setMessages] = useState<ChatMessage[]>([]);

  // ── Settings drawer ────────────────────────────────────────────────────────
  const [showSettings, setShowSettings] = useState(false);
  const [drawerSettings, setDrawerSettings] = useState<DrawerSettings>({
    systemPrompt: "",
    temperature: 0.7,
    maxTokens: 2048,
  });

  // ── Chat input ─────────────────────────────────────────────────────────────
  const [inputValue, setInputValue] = useState("");
  const [pendingAttachments, setPendingAttachments] = useState<PendingAttachment[]>([]);

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
  const refreshToken = useCallback(async (gId: string) => {
    try {
      const tok = await api.post<PlaygroundToken>("/playground/token", { gateway_id: gId });
      setPlayToken(tok);
      tokenExpiresAt.current = new Date(tok.expires_at);
    } catch (e) {
      setError("Could not create gateway token: " + String(e));
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
  async function generateTitle(convId: string, firstUserText: string) {
    const tok = playToken;
    if (!tok || !model) return;
    try {
      const compatUrl = `${GATEWAY_URL}/v1/${tok.tenant_slug}/${tok.gateway_slug}/compat/chat/completions`;
      const res = await fetch(compatUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${tok.token}`,
        },
        body: JSON.stringify({
          model,
          messages: [
            {
              role: "system",
              content:
                "Generate a short title (4-5 words, no quotes, no trailing punctuation) for a conversation that starts with the following message. Reply with only the title.",
            },
            { role: "user", content: firstUserText.slice(0, 500) },
          ],
          max_tokens: 20,
          temperature: 0,
          stream: false,
        }),
      });
      if (!res.ok) return;
      const json = await res.json();
      const title: string | undefined = json?.choices?.[0]?.message?.content?.trim();
      if (!title) return;
      await renameConversation(convId, title);
    } catch { /* best-effort — ignore errors */ }
  }

  // ── Delete conversation ────────────────────────────────────────────────────
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

    // Refresh token if expiring soon
    const tokenAge = tokenExpiresAt.current
      ? tokenExpiresAt.current.getTime() - Date.now()
      : null;
    if (tokenAge !== null && tokenAge < 60_000) {
      await refreshToken(gatewayId);
    }

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
    let hasSkill: string | null = null;
    if (pendingAttachments.length > 0) {
      const blocks: object[] = [{ type: "text", text }];
      const unsupported: string[] = [];
      for (const att of pendingAttachments) {
        if (att.mime_type.startsWith("image/")) {
          blocks.push({
            type: "image_url",
            image_url: { url: `data:${att.mime_type};base64,${att.data}` },
          });
        } else if (att.mime_type === "application/pdf" || att.mime_type === "text/plain") {
          blocks.push({
            type: "document",
            source: { type: "base64", media_type: att.mime_type, data: att.data },
          });
        } else if (att.mime_type === "application/vnd.openxmlformats-officedocument.wordprocessingml.document") {
          let fileId: string;
          try {
            const res = await api.post<{ file_id: string }>("/chat/files", {
              gateway_id: gatewayId,
              filename: att.filename,
              mime_type: att.mime_type,
              data: att.data,
            });
            fileId = res.file_id;
          } catch (e) {
            setError("Failed to upload document to Anthropic: " + String(e));
            return;
          }
          blocks.push({ type: "document", source: { type: "file", file_id: fileId } });
          hasSkill = "docx";
        } else {
          unsupported.push(att.filename);
        }
      }
      if (unsupported.length > 0) {
        setError(
          `Unsupported file type(s): ${unsupported.join(", ")}. ` +
          `Supported: images (JPEG, PNG, GIF, WebP), PDF, plain text, Word (.docx).`
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
          if (Array.isArray(parsed)) content = parsed;
        } catch { /* plain text — keep as string */ }
        return { role: m.role, content };
      }),
    ];

    // Determine if skill headers are needed (new docx in this message, or file_id in history)
    const needsSkill = hasSkill ?? (history.some((m) => {
      try {
        const p = JSON.parse(m.content);
        return Array.isArray(p) && p.some((b: any) => b?.source?.type === "file");
      } catch { return false; }
    }) ? "docx" : null);

    // Stream inference
    const tok = playToken;
    const compatUrl = `${GATEWAY_URL}/v1/${tok.tenant_slug}/${tok.gateway_slug}/compat/chat/completions`;
    const abort = new AbortController();
    abortRef.current = abort;

    setIsStreaming(true);
    setStreamingContent("");

    const start = performance.now();
    let accumulated = "";
    let inputTokens: number | null = null;
    let outputTokens: number | null = null;
    let costUsd: number | null = null;

    try {
      const res = await fetch(compatUrl, {
        method: "POST",
        signal: abort.signal,
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${tok.token}`,
          ...(needsSkill ? { "x-aig-skill": needsSkill } : {}),
        },
        body: JSON.stringify({
          model,
          messages: apiMessages,
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
              accumulated += delta;
              setStreamingContent(accumulated);
            }
            const usage = chunk?.usage;
            if (usage) {
              inputTokens = usage.prompt_tokens ?? null;
              outputTokens = usage.completion_tokens ?? null;
              costUsd = usage.cost_usd ?? null;
            }
          } catch { /* skip malformed */ }
        }
      }
    } catch (err: unknown) {
      if ((err as Error)?.name === "AbortError") {
        // User stopped — save partial content
      } else {
        setError(String(err));
        setIsStreaming(false);
        setStreamingContent(null);
        return;
      }
    }

    const latencyMs = Math.round(performance.now() - start);
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
        generateTitle(convId, text);
      }
    } catch (e) {
      setError("Failed to save assistant message: " + String(e));
    }
  }

  function stopStreaming() {
    abortRef.current?.abort();
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

        <div className={chatS["config-spacer"]} />

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
        <div className={chatS["message-area"]}>
          <MessageThread
            messages={messages}
            streamingContent={streamingContent}
            isStreaming={isStreaming}
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
