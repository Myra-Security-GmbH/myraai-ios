import { useEffect, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { api } from "src/api/client";
import type { Gateway, ModelPrice, PlaygroundToken, Tenant } from "src/api/types";
import s from "src/common/components/layout/Layout.module.scss";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface PanelState {
  id: string;
  model: string;
  content: string | null;
  loading: boolean;
  error: string | null;
  latencyMs: number | null;
  inputTokens: number | null;
  outputTokens: number | null;
  costUsd: number | null;
}

function makePanel(model = ""): PanelState {
  return {
    id: Math.random().toString(36).slice(2),
    model,
    content: null,
    loading: false,
    error: null,
    latencyMs: null,
    inputTokens: null,
    outputTokens: null,
    costUsd: null,
  };
}

// ---------------------------------------------------------------------------
// ModelPicker — searchable select grouped by provider
// ---------------------------------------------------------------------------

interface ModelPickerProps {
  models: ModelPrice[];
  value: string;
  onChange: (model: string) => void;
  id?: string;
}

function ModelPicker({ models, value, onChange, id }: ModelPickerProps) {
  const [search, setSearch] = useState("");
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  const lower = search.toLowerCase();
  const filtered = search
    ? models.filter(
        (m) =>
          m.model.toLowerCase().includes(lower) ||
          m.provider.toLowerCase().includes(lower)
      )
    : models;

  // Group by provider
  const byProvider: Record<string, ModelPrice[]> = {};
  for (const m of filtered) {
    (byProvider[m.provider] ??= []).push(m);
  }
  const providers = Object.keys(byProvider).sort();

  // Close on outside click
  useEffect(() => {
    if (!open) return;
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [open]);

  const displayLabel = value || "Select model…";

  return (
    <div ref={ref} style={{ position: "relative" }} id={id}>
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className={s["form-input"]}
        style={{
          width: "100%",
          textAlign: "left",
          cursor: "pointer",
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          padding: "6px 10px",
        }}
        aria-haspopup="listbox"
        aria-expanded={open}
      >
        <span
          style={{
            overflow: "hidden",
            textOverflow: "ellipsis",
            whiteSpace: "nowrap",
          }}
        >
          {displayLabel}
        </span>
        <span style={{ marginLeft: 8, flexShrink: 0 }}>▾</span>
      </button>

      {open && (
        <div
          role="listbox"
          style={{
            position: "absolute",
            top: "calc(100% + 4px)",
            left: 0,
            right: 0,
            zIndex: 100,
            background: "var(--card-bg)",
            border: "1px solid var(--card-border)",
            borderRadius: 6,
            boxShadow: "0 4px 16px rgba(0,0,0,0.15)",
            maxHeight: 360,
            display: "flex",
            flexDirection: "column",
          }}
        >
          <div style={{ padding: "8px 8px 4px" }}>
            <input
              autoFocus
              type="text"
              placeholder="Search models…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className={s["form-input"]}
              style={{ margin: 0 }}
              aria-label="Search models"
            />
          </div>
          <div style={{ overflowY: "auto", flex: 1 }}>
            {providers.length === 0 && (
              <div className={s.empty} style={{ padding: "16px 12px" }}>
                No models match
              </div>
            )}
            {providers.map((prov) => (
              <div key={prov}>
                <div
                  style={{
                    padding: "6px 12px 2px",
                    fontSize: 11,
                    fontWeight: 600,
                    textTransform: "uppercase",
                    letterSpacing: "0.06em",
                    color: "var(--text-secondary)",
                    position: "sticky",
                    top: 0,
                    background: "var(--card-bg)",
                  }}
                >
                  {prov}
                </div>
                {byProvider[prov].map((m) => (
                  <div
                    key={m.model}
                    role="option"
                    aria-selected={m.model === value}
                    onClick={() => {
                      onChange(m.model);
                      setOpen(false);
                      setSearch("");
                    }}
                    style={{
                      padding: "6px 12px",
                      cursor: "pointer",
                      fontSize: 13,
                      fontFamily: "var(--font-mono, monospace)",
                      background:
                        m.model === value
                          ? "var(--table-row-hover)"
                          : undefined,
                    }}
                    onMouseOver={(e) =>
                      ((e.currentTarget as HTMLElement).style.background =
                        "var(--table-row-hover)")
                    }
                    onMouseOut={(e) =>
                      ((e.currentTarget as HTMLElement).style.background =
                        m.model === value
                          ? "var(--table-row-hover)"
                          : "")
                    }
                  >
                    {m.model}
                  </div>
                ))}
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// MarkdownRenderer — renders model output as formatted markdown
// ---------------------------------------------------------------------------

function MarkdownRenderer({ content }: { content: string }) {
  return (
    <ReactMarkdown
      remarkPlugins={[remarkGfm]}
      components={{
        h1: ({ children }) => (
          <h1 style={{ fontSize: "1.4em", fontWeight: 700, margin: "0.6em 0 0.3em", lineHeight: 1.3 }}>{children}</h1>
        ),
        h2: ({ children }) => (
          <h2 style={{ fontSize: "1.2em", fontWeight: 700, margin: "0.6em 0 0.3em", lineHeight: 1.3 }}>{children}</h2>
        ),
        h3: ({ children }) => (
          <h3 style={{ fontSize: "1.05em", fontWeight: 700, margin: "0.5em 0 0.25em", lineHeight: 1.3 }}>{children}</h3>
        ),
        p: ({ children }) => (
          <p style={{ margin: "0 0 0.6em", lineHeight: 1.6 }}>{children}</p>
        ),
        ul: ({ children }) => (
          <ul style={{ margin: "0 0 0.6em", paddingLeft: "1.4em" }}>{children}</ul>
        ),
        ol: ({ children }) => (
          <ol style={{ margin: "0 0 0.6em", paddingLeft: "1.4em" }}>{children}</ol>
        ),
        li: ({ children }) => (
          <li style={{ margin: "0.15em 0", lineHeight: 1.5 }}>{children}</li>
        ),
        code: ({ children, className }) => {
          const isBlock = !!className;
          return isBlock ? (
            <code
              style={{
                display: "block",
                background: "var(--section-bg)",
                border: "1px solid var(--card-border)",
                borderRadius: 4,
                padding: "8px 10px",
                fontFamily: "var(--font-mono, monospace)",
                fontSize: "0.88em",
                overflowX: "auto",
                whiteSpace: "pre",
              }}
            >
              {children}
            </code>
          ) : (
            <code
              style={{
                background: "var(--section-bg)",
                border: "1px solid var(--card-border)",
                borderRadius: 3,
                padding: "1px 5px",
                fontFamily: "var(--font-mono, monospace)",
                fontSize: "0.88em",
              }}
            >
              {children}
            </code>
          );
        },
        pre: ({ children }) => (
          <pre style={{ margin: "0 0 0.6em", background: "none", padding: 0 }}>{children}</pre>
        ),
        blockquote: ({ children }) => (
          <blockquote
            style={{
              borderLeft: "3px solid var(--card-border)",
              margin: "0 0 0.6em",
              paddingLeft: "0.8em",
              color: "var(--text-secondary)",
              fontStyle: "italic",
            }}
          >
            {children}
          </blockquote>
        ),
        hr: () => (
          <hr style={{ border: "none", borderTop: "1px solid var(--card-border)", margin: "0.8em 0" }} />
        ),
        table: ({ children }) => (
          <div style={{ overflowX: "auto", marginBottom: "0.6em" }}>
            <table style={{ borderCollapse: "collapse", width: "100%", fontSize: "0.92em" }}>{children}</table>
          </div>
        ),
        th: ({ children }) => (
          <th style={{ border: "1px solid var(--card-border)", padding: "4px 8px", background: "var(--section-bg)", fontWeight: 700, textAlign: "left" }}>{children}</th>
        ),
        td: ({ children }) => (
          <td style={{ border: "1px solid var(--card-border)", padding: "4px 8px" }}>{children}</td>
        ),
        a: ({ href, children }) => (
          <a href={href} target="_blank" rel="noopener noreferrer" style={{ color: "var(--accent)", textDecoration: "underline" }}>{children}</a>
        ),
        strong: ({ children }) => <strong style={{ fontWeight: 700 }}>{children}</strong>,
        em: ({ children }) => <em style={{ fontStyle: "italic" }}>{children}</em>,
      }}
    >
      {content}
    </ReactMarkdown>
  );
}

// ---------------------------------------------------------------------------
// PanelResult — response card for one model
// ---------------------------------------------------------------------------

interface PanelResultProps {
  panel: PanelState;
  models: ModelPrice[];
  onModelChange: (model: string) => void;
  onRemove: () => void;
  canRemove: boolean;
}

function PanelResult({
  panel,
  models,
  onModelChange,
  onRemove,
  canRemove,
}: PanelResultProps) {
  const hasResult = panel.content !== null || panel.error !== null;
  const [rawMode, setRawMode] = useState(false);

  return (
    <div
      className={s.card}
      style={{ marginBottom: 0, display: "flex", flexDirection: "column", minWidth: 0 }}
    >
      {/* Header: model picker + raw/rendered toggle + remove */}
      <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 12 }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <ModelPicker
            models={models}
            value={panel.model}
            onChange={onModelChange}
          />
        </div>
        {hasResult && !panel.error && (
          <button
            type="button"
            className={`${s.btn} ${s["btn--secondary"]}`}
            style={{ padding: "3px 8px", flexShrink: 0, fontSize: 11 }}
            onClick={() => setRawMode((v) => !v)}
            aria-label={rawMode ? "Show rendered" : "Show raw"}
          >
            {rawMode ? "Rendered" : "Raw"}
          </button>
        )}
        {canRemove && (
          <button
            type="button"
            className={`${s.btn} ${s["btn--secondary"]}`}
            style={{ padding: "4px 8px", flexShrink: 0 }}
            onClick={onRemove}
            aria-label="Remove panel"
          >
            ✕
          </button>
        )}
      </div>

      {/* Response area */}
      <div
        style={{
          flex: 1,
          minHeight: 200,
          background: "var(--section-bg)",
          borderRadius: 4,
          padding: "10px 12px",
          fontSize: 13,
          lineHeight: 1.6,
          overflowY: "auto",
          wordBreak: "break-word",
          color: panel.error ? "var(--badge-error-text)" : "var(--text-primary)",
          ...(rawMode ? { fontFamily: "var(--font-mono, monospace)", whiteSpace: "pre-wrap" } : {}),
        }}
        aria-label="Response"
        aria-live="polite"
      >
        {/* Spinner only while waiting for the first token */}
        {panel.loading && panel.content === null && !panel.error && (
          <span style={{ color: "var(--text-secondary)" }}>Running…</span>
        )}
        {/* Error (always without loading guard — errors arrive instantly) */}
        {panel.error && panel.error}
        {/* Content — shown progressively as chunks arrive, even while still loading */}
        {panel.content !== null && !panel.error && (
          rawMode
            ? (panel.content || <span style={{ color: "var(--text-secondary)" }}>(empty response)</span>)
            : (panel.content
                ? <>
                    <MarkdownRenderer content={panel.content} />
                    {panel.loading && (
                      <span
                        style={{ display: "inline-block", width: "0.55em", height: "1em",
                                 background: "var(--text-primary)", verticalAlign: "text-bottom",
                                 animation: "aig-blink 1s step-start infinite" }}
                        aria-hidden="true"
                      />
                    )}
                  </>
                : <span style={{ color: "var(--text-secondary)" }}>(empty response)</span>)
        )}
        {!panel.loading && !hasResult && (
          <span style={{ color: "var(--text-secondary)" }}>
            Response will appear here
          </span>
        )}
      </div>

      {/* Metrics footer */}
      {hasResult && !panel.error && (
        <div
          style={{
            display: "flex",
            gap: 16,
            marginTop: 10,
            fontSize: 12,
            color: "var(--text-secondary)",
            flexWrap: "wrap",
          }}
        >
          {panel.latencyMs !== null && (
            <span>⏱ {panel.latencyMs.toLocaleString()} ms</span>
          )}
          {panel.inputTokens !== null && (
            <span>↑ {panel.inputTokens.toLocaleString()} in</span>
          )}
          {panel.outputTokens !== null && (
            <span>↓ {panel.outputTokens.toLocaleString()} out</span>
          )}
          {panel.costUsd !== null && (
            <span>$ {panel.costUsd < 0.001 ? panel.costUsd.toExponential(2) : panel.costUsd.toFixed(4)}</span>
          )}
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Playground page
// ---------------------------------------------------------------------------

const BLINK_STYLE = `@keyframes aig-blink { 0%,100%{opacity:1} 50%{opacity:0} }`;

export default function Playground() {
  useDocumentTitle("Playground");

  // Gateway selection
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [gateways, setGateways] = useState<Gateway[]>([]);
  const [selectedTenantId, setSelectedTenantId] = useState("");
  const [selectedGatewayId, setSelectedGatewayId] = useState("");

  // Models
  const [models, setModels] = useState<ModelPrice[]>([]);

  // Playground token (short-lived, per gateway)
  const [playToken, setPlayToken] = useState<PlaygroundToken | null>(null);
  const tokenExpiresAt = useRef<Date | null>(null);

  // Prompt
  const [systemPrompt, setSystemPrompt] = useState("");
  const [userMessage, setUserMessage] = useState("");
  const [showSystem, setShowSystem] = useState(false);

  // Params
  const [temperature, setTemperature] = useState(0.7);
  const [maxTokens, setMaxTokens] = useState(1024);
  const [showParams, setShowParams] = useState(false);

  // Panels (1–4 models to compare)
  const [panels, setPanels] = useState<PanelState[]>([makePanel()]);

  const [globalError, setGlobalError] = useState<string | null>(null);

  // ── Load tenants + models on mount ────────────────────────────────────────
  useEffect(() => {
    api.get<Tenant[]>("/tenants").then(setTenants).catch(() => {});
    api.get<ModelPrice[]>("/models").then(setModels).catch(() => {});
  }, []);

  // ── Load gateways when tenant changes ─────────────────────────────────────
  useEffect(() => {
    if (!selectedTenantId) { setGateways([]); setSelectedGatewayId(""); return; }
    api
      .get<Gateway[]>(`/tenants/${selectedTenantId}/gateways`)
      .then((rows) => {
        setGateways(rows);
        setSelectedGatewayId(rows[0]?.id ?? "");
      })
      .catch(() => {});
  }, [selectedTenantId]);

  // Auto-select first tenant
  useEffect(() => {
    if (tenants.length > 0 && !selectedTenantId) {
      setSelectedTenantId(tenants[0].id);
    }
  }, [tenants, selectedTenantId]);

  // ── Fetch / refresh playground token when gateway changes ─────────────────
  const refreshToken = async (gatewayId: string) => {
    try {
      const tok = await api.post<PlaygroundToken>("/playground/token", {
        gateway_id: gatewayId,
      });
      setPlayToken(tok);
      tokenExpiresAt.current = new Date(tok.expires_at);
    } catch (e) {
      setGlobalError("Could not create playground token: " + String(e));
    }
  };

  useEffect(() => {
    if (!selectedGatewayId) { setPlayToken(null); return; }
    refreshToken(selectedGatewayId);
  }, [selectedGatewayId]);

  // ── Run completions ────────────────────────────────────────────────────────
  const run = async () => {
    if (!userMessage.trim()) return;
    if (!playToken) {
      setGlobalError("No active gateway token. Select a gateway first.");
      return;
    }

    // Refresh token if near expiry (< 60 s left)
    if (
      tokenExpiresAt.current &&
      tokenExpiresAt.current.getTime() - Date.now() < 60_000
    ) {
      await refreshToken(selectedGatewayId);
    }

    const tok = playToken;
    const messages: { role: string; content: string }[] = [];
    if (systemPrompt.trim()) messages.push({ role: "system", content: systemPrompt.trim() });
    messages.push({ role: "user", content: userMessage.trim() });

    // Mark all panels loading
    setPanels((prev) =>
      prev.map((p) => ({
        ...p,
        loading: true,
        content: null,
        error: null,
        latencyMs: null,
        inputTokens: null,
        outputTokens: null,
        costUsd: null,
      }))
    );
    setGlobalError(null);

    const compatBase = `/v1/${tok.tenant_slug}/${tok.gateway_slug}/compat`;

    const runPanel = async (panel: PanelState) => {
      if (!panel.model) {
        setPanels((prev) =>
          prev.map((p) =>
            p.id === panel.id
              ? { ...p, loading: false, error: "No model selected" }
              : p
          )
        );
        return;
      }

      const start = performance.now();
      try {
        const res = await fetch(`${compatBase}/chat/completions`, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${tok.token}`,
          },
          body: JSON.stringify({
            model: panel.model,
            messages,
            temperature,
            max_tokens: maxTokens,
            stream: true,
          }),
        });

        if (!res.ok) {
          const latencyMs = Math.round(performance.now() - start);
          let msg = `HTTP ${res.status}`;
          try {
            const data = await res.json();
            msg = data?.error?.message ?? data?.error ?? msg;
          } catch { /* keep HTTP status */ }
          setPanels((prev) =>
            prev.map((p) =>
              p.id === panel.id
                ? { ...p, loading: false, error: String(msg), latencyMs }
                : p
            )
          );
          return;
        }

        // Stream SSE chunks and update panel incrementally
        const reader = res.body!.getReader();
        const decoder = new TextDecoder();
        let accumulated = "";
        let buf = "";

        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          buf += decoder.decode(value, { stream: true });

          // Process complete SSE lines
          const lines = buf.split("\n");
          buf = lines.pop() ?? ""; // keep incomplete last line

          for (const line of lines) {
            if (!line.startsWith("data: ")) continue;
            const data = line.slice(6).trim();
            if (data === "[DONE]") continue;
            try {
              const chunk = JSON.parse(data);
              const delta = chunk?.choices?.[0]?.delta?.content;
              if (delta) {
                accumulated += delta;
                // Progressive update while streaming
                setPanels((prev) =>
                  prev.map((p) =>
                    p.id === panel.id
                      ? { ...p, content: accumulated }
                      : p
                  )
                );
              }
            } catch { /* skip malformed chunks */ }
          }
        }

        const latencyMs = Math.round(performance.now() - start);
        // Streaming doesn't return usage counts; only latency is known
        setPanels((prev) =>
          prev.map((p) =>
            p.id === panel.id
              ? {
                  ...p,
                  loading: false,
                  content: accumulated || "(no content)",
                  latencyMs,
                  inputTokens: null,
                  outputTokens: null,
                  costUsd: null,
                }
              : p
          )
        );
      } catch (err) {
        const latencyMs = Math.round(performance.now() - start);
        setPanels((prev) =>
          prev.map((p) =>
            p.id === panel.id
              ? { ...p, loading: false, error: String(err), latencyMs }
              : p
          )
        );
      }
    };

    // Capture current panels snapshot and fire in parallel
    setPanels((prev) => {
      Promise.all(prev.map(runPanel));
      return prev;
    });
  };

  const addPanel = () => {
    if (panels.length >= 4) return;
    setPanels((prev) => [...prev, makePanel()]);
  };

  const removePanel = (id: string) => {
    setPanels((prev) => prev.filter((p) => p.id !== id));
  };

  const updatePanelModel = (id: string, model: string) => {
    setPanels((prev) =>
      prev.map((p) => (p.id === id ? { ...p, model } : p))
    );
  };

  const isRunning = panels.some((p) => p.loading);
  const canRun =
    !!userMessage.trim() &&
    !!playToken &&
    panels.every((p) => !!p.model);

  // ── Render ─────────────────────────────────────────────────────────────────
  return (
    <main role="main" className={s.page}>
      <style>{BLINK_STYLE}</style>
      {/* Header */}
      <div className={s["page-header"]}>
        <h1 className={s["page-title"]}>Playground</h1>
        <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
          {panels.length < 4 && (
            <button
              type="button"
              className={`${s.btn} ${s["btn--secondary"]}`}
              onClick={addPanel}
              disabled={isRunning}
            >
              + Add Model
            </button>
          )}
          <button
            type="button"
            className={`${s.btn} ${s["btn--primary"]}`}
            onClick={run}
            disabled={!canRun || isRunning}
            aria-label="Run"
          >
            {isRunning ? "Running…" : "▶ Run"}
          </button>
        </div>
      </div>

      {globalError && (
        <div className={`${s.alert} ${s["alert--error"]}`} style={{ marginBottom: 16 }}>
          {globalError}
        </div>
      )}

      {/* Config bar */}
      <div className={s.card}>
        <div style={{ display: "flex", gap: 16, flexWrap: "wrap", alignItems: "flex-end" }}>
          {/* Tenant */}
          <div className={s["form-group"]} style={{ marginBottom: 0, minWidth: 160 }}>
            <label className={s["form-label"]}>Tenant</label>
            <select
              className={s["form-select"]}
              value={selectedTenantId}
              onChange={(e) => setSelectedTenantId(e.target.value)}
            >
              {tenants.map((t) => (
                <option key={t.id} value={t.id}>{t.slug}</option>
              ))}
            </select>
          </div>

          {/* Gateway */}
          <div className={s["form-group"]} style={{ marginBottom: 0, minWidth: 160 }}>
            <label className={s["form-label"]}>Gateway</label>
            <select
              className={s["form-select"]}
              value={selectedGatewayId}
              onChange={(e) => setSelectedGatewayId(e.target.value)}
            >
              {gateways.map((g) => (
                <option key={g.id} value={g.id}>{g.slug}</option>
              ))}
            </select>
          </div>

          {/* Token status */}
          {playToken && (
            <div style={{ fontSize: 12, color: "var(--text-secondary)", alignSelf: "center" }}>
              <span
                className={`${s.badge} ${s["badge--success"]}`}
                style={{ fontSize: 11 }}
              >
                token active
              </span>
            </div>
          )}

          <div style={{ marginLeft: "auto", display: "flex", gap: 8 }}>
            <button
              type="button"
              className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
              onClick={() => setShowSystem((v) => !v)}
            >
              {showSystem ? "Hide system" : "System prompt"}
            </button>
            <button
              type="button"
              className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
              onClick={() => setShowParams((v) => !v)}
            >
              {showParams ? "Hide params" : "Parameters"}
            </button>
          </div>
        </div>

        {/* System prompt */}
        {showSystem && (
          <div style={{ marginTop: 16 }}>
            <label className={s["form-label"]}>System prompt</label>
            <textarea
              className={s["form-input"]}
              rows={3}
              placeholder="You are a helpful assistant…"
              value={systemPrompt}
              onChange={(e) => setSystemPrompt(e.target.value)}
              style={{ resize: "vertical", fontFamily: "inherit" }}
              aria-label="System prompt"
            />
          </div>
        )}

        {/* Parameters */}
        {showParams && (
          <div className={s["form-row"]} style={{ marginTop: 16 }}>
            <div className={s["form-group"]} style={{ marginBottom: 0 }}>
              <label className={s["form-label"]}>
                Temperature: {temperature}
              </label>
              <input
                type="range"
                min={0}
                max={2}
                step={0.05}
                value={temperature}
                onChange={(e) => setTemperature(parseFloat(e.target.value))}
                style={{ width: "100%" }}
                aria-label="Temperature"
              />
            </div>
            <div className={s["form-group"]} style={{ marginBottom: 0 }}>
              <label className={s["form-label"]}>Max tokens</label>
              <input
                type="number"
                className={s["form-input"]}
                min={1}
                max={32768}
                value={maxTokens}
                onChange={(e) =>
                  setMaxTokens(Math.max(1, parseInt(e.target.value) || 1))
                }
                aria-label="Max tokens"
              />
            </div>
          </div>
        )}
      </div>

      {/* Panels grid */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: `repeat(${panels.length}, minmax(0, 1fr))`,
          gap: 16,
          marginBottom: 16,
        }}
      >
        {panels.map((panel) => (
          <PanelResult
            key={panel.id}
            panel={panel}
            models={models}
            onModelChange={(model) => updatePanelModel(panel.id, model)}
            onRemove={() => removePanel(panel.id)}
            canRemove={panels.length > 1}
          />
        ))}
      </div>

      {/* Message input */}
      <div className={s.card} style={{ marginBottom: 0 }}>
        <label className={s["form-label"]}>Message</label>
        <textarea
          className={s["form-input"]}
          rows={4}
          placeholder="Enter your message…"
          value={userMessage}
          onChange={(e) => setUserMessage(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
              e.preventDefault();
              if (canRun && !isRunning) run();
            }
          }}
          disabled={isRunning}
          style={{ resize: "vertical", fontFamily: "inherit" }}
          aria-label="User message"
        />
        <div style={{ marginTop: 8, fontSize: 12, color: "var(--text-secondary)" }}>
          Tip: ⌘↵ / Ctrl↵ to run · {models.length.toLocaleString()} models available
        </div>
      </div>
    </main>
  );
}
