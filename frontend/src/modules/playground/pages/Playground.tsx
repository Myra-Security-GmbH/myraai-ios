import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import { api } from "src/api/client";
import type { Gateway, ModelPrice, PlaygroundToken, ProviderConfig, ProviderMeta, Tenant } from "src/api/types";
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
  errorStatus: number | null;
  startMs: number | null;          // performance.now() when run started
  latencyMs: number | null;
  inputTokens: number | null;
  outputTokens: number | null;
  cacheCreationTokens: number | null;
  cacheReadTokens: number | null;
  searchQuery: string | null;   // set while Claude is searching; persists as "searched for" after
}

function makePanel(model = ""): PanelState {
  return {
    id: Math.random().toString(36).slice(2),
    model,
    content: null,
    loading: false,
    error: null,
    errorStatus: null,
    startMs: null,
    latencyMs: null,
    inputTokens: null,
    outputTokens: null,
    cacheCreationTokens: null,
    cacheReadTokens: null,
    searchQuery: null,
  };
}

// ---------------------------------------------------------------------------
// Web search tool definition (Anthropic native format)
// ---------------------------------------------------------------------------

const WEB_SEARCH_TOOL = {
  name: "web_search",
  description:
    "Search the web for current information about recent events, news, people, or anything requiring up-to-date data not available in training data.",
  input_schema: {
    type: "object" as const,
    properties: {
      query: { type: "string", description: "The search query to look up" },
    },
    required: ["query"],
  },
};

// ---------------------------------------------------------------------------
// ModelPicker — searchable select grouped by provider
// ---------------------------------------------------------------------------

interface ModelPickerProps {
  models: ModelPrice[];
  value: string;
  onChange: (model: string) => void;
  runnableProviders: Set<string>;
  id?: string;
}

function ModelPicker({ models, value, onChange, runnableProviders, id }: ModelPickerProps) {
  const [search, setSearch] = useState("");
  const [open, setOpen] = useState(false);
  const [onlyRunnable, setOnlyRunnable] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  const lower = search.toLowerCase();
  const filtered = models.filter((m) => {
    if (onlyRunnable && !runnableProviders.has(m.provider)) return false;
    if (search && !m.model.toLowerCase().includes(lower) && !m.provider.toLowerCase().includes(lower)) return false;
    return true;
  });

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
            <label style={{ display: "flex", alignItems: "center", gap: 6, marginTop: 6, fontSize: 12, color: "var(--text-secondary)", cursor: "pointer", userSelect: "none" }}>
              <input
                type="checkbox"
                checked={onlyRunnable}
                onChange={(e) => setOnlyRunnable(e.target.checked)}
                aria-label="Only show runnable models"
              />
              Only show runnable models
            </label>
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
                    display: "flex",
                    alignItems: "center",
                    gap: 6,
                  }}
                >
                  {prov}
                  {!runnableProviders.has(prov) && (
                    <span style={{ opacity: 0.45, fontWeight: 400, fontSize: 10, textTransform: "none", letterSpacing: 0 }}>
                      no key
                    </span>
                  )}
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
  runnableProviders: Set<string>;
}

function PanelResult({
  panel,
  models,
  onModelChange,
  onRemove,
  canRemove,
  runnableProviders,
}: PanelResultProps) {
  const hasResult = panel.content !== null || panel.error !== null;
  const [rawMode, setRawMode] = useState(false);

  // Live elapsed-time counter while streaming
  const [elapsedMs, setElapsedMs] = useState<number | null>(null);
  useEffect(() => {
    if (!panel.loading || panel.startMs === null) { setElapsedMs(null); return; }
    const tick = () => setElapsedMs(Math.round(performance.now() - panel.startMs!));
    tick();
    const id = setInterval(tick, 100);
    return () => clearInterval(id);
  }, [panel.loading, panel.startMs]);

  // Cost estimate from token counts + model price table
  const modelInfo = models.find((m) => m.model === panel.model);
  const costUsd =
    modelInfo != null && panel.inputTokens !== null && panel.outputTokens !== null
      ? ((panel.inputTokens / 1000) * (modelInfo.input_per_1k ?? 0)) +
        ((panel.outputTokens / 1000) * (modelInfo.output_per_1k ?? 0)) +
        (((panel.cacheCreationTokens ?? 0) / 1000) * (modelInfo.cache_write_per_1k ?? 0)) +
        (((panel.cacheReadTokens ?? 0) / 1000) * (modelInfo.cache_read_per_1k ?? 0))
      : null;

  const displayMs = panel.loading ? elapsedMs : panel.latencyMs;

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
            runnableProviders={runnableProviders}
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
        {/* Spinner only while waiting for the first token (not shown when search indicator is visible) */}
        {panel.loading && panel.content === null && !panel.error && !panel.searchQuery && (
          <span style={{ color: "var(--text-secondary)" }}>Running…</span>
        )}
        {/* Error display */}
        {panel.error && (
          <div>
            <div style={{ display: "flex", alignItems: "center", gap: 6, marginBottom: 4 }}>
              <span
                style={{
                  display: "inline-block",
                  background: "var(--badge-error-bg, #fde8e8)",
                  color: "var(--badge-error-text, #c0392b)",
                  borderRadius: 3,
                  padding: "1px 7px",
                  fontSize: 11,
                  fontWeight: 700,
                  letterSpacing: "0.03em",
                }}
              >
                {panel.errorStatus === 401 || panel.errorStatus === 403
                  ? "AUTH ERROR"
                  : panel.errorStatus === 404
                  ? "NOT FOUND"
                  : panel.errorStatus === 429
                  ? "RATE LIMITED"
                  : panel.errorStatus != null && panel.errorStatus >= 500
                  ? `SERVER ERROR ${panel.errorStatus}`
                  : panel.errorStatus != null
                  ? `HTTP ${panel.errorStatus}`
                  : "ERROR"}
              </span>
              {(panel.errorStatus === 429 || (panel.errorStatus != null && panel.errorStatus >= 500)) && (
                <span style={{ fontSize: 11, color: "var(--text-secondary)" }}>
                  Try again in a moment
                </span>
              )}
              {(panel.errorStatus === 401 || panel.errorStatus === 403) && (
                <span style={{ fontSize: 11, color: "var(--text-secondary)" }}>
                  Check your gateway token
                </span>
              )}
            </div>
            <div style={{ fontSize: 12, fontFamily: "var(--font-mono, monospace)", whiteSpace: "pre-wrap", wordBreak: "break-all" }}>
              {panel.error}
            </div>
          </div>
        )}
        {/* Search indicator — shown while searching and persists as provenance after */}
        {panel.searchQuery && !panel.error && (
          <div
            style={{
              marginBottom: 8,
              display: "flex",
              alignItems: "center",
              gap: 6,
              fontSize: 12,
              color: "var(--text-secondary)",
            }}
          >
            <span
              style={{
                display: "inline-block",
                background: "var(--badge-info-bg, #e8f0fe)",
                color: "var(--badge-info-text, #1a56c4)",
                borderRadius: 3,
                padding: "1px 7px",
                fontSize: 11,
                fontWeight: 600,
                letterSpacing: "0.03em",
                flexShrink: 0,
              }}
            >
              {panel.loading && panel.content === null ? "searching" : "searched"}
            </span>
            <span
              style={{
                fontFamily: "var(--font-mono, monospace)",
                overflow: "hidden",
                textOverflow: "ellipsis",
                whiteSpace: "nowrap",
              }}
            >
              {panel.searchQuery}
            </span>
          </div>
        )}
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

      {/* Metrics footer — shown while loading (live) and after completion */}
      {(hasResult || panel.loading) && !panel.error && (
        <div
          style={{
            display: "flex",
            gap: 12,
            marginTop: 10,
            fontSize: 12,
            color: "var(--text-secondary)",
            flexWrap: "wrap",
            alignItems: "center",
          }}
        >
          {displayMs !== null && (
            <span aria-label="Latency">
              ⏱ {displayMs.toLocaleString()} ms{panel.loading ? "…" : ""}
            </span>
          )}
          {panel.inputTokens !== null && (
            <span title="Input tokens" aria-label="Input tokens">
              ↑ {panel.inputTokens.toLocaleString()} in
            </span>
          )}
          {panel.outputTokens !== null && (
            <span title="Output tokens" aria-label="Output tokens">
              ↓ {panel.outputTokens.toLocaleString()} out
            </span>
          )}
          {panel.cacheCreationTokens !== null && panel.cacheCreationTokens > 0 && (
            <span title="Cache write tokens" aria-label="Cache write tokens">
              ✍ {panel.cacheCreationTokens.toLocaleString()} cache write
            </span>
          )}
          {panel.cacheReadTokens !== null && panel.cacheReadTokens > 0 && (
            <span title="Cache read tokens" aria-label="Cache read tokens">
              ⚡ {panel.cacheReadTokens.toLocaleString()} cache read
            </span>
          )}
          {costUsd !== null && (
            <span title="Estimated cost" aria-label="Estimated cost">
              $ {costUsd < 0.0001 ? costUsd.toExponential(2) : costUsd.toFixed(4)}
            </span>
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

// ---------------------------------------------------------------------------
// Persisted state helpers
// ---------------------------------------------------------------------------

const STORAGE_KEY = "aig_playground_v1";

interface PersistedState {
  tenantId: string;
  gatewayId: string;
  panelModels: string[];
  systemPrompt: string;
  temperature: number;
  maxTokens: number;
}

function loadPersistedState(): Partial<PersistedState> {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    return raw ? (JSON.parse(raw) as Partial<PersistedState>) : {};
  } catch {
    return {};
  }
}

function savePersistedState(s: PersistedState) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(s));
  } catch { /* quota exceeded — ignore */ }
}

export default function Playground() {
  useDocumentTitle("Playground");

  const persisted = useRef(loadPersistedState());

  // Gateway selection
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [gateways, setGateways] = useState<Gateway[]>([]);
  const [selectedTenantId, setSelectedTenantId] = useState(persisted.current.tenantId ?? "");
  const [selectedGatewayId, setSelectedGatewayId] = useState("");

  // Models
  const [models, setModels] = useState<ModelPrice[]>([]);

  // Provider metadata + which providers have keys configured for the selected gateway
  const [providerMeta, setProviderMeta] = useState<ProviderMeta[]>([]);
  const [configuredProviders, setConfiguredProviders] = useState<Set<string>>(new Set());

  // Playground token (short-lived, per gateway)
  const [playToken, setPlayToken] = useState<PlaygroundToken | null>(null);
  const tokenExpiresAt = useRef<Date | null>(null);

  // Prompt
  const [systemPrompt, setSystemPrompt] = useState(persisted.current.systemPrompt ?? "");
  const [userMessage, setUserMessage] = useState("");
  const [showSystem, setShowSystem] = useState(!!(persisted.current.systemPrompt));

  // Params
  const [temperature, setTemperature] = useState(persisted.current.temperature ?? 0.7);
  const [maxTokens, setMaxTokens] = useState(persisted.current.maxTokens ?? 1024);
  const [showParams, setShowParams] = useState(false);
  const [webSearch, setWebSearch] = useState(false);

  // Panels (1–4 models to compare) — models restored after catalog loads
  const [panels, setPanels] = useState<PanelState[]>([makePanel()]);

  const [globalError, setGlobalError] = useState<string | null>(null);

  // ── Load tenants + models + provider metadata on mount ────────────────────
  useEffect(() => {
    api.get<Tenant[]>("/tenants").then(setTenants).catch(() => {});
    api.get<ModelPrice[]>("/models").then(setModels).catch(() => {});
    api.get<ProviderMeta[]>("/providers").then(setProviderMeta).catch(() => {});
  }, []);

  // ── Load gateways when tenant changes ─────────────────────────────────────
  useEffect(() => {
    if (!selectedTenantId) { setGateways([]); setSelectedGatewayId(""); return; }
    api
      .get<Gateway[]>(`/tenants/${selectedTenantId}/gateways`)
      .then((rows) => {
        setGateways(rows);
        // Restore persisted gateway if it belongs to this tenant, else first
        const saved = persisted.current.gatewayId;
        const match = saved && rows.find((r) => r.id === saved);
        setSelectedGatewayId(match ? saved! : (rows[0]?.id ?? ""));
      })
      .catch(() => {});
  }, [selectedTenantId]);

  // Ensure selectedTenantId is always a valid tenant (or first available)
  useEffect(() => {
    if (tenants.length === 0) return;
    if (!selectedTenantId || !tenants.some((t) => t.id === selectedTenantId)) {
      setSelectedTenantId(tenants[0].id);
    }
  }, [tenants, selectedTenantId]);

  // ── Reload configured provider keys when gateway changes ──────────────────
  useEffect(() => {
    if (!selectedGatewayId) { setConfiguredProviders(new Set()); return; }
    api
      .get<ProviderConfig[]>(`/gateways/${selectedGatewayId}/keys`)
      .then((keys) => setConfiguredProviders(new Set(keys.map((k) => k.provider))))
      .catch(() => {});
  }, [selectedGatewayId]);

  // ── Restore panel models once catalog loads ───────────────────────────────
  const panelModelsRestored = useRef(false);
  useEffect(() => {
    if (models.length === 0 || panelModelsRestored.current) return;
    panelModelsRestored.current = true;
    const saved = persisted.current.panelModels ?? [];
    if (saved.length === 0) return;
    // Only keep model names that still exist in the catalog
    const valid = saved.filter((m) => models.some((r) => r.model === m));
    if (valid.length === 0) return;
    setPanels(valid.map((m) => makePanel(m)));
  }, [models]);

  // ── Persist state on every relevant change ────────────────────────────────
  useEffect(() => {
    savePersistedState({
      tenantId: selectedTenantId,
      gatewayId: selectedGatewayId,
      panelModels: panels.map((p) => p.model),
      systemPrompt,
      temperature,
      maxTokens,
    });
  }, [selectedTenantId, selectedGatewayId, panels, systemPrompt, temperature, maxTokens]);

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

  // ── Derived: runnable providers + count ───────────────────────────────────
  const freeProviders = useMemo(
    () => new Set(providerMeta.filter((p) => !p.requires_key).map((p) => p.name)),
    [providerMeta]
  );

  const runnableProviders = useMemo(
    () => new Set([...freeProviders, ...configuredProviders]),
    [freeProviders, configuredProviders]
  );

  const runnableCount = useMemo(
    () => models.filter((m) => runnableProviders.has(m.provider)).length,
    [models, runnableProviders]
  );

  // Returns the web-search mode for a given model:
  //   "claude"      — Anthropic agentic 2-leg loop
  //   "gemini"      — compat path + google_search grounding tool injected
  //   "perplexity"  — compat path, search is built into the model
  //   null          — not supported
  const getWebSearchMode = useCallback(
    (model: string): "claude" | "gemini" | "perplexity" | null => {
      if (model.startsWith("claude-")) return "claude";
      const meta = models.find((m) => m.model === model);
      if (meta?.provider === "gemini") return "gemini";
      if (meta?.provider === "perplexity") return "perplexity";
      return null;
    },
    [models]
  );

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

    const runStartMs = performance.now();

    // Snapshot the panels BEFORE the loading update so runPanel has stable model values.
    // IMPORTANT: runPanel must be called outside any setPanels callback — running side
    // effects inside a state updater is an anti-pattern that causes React (StrictMode /
    // concurrent mode) to invoke the updater multiple times, firing duplicate requests.
    const panelSnapshot = panels;

    // Mark all panels loading
    setPanels((prev) =>
      prev.map((p) => ({
        ...p,
        loading: true,
        content: null,
        error: null,
        errorStatus: null,
        startMs: runStartMs,
        latencyMs: null,
        inputTokens: null,
        outputTokens: null,
        cacheCreationTokens: null,
        cacheReadTokens: null,
        searchQuery: null,
      }))
    );
    setGlobalError(null);

    const compatBase = `/v1/${tok.tenant_slug}/${tok.gateway_slug}/compat`;

    const anthropicBase = `/v1/${tok.tenant_slug}/${tok.gateway_slug}/anthropic/v1/messages`;

    const runPanel = async (panel: PanelState) => {
      if (!panel.model) {
        setPanels((prev) =>
          prev.map((p) =>
            p.id === panel.id
              ? { ...p, loading: false, error: "No model selected", errorStatus: null }
              : p
          )
        );
        return;
      }

      const start = performance.now();
      const commonHeaders = {
        "Content-Type": "application/json",
        Authorization: `Bearer ${tok.token}`,
      };

      // ── Web search agentic loop (Claude models only, native Anthropic API) ──
      const searchMode = getWebSearchMode(panel.model);
      if (webSearch && searchMode === "claude") {
        try {
          // Build Anthropic-format messages (system goes in top-level field)
          const anthropicMessages: object[] = messages
            .filter((m) => m.role !== "system")
            .map((m) => ({ role: m.role, content: m.content }));

          // Fix 1: inject tool-use guidance so Claude reliably calls web_search
          // instead of responding with "I don't have the ability to search".
          const WEB_SEARCH_INSTRUCTION =
            "You have a web_search tool available. Use it whenever the user asks about current events, recent news, live data, or anything that may have changed since your training cutoff.";
          const baseSystem = systemPrompt.trim();
          const system = baseSystem
            ? `${baseSystem}\n\n${WEB_SEARCH_INSTRUCTION}`
            : WEB_SEARCH_INSTRUCTION;

          // Leg 1 — non-streaming: let Claude decide whether to search
          const leg1Res = await fetch(anthropicBase, {
            method: "POST",
            headers: commonHeaders,
            body: JSON.stringify({
              model: panel.model,
              max_tokens: maxTokens,
              temperature,
              tools: [WEB_SEARCH_TOOL],
              messages: anthropicMessages,
              ...(system ? { system } : {}),
            }),
          });

          if (!leg1Res.ok) {
            const latencyMs = Math.round(performance.now() - start);
            let msg = `HTTP ${leg1Res.status}`;
            try {
              const data = await leg1Res.json();
              msg = data?.error?.message ?? data?.error?.type ?? msg;
            } catch { /* keep */ }
            setPanels((prev) =>
              prev.map((p) =>
                p.id === panel.id
                  ? { ...p, loading: false, error: msg, errorStatus: leg1Res.status, latencyMs }
                  : p
              )
            );
            return;
          }

          const leg1 = await leg1Res.json();

          if (leg1.stop_reason !== "tool_use") {
            // No search needed — display direct answer
            const text = (leg1.content ?? [])
              .filter((b: { type: string }) => b.type === "text")
              .map((b: { text: string }) => b.text)
              .join("");
            const latencyMs = Math.round(performance.now() - start);
            setPanels((prev) =>
              prev.map((p) =>
                p.id === panel.id
                  ? {
                      ...p,
                      loading: false,
                      content: text || "(no content)",
                      latencyMs,
                      inputTokens: leg1.usage?.input_tokens ?? null,
                      outputTokens: leg1.usage?.output_tokens ?? null,
                    }
                  : p
              )
            );
            return;
          }

          // Claude wants to search — collect ALL tool_use blocks (Opus may emit multiple)
          type ToolUseBlock = { id: string; name: string; input: { query: string } };
          const toolBlocks = (leg1.content ?? []).filter(
            (b: { type: string }) => b.type === "tool_use"
          ) as ToolUseBlock[];
          const searchQuery = toolBlocks.map((b) => b.input?.query).filter(Boolean).join(", ");

          // Show "searching…" indicator
          setPanels((prev) =>
            prev.map((p) => (p.id === panel.id ? { ...p, searchQuery } : p))
          );

          // Execute all searches in parallel
          const toolResults = await Promise.all(
            toolBlocks.map(async (toolBlock) => {
              const q = toolBlock.input?.query ?? "";
              try {
                const searchRes = await fetch(
                  `/admin/v1/playground/search?q=${encodeURIComponent(q)}`
                );
                const searchData = await searchRes.json();
                const results: Array<{ title: string; url: string; snippet: string }> =
                  searchData.results ?? [];
                const content =
                  results.length > 0
                    ? results.map((r) => `**${r.title}**\n${r.url}\n${r.snippet}`).join("\n\n")
                    : "No results found.";
                return { type: "tool_result" as const, tool_use_id: toolBlock.id, content };
              } catch {
                return { type: "tool_result" as const, tool_use_id: toolBlock.id, content: "Search failed." };
              }
            })
          );

          // Build messages with tool results for leg 2
          const nextMessages = [
            ...anthropicMessages,
            { role: "assistant", content: leg1.content },
            { role: "user", content: toolResults },
          ];

          // Leg 2 — streaming: final answer grounded in search results.
          // tools must be repeated — Anthropic requires it in every request
          // that references tool_use/tool_result blocks in the message history.
          const leg2Res = await fetch(anthropicBase, {
            method: "POST",
            headers: commonHeaders,
            body: JSON.stringify({
              model: panel.model,
              max_tokens: maxTokens,
              temperature,
              stream: true,
              tools: [WEB_SEARCH_TOOL],
              messages: nextMessages,
              ...(system ? { system } : {}),
            }),
          });

          if (!leg2Res.ok) {
            const latencyMs = Math.round(performance.now() - start);
            let msg = `HTTP ${leg2Res.status}`;
            try {
              const data = await leg2Res.json();
              msg = data?.error?.message ?? data?.error?.type ?? msg;
            } catch { /* keep */ }
            setPanels((prev) =>
              prev.map((p) =>
                p.id === panel.id
                  ? { ...p, loading: false, error: msg, errorStatus: leg2Res.status, latencyMs }
                  : p
              )
            );
            return;
          }

          // Stream Anthropic SSE format
          const reader2 = leg2Res.body!.getReader();
          const decoder2 = new TextDecoder();
          let accumulated = "";
          let buf2 = "";
          let inputTokens: number | null = null;
          let outputTokens: number | null = null;

          while (true) {
            const { value, done } = await reader2.read();
            if (done) break;
            buf2 += decoder2.decode(value, { stream: true });
            const lines = buf2.split("\n");
            buf2 = lines.pop() ?? "";
            for (const line of lines) {
              if (!line.startsWith("data: ")) continue;
              const raw = line.slice(6).trim();
              if (!raw) continue;
              try {
                const chunk = JSON.parse(raw);
                if (chunk.type === "content_block_delta" && chunk.delta?.type === "text_delta") {
                  accumulated += chunk.delta.text ?? "";
                  setPanels((prev) =>
                    prev.map((p) => (p.id === panel.id ? { ...p, content: accumulated } : p))
                  );
                }
                if (chunk.type === "message_start") {
                  inputTokens = chunk.message?.usage?.input_tokens ?? null;
                }
                if (chunk.type === "message_delta") {
                  outputTokens = chunk.usage?.output_tokens ?? null;
                }
              } catch { /* skip malformed */ }
            }
          }

          const latencyMs = Math.round(performance.now() - start);
          setPanels((prev) =>
            prev.map((p) =>
              p.id === panel.id
                ? {
                    ...p,
                    loading: false,
                    content: accumulated || "(no content)",
                    latencyMs,
                    inputTokens,
                    outputTokens,
                  }
                : p
            )
          );
        } catch (err) {
          const latencyMs = Math.round(performance.now() - start);
          const isNetwork = err instanceof TypeError && /fetch|network|failed/i.test(String(err));
          setPanels((prev) =>
            prev.map((p) =>
              p.id === panel.id
                ? {
                    ...p,
                    loading: false,
                    error: isNetwork ? "Network error — is the gateway running?" : String(err),
                    errorStatus: null,
                    latencyMs,
                    searchQuery: null,
                  }
                : p
            )
          );
        }
        return;
      }

      // ── Standard streaming via compat/OpenAI endpoint ────────────────────
      try {
        const res = await fetch(`${compatBase}/chat/completions`, {
          method: "POST",
          headers: commonHeaders,
          body: JSON.stringify({
            model: panel.model,
            messages,
            temperature,
            max_tokens: maxTokens,
            stream: true,
            // Inject web_search tool for Gemini → backend converts to googleSearch grounding
            ...(webSearch && searchMode === "gemini" ? { tools: [WEB_SEARCH_TOOL] } : {}),
          }),
        });

        if (!res.ok) {
          const latencyMs = Math.round(performance.now() - start);
          let msg = `HTTP ${res.status}`;
          try {
            const text = await res.text();
            const data = JSON.parse(text);
            // Try common error shapes: OpenAI, gateway native, plain string
            msg = data?.error?.message ?? data?.error ?? data?.message ?? text ?? msg;
          } catch { /* keep HTTP status message */ }
          setPanels((prev) =>
            prev.map((p) =>
              p.id === panel.id
                ? { ...p, loading: false, error: String(msg), errorStatus: res.status, latencyMs }
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
              // Content delta — update text progressively
              const delta = chunk?.choices?.[0]?.delta?.content;
              if (delta) {
                accumulated += delta;
                setPanels((prev) =>
                  prev.map((p) =>
                    p.id === panel.id ? { ...p, content: accumulated } : p
                  )
                );
              }
              // Usage chunk — update token counts in real-time
              const usage = chunk?.usage;
              if (usage) {
                setPanels((prev) =>
                  prev.map((p) =>
                    p.id === panel.id
                      ? {
                          ...p,
                          inputTokens: usage.prompt_tokens ?? null,
                          outputTokens: usage.completion_tokens ?? null,
                          cacheCreationTokens: usage.cache_creation_tokens ?? null,
                          cacheReadTokens: usage.cache_read_tokens ?? null,
                        }
                      : p
                  )
                );
              }
            } catch { /* skip malformed chunks */ }
          }
        }

        const latencyMs = Math.round(performance.now() - start);
        setPanels((prev) =>
          prev.map((p) =>
            p.id === panel.id
              ? {
                  ...p,
                  loading: false,
                  content: accumulated || "(no content)",
                  latencyMs,
                  // Token counts preserved from usage chunk (if received); no reset here
                }
              : p
          )
        );
      } catch (err) {
        const latencyMs = Math.round(performance.now() - start);
        const isNetwork = err instanceof TypeError && /fetch|network|failed/i.test(String(err));
        setPanels((prev) =>
          prev.map((p) =>
            p.id === panel.id
              ? {
                  ...p,
                  loading: false,
                  error: isNetwork ? "Network error — is the gateway running?" : String(err),
                  errorStatus: null,
                  latencyMs,
                }
              : p
          )
        );
      }
    };

    // Fire all panels in parallel using the pre-captured snapshot.
    Promise.all(panelSnapshot.map(runPanel));
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

  // Fix 2: hint when message looks search-related but web search toggle is off
  const SEARCH_HINT_RE = /\b(search|look up|lookup|latest|current|news|today|recent|right now|trending|find out|what('s| is) happening)\b/i;
  const showSearchHint =
    !webSearch &&
    SEARCH_HINT_RE.test(userMessage) &&
    panels.some((p) => getWebSearchMode(p.model) !== null);

  // True when web search is ON but at least one selected model doesn't support it
  const webSearchUnsupported =
    webSearch && panels.some((p) => p.model !== "" && getWebSearchMode(p.model) === null);

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
              className={`${s.btn} ${webSearch ? s["btn--primary"] : s["btn--secondary"]} ${s["btn--sm"]}`}
              onClick={() => setWebSearch((v) => !v)}
              title="Enable web search (Claude: agentic loop · Gemini: grounding · Perplexity: built-in)"
            >
              {webSearch ? "Web Search ON" : "Web Search"}
            </button>
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

        {/* Model availability summary */}
        {models.length > 0 && (
          <div style={{
            marginTop: 10,
            paddingTop: 8,
            borderTop: "1px solid var(--card-border)",
            fontSize: 12,
            display: "flex",
            gap: 16,
            alignItems: "center",
            flexWrap: "wrap",
          }}>
            <span>
              <strong>{runnableCount.toLocaleString()}</strong>
              <span style={{ color: "var(--text-secondary)" }}> runnable</span>
              <span style={{ margin: "0 8px", opacity: 0.35 }}>·</span>
              <span style={{ color: "var(--text-secondary)" }}>
                {models.length.toLocaleString()} in catalog
              </span>
            </span>
            {runnableCount < models.length && selectedGatewayId && (
              <span style={{ color: "var(--text-secondary)" }}>
                {(models.length - runnableCount).toLocaleString()} need a key —{" "}
                <a href="/gateways" style={{ color: "var(--link-color, #1a56c4)" }}>
                  configure in Gateways
                </a>
              </span>
            )}
          </div>
        )}

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
            runnableProviders={runnableProviders}
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
        <div style={{ marginTop: 8, fontSize: 12, color: "var(--text-secondary)", display: "flex", gap: 12, flexWrap: "wrap", alignItems: "center" }}>
          <span>Tip: ⌘↵ / Ctrl↵ to run</span>
          {webSearchUnsupported && (
            <span
              style={{
                background: "var(--badge-warn-bg, #fef3c7)",
                color: "var(--badge-warn-text, #92400e)",
                borderRadius: 4,
                padding: "2px 8px",
                fontWeight: 500,
              }}
              aria-label="Web search not supported"
            >
              Web search is not available for the selected model
            </span>
          )}
          {showSearchHint && (
            <span
              style={{
                background: "var(--badge-info-bg, #e8f0fe)",
                color: "var(--badge-info-text, #1a56c4)",
                borderRadius: 4,
                padding: "2px 8px",
                fontWeight: 500,
              }}
              aria-label="Web search hint"
            >
              Enable <strong>Web Search</strong> to let Claude look this up in real time
            </span>
          )}
        </div>
      </div>
    </main>
  );
}
