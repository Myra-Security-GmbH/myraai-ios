import { memo, useCallback, useEffect, useMemo, useRef, useState } from "react";
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
  searchQuery: string | null;      // set while searching; persists as "searched for" after
  fetchingUrls: number | null;     // set to URL count while gateway is fetching pages
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
    fetchingUrls: null,
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

const ModelPicker = memo(function ModelPicker({ models, value, onChange, runnableProviders, id }: ModelPickerProps) {
  const [search, setSearch] = useState("");
  const [open, setOpen] = useState(false);
  const [onlyRunnable, setOnlyRunnable] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  const { byProvider, providers } = useMemo(() => {
    const lower = search.toLowerCase();
    const filtered = models.filter((m) => {
      if (onlyRunnable && !runnableProviders.has(m.provider)) return false;
      if (search && !m.model.toLowerCase().includes(lower) && !m.provider.toLowerCase().includes(lower)) return false;
      // Exclude non-chat models: embedding, rerank, and moderation models
      // are not compatible with the chat completions endpoint.
      const lm = m.model.toLowerCase();
      if (lm.includes("embed") || lm.includes("rerank") || lm.includes("moderation")) return false;
      return true;
    });
    const byProvider: Record<string, ModelPrice[]> = {};
    for (const m of filtered) {
      (byProvider[m.provider] ??= []).push(m);
    }
    return { byProvider, providers: Object.keys(byProvider).sort() };
  }, [models, search, onlyRunnable, runnableProviders]);

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
                    className={s["model-option"]}
                    data-selected={m.model === value ? "true" : undefined}
                    onClick={() => {
                      onChange(m.model);
                      setOpen(false);
                      setSearch("");
                    }}
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
});

// ---------------------------------------------------------------------------
// MarkdownRenderer — renders model output as formatted markdown
// ---------------------------------------------------------------------------

// Convert bare https?:// URLs that aren't already inside a markdown link
// [...](url) into explicit [url](url) so ReactMarkdown renders them as <a>.
// remark-gfm handles most positions but misses URLs at end of a sentence
// (trailing punctuation) or inside parentheses.
const BARE_URL_RE = /(?<!\]\(|\[)(https?:\/\/[^\s<>"')\]]+)/g;
function withLinkedUrls(text: string): string {
  return text.replace(BARE_URL_RE, (url) => {
    const clean = url.replace(/[.,;:!?]+$/, ""); // strip trailing punctuation
    return `[${clean}](${clean})`;
  });
}

// LinkSafetyModal — shown when the user clicks a URL in model output.
// Requires explicit acknowledgement before opening the link.
function LinkSafetyModal({ url, onClose }: { url: string; onClose: () => void }) {
  function open() {
    window.open(url, "_blank", "noopener,noreferrer");
    onClose();
  }
  // Close on Escape
  useEffect(() => {
    const handler = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [onClose]);

  return (
    <div
      className={s["modal-overlay"]}
      onClick={(e) => e.target === e.currentTarget && onClose()}
    >
      <div className={s.modal} style={{ maxWidth: 480 }}>
        <div className={s["modal-header"]}>
          <h2 className={s["modal-title"]}>You are leaving this tool</h2>
          <button className={s["modal-close"]} onClick={onClose} aria-label="Close">
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none"
                 stroke="currentColor" strokeWidth="2">
              <line x1="18" y1="6" x2="6" y2="18"/>
              <line x1="6" y1="6" x2="18" y2="18"/>
            </svg>
          </button>
        </div>

        <p style={{ margin: "0 0 12px", lineHeight: 1.6, color: "var(--text-secondary)", fontSize: "0.92em" }}>
          This link was generated by an AI model. You are solely responsible
          for any site you choose to visit.
        </p>

        <div
          style={{
            background: "var(--section-bg)",
            border: "1px solid var(--card-border)",
            borderRadius: 6,
            padding: "8px 12px",
            fontFamily: "var(--font-mono, monospace)",
            fontSize: "0.82em",
            wordBreak: "break-all",
            color: "var(--text-primary)",
            marginBottom: 20,
            userSelect: "all",
          }}
        >
          {url}
        </div>

        <div className={s["form-actions"]}>
          <button className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>
            Cancel
          </button>
          <button className={`${s.btn} ${s["btn--primary"]}`} onClick={open}>
            Open link →
          </button>
        </div>
      </div>
    </div>
  );
}

function MarkdownRenderer({
  content,
  onLinkClick,
}: {
  content: string;
  onLinkClick?: (url: string) => void;
}) {
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
          <a
            href={href}
            style={{ color: "var(--accent)", textDecoration: "underline", cursor: "pointer" }}
            onClick={(e) => {
              e.preventDefault();
              if (href) onLinkClick ? onLinkClick(href) : window.open(href, "_blank", "noopener,noreferrer");
            }}
          >
            {children}
          </a>
        ),
        strong: ({ children }) => <strong style={{ fontWeight: 700 }}>{children}</strong>,
        em: ({ children }) => <em style={{ fontStyle: "italic" }}>{children}</em>,
      }}
    >
      {withLinkedUrls(content)}
    </ReactMarkdown>
  );
}

// ---------------------------------------------------------------------------
// PanelResult — response card for one model
// ---------------------------------------------------------------------------

interface PanelResultProps {
  panel: PanelState;
  models: ModelPrice[];
  onModelChange: (id: string, model: string) => void;
  onRemove: (id: string) => void;
  canRemove: boolean;
  runnableProviders: Set<string>;
}

const PanelResult = memo(function PanelResult({
  panel,
  models,
  onModelChange,
  onRemove,
  canRemove,
  runnableProviders,
}: PanelResultProps) {
  const handleModelChange = useCallback(
    (model: string) => onModelChange(panel.id, model),
    [onModelChange, panel.id]
  );
  const handleRemove = useCallback(
    () => onRemove(panel.id),
    [onRemove, panel.id]
  );
  const hasResult = panel.content !== null || panel.error !== null;
  const [rawMode, setRawMode] = useState(false);
  const [pendingUrl, setPendingUrl] = useState<string | null>(null);

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
            onChange={handleModelChange}
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
            onClick={handleRemove}
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
        {/* Search indicator — cycles through: searching → fetching N URLs → searched */}
        {panel.searchQuery !== null && !panel.error && (
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
              {panel.loading && panel.content === null
                ? panel.fetchingUrls !== null
                  ? `fetching ${panel.fetchingUrls} URL${panel.fetchingUrls !== 1 ? "s" : ""}`
                  : "searching"
                : "searched"}
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
                    <MarkdownRenderer content={panel.content} onLinkClick={setPendingUrl} />
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

      {pendingUrl && (
        <LinkSafetyModal url={pendingUrl} onClose={() => setPendingUrl(null)} />
      )}
    </div>
  );
});

// ---------------------------------------------------------------------------
// Playground page
// ---------------------------------------------------------------------------

const BLINK_STYLE = `@keyframes aig-blink { 0%,100%{opacity:1} 50%{opacity:0} }`;

// ---------------------------------------------------------------------------
// Persisted state helpers
// ---------------------------------------------------------------------------

const STORAGE_KEY = "aig_playground_v1";
const SEARCH_HINT_RE = /\b(search|look up|lookup|latest|current|news|today|recent|right now|trending|find out|what('s| is) happening)\b/i;
const DEFAULT_SYSTEM_PROMPT = `You are a professional research assistant.

### STRICT OPERATING RULES:
1. **NO HALLUCINATIONS:** If the answer is not clear, state: "I'm sorry, but I don't have information about the requested topic." Do not invent URLs or facts.
2. **LANGUAGE:** Always respond in English unless the user's message is explicitly written in a different language. The language of search results or referenced documents does NOT change the response language.
3. **WEB SEARCH RESULTS:** When you receive tool results from a web_search call, you MUST use the data in those results to answer the user's question directly. Extract and present the actual facts (numbers, dates, names) from the tool result content. Do NOT say you lack information if tool results are present.`;

interface PersistedState {
  tenantId: string;
  gatewayId: string;
  panelModels: string[];
  systemPrompt: string | undefined;
  webSearch: boolean;
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
  const [systemPrompt, setSystemPrompt] = useState(persisted.current.systemPrompt ?? DEFAULT_SYSTEM_PROMPT);
  const [userMessage, setUserMessage] = useState("");
  const [showSystem, setShowSystem] = useState(false);

  // Params
  const [temperature, setTemperature] = useState(persisted.current.temperature ?? 0.3);
  const [maxTokens, setMaxTokens] = useState(persisted.current.maxTokens ?? 1024);
  const [showParams, setShowParams] = useState(false);
  const [webSearch, setWebSearch] = useState(persisted.current.webSearch ?? false);

  // Panels (1–4 models to compare) — models restored after catalog loads
  const [panels, setPanels] = useState<PanelState[]>([makePanel()]);

  const [globalError, setGlobalError] = useState<string | null>(null);

  // ── Load tenants + models + provider metadata on mount ────────────────────
  useEffect(() => {
    api.get<Tenant[]>("/tenants")
      .then((rows) => { setTenants(rows); })
      .catch(() => {});
    api.get<ModelPrice[]>("/models")
      .then((rows) => { setModels(rows); })
      .catch(() => {});
    api.get<ProviderMeta[]>("/providers")
      .then((rows) => { setProviderMeta(rows); })
      .catch(() => {});
  // eslint-disable-next-line react-hooks/exhaustive-deps
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
        const chosen = match ? saved! : (rows[0]?.id ?? "");
        setSelectedGatewayId(chosen);
      })
      .catch(() => {});
  // eslint-disable-next-line react-hooks/exhaustive-deps
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
      .then((keys) => {
        const providers = keys.map((k) => k.provider);
        setConfiguredProviders(new Set(providers));
      })
      .catch(() => {});
  // eslint-disable-next-line react-hooks/exhaustive-deps
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

  // ── Persist state — debounced so rapid typing doesn't hammer localStorage ──
  useEffect(() => {
    const t = setTimeout(() => {
      savePersistedState({
        tenantId: selectedTenantId,
        gatewayId: selectedGatewayId,
        panelModels: panels.map((p) => p.model),
        systemPrompt: systemPrompt === DEFAULT_SYSTEM_PROMPT ? undefined : (systemPrompt || undefined),
        webSearch,
        temperature,
        maxTokens,
      });
    }, 400);
    return () => clearTimeout(t);
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
  //   "claude"      — Anthropic agentic 2-leg loop (native endpoint)
  //   "gemini"      — compat path + google_search grounding tool injected
  //   "perplexity"  — compat path, search is built into the model
  //   "openai"      — compat path, gateway injects web_search tool (2-leg loop)
  //   null          — not supported / unknown model
  const getWebSearchMode = useCallback(
    (model: string): "claude" | "gemini" | "perplexity" | "openai" | null => {
      if (model.startsWith("claude-")) return "claude";
      const meta = models.find((m) => m.model === model);
      // Only native Gemini models support Google Search grounding; Gemma models do not
      const modelName = model.replace(/^gemini\//, "");
      if (meta?.provider === "gemini" && modelName.startsWith("gemini")) return "gemini";
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
    const tokenAge = tokenExpiresAt.current
      ? tokenExpiresAt.current.getTime() - Date.now()
      : null;
    const needsRefresh = tokenAge !== null && tokenAge < 60_000;
    if (needsRefresh) {
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
        fetchingUrls: null,
      }))
    );
    setGlobalError(null);

    const gwBase = import.meta.env.VITE_GATEWAY_URL ?? "";
    const compatBase = `${gwBase}/v1/${tok.tenant_slug}/${tok.gateway_slug}/compat`;

    const anthropicBase = `${gwBase}/v1/${tok.tenant_slug}/${tok.gateway_slug}/anthropic/v1/messages`;

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

      // ── Web search: gateway handles the 2-leg loop server-side ─────────────
      // Clients opt-in per-request with X-Web-Search: 1.
      // The gateway injects the tool, calls the provider, runs the Brave search,
      // and streams the final grounded answer.  No client-side loop needed.
      const searchMode = getWebSearchMode(panel.model);
      const webSearchActive = !!(webSearch && searchMode && searchMode !== "perplexity");
      const wsHeaders = webSearchActive
        ? { ...commonHeaders, "X-Web-Search": "1" }
        : commonHeaders;

      // Show the "searching…" badge immediately — before the fetch even starts.
      // The gateway runs Leg 1 + Brave search before streaming, so there can be
      // 5-10 s of "Running…" with no visible search feedback otherwise.
      // searchQuery="" means "search in progress, query not yet known".
      if (webSearchActive) {
        setPanels((prev) => prev.map((p) =>
          p.id === panel.id ? { ...p, searchQuery: "" } : p
        ));
      }

      // Claude models: use the native Anthropic endpoint
      if (searchMode === "claude") {
        const anthropicMessages = messages
          .filter((m) => m.role !== "system")
          .map((m) => ({ role: m.role, content: m.content }));
        const userSys = systemPrompt.trim();
        // When web search is active, always inject the web search instruction into the system field.
        // User's own system prompt is preserved by prepending it.
        const claudeSystem = webSearch
          ? (userSys ? `${userSys}\n\n${DEFAULT_SYSTEM_PROMPT}` : DEFAULT_SYSTEM_PROMPT)
          : (userSys || undefined);

        try {
          // ── Web search: client-side 2-leg agentic loop ─────────────────────
          if (webSearch) {
            // Leg 1: non-streaming — get tool_use decision from model
            const leg1Res = await fetch(anthropicBase, {
              method: "POST",
              headers: commonHeaders,
              body: JSON.stringify({
                model: panel.model,
                max_tokens: maxTokens,
                temperature,
                stream: false,
                messages: anthropicMessages,
                system: claudeSystem,
                tools: [WEB_SEARCH_TOOL],
              }),
            });

            if (!leg1Res.ok) {
              const latencyMs = Math.round(performance.now() - start);
              let msg = `HTTP ${leg1Res.status}`;
              try { const d = await leg1Res.json(); msg = d?.error?.message ?? d?.error?.type ?? msg; }
              catch { /* keep */ }
              setPanels((prev) => prev.map((p) =>
                p.id === panel.id ? { ...p, loading: false, error: msg, errorStatus: leg1Res.status, latencyMs } : p
              ));
              return;
            }

            const leg1Data = await leg1Res.json();
            const toolUseBlocks: Array<{ id: string; name: string; input: { query?: string } }> =
              (leg1Data.content ?? []).filter((b: { type: string }) => b.type === "tool_use");

            // Model decided not to use web search — render leg1 text response directly
            if (toolUseBlocks.length === 0) {
              const textContent = (leg1Data.content ?? [])
                .filter((b: { type: string }) => b.type === "text")
                .map((b: { type: string; text?: string }) => b.text ?? "")
                .join("") || "(no content)";
              const latencyMs = Math.round(performance.now() - start);
              setPanels((prev) => prev.map((p) =>
                p.id === panel.id
                  ? { ...p, loading: false, content: textContent, latencyMs,
                      inputTokens: leg1Data.usage?.input_tokens ?? null,
                      outputTokens: leg1Data.usage?.output_tokens ?? null }
                  : p
              ));
              return;
            }

            // Show "searching" chip
            setPanels((prev) => prev.map((p) =>
              p.id === panel.id ? { ...p, searchQuery: "" } : p
            ));

            // Search for each tool_use block in parallel
            const toolResults = await Promise.all(
              toolUseBlocks.map(async (block) => {
                const q = block.input?.query ?? "";
                const searchRes = await fetch(
                  `/admin/v1/playground/search?q=${encodeURIComponent(q)}`,
                  { headers: commonHeaders }
                );
                const searchData = searchRes.ok
                  ? await searchRes.json().catch(() => ({ results: [] }))
                  : { results: [] };
                return {
                  type: "tool_result",
                  tool_use_id: block.id,
                  content: JSON.stringify(searchData.results ?? []),
                };
              })
            );

            // Surface search query in UI (use first tool_use query)
            if (toolUseBlocks.length > 0) {
              setPanels((prev) => prev.map((p) =>
                p.id === panel.id ? { ...p, searchQuery: toolUseBlocks[0].input?.query ?? "" } : p
              ));
            }

            // Leg 2: streaming — send tool results and get final answer
            const leg2Messages = [
              ...anthropicMessages,
              { role: "assistant", content: leg1Data.content },
              { role: "user", content: toolResults },
            ];

            const res = await fetch(anthropicBase, {
              method: "POST",
              headers: commonHeaders,
              body: JSON.stringify({
                model: panel.model,
                max_tokens: maxTokens,
                temperature,
                stream: true,
                messages: leg2Messages,
                system: claudeSystem,
                tools: [WEB_SEARCH_TOOL],
              }),
            });

            if (!res.ok) {
              const latencyMs = Math.round(performance.now() - start);
              let msg = `HTTP ${res.status}`;
              try { const d = await res.json(); msg = d?.error?.message ?? d?.error?.type ?? msg; }
              catch { /* keep */ }
              setPanels((prev) => prev.map((p) =>
                p.id === panel.id ? { ...p, loading: false, error: msg, errorStatus: res.status, latencyMs } : p
              ));
              return;
            }

            // Stream Anthropic SSE format (leg 2)
            const reader = res.body!.getReader();
            const decoder = new TextDecoder();
            let accumulated = "";
            let buf = "";
            let inputTokens: number | null = null;
            let outputTokens: number | null = null;

            while (true) {
              const { value, done } = await reader.read();
              if (done) break;
              buf += decoder.decode(value, { stream: true });
              const lines = buf.split("\n");
              buf = lines.pop() ?? "";
              for (const line of lines) {
                if (!line.startsWith("data: ")) continue;
                const raw = line.slice(6).trim();
                if (!raw) continue;
                try {
                  const chunk = JSON.parse(raw);
                  if (chunk.type === "content_block_delta" && chunk.delta?.type === "text_delta") {
                    accumulated += chunk.delta.text ?? "";
                    setPanels((prev) => prev.map((p) =>
                      p.id === panel.id ? { ...p, content: accumulated } : p
                    ));
                  }
                  if (chunk.type === "message_start") inputTokens = chunk.message?.usage?.input_tokens ?? null;
                  if (chunk.type === "message_delta") outputTokens = chunk.usage?.output_tokens ?? null;
                } catch { /* skip malformed */ }
              }
            }

            const latencyMs = Math.round(performance.now() - start);
            setPanels((prev) => prev.map((p) =>
              p.id === panel.id
                ? { ...p, loading: false, content: accumulated || "(no content)", latencyMs, inputTokens, outputTokens }
                : p
            ));
            return;
          }

          // ── Non-web-search Claude path: single streaming request ────────────
          const res = await fetch(anthropicBase, {
            method: "POST",
            headers: commonHeaders,
            body: JSON.stringify({
              model: panel.model,
              max_tokens: maxTokens,
              temperature,
              stream: true,
              messages: anthropicMessages,
              ...(claudeSystem ? { system: claudeSystem } : {}),
            }),
          });

          if (!res.ok) {
            const latencyMs = Math.round(performance.now() - start);
            let msg = `HTTP ${res.status}`;
            try { const d = await res.json(); msg = d?.error?.message ?? d?.error?.type ?? msg; }
            catch { /* keep */ }
            setPanels((prev) => prev.map((p) =>
              p.id === panel.id ? { ...p, loading: false, error: msg, errorStatus: res.status, latencyMs } : p
            ));
            return;
          }

          // Stream Anthropic SSE format
          const reader = res.body!.getReader();
          const decoder = new TextDecoder();
          let accumulated = "";
          let buf = "";
          let inputTokens: number | null = null;
          let outputTokens: number | null = null;

          while (true) {
            const { value, done } = await reader.read();
            if (done) break;
            buf += decoder.decode(value, { stream: true });
            const lines = buf.split("\n");
            buf = lines.pop() ?? "";
            for (const line of lines) {
              if (!line.startsWith("data: ")) continue;
              const raw = line.slice(6).trim();
              if (!raw) continue;
              try {
                const chunk = JSON.parse(raw);
                if (chunk?.aig_status === "fetching") {
                  setPanels((prev) => prev.map((p) =>
                    p.id === panel.id ? { ...p, fetchingUrls: chunk.count ?? 1 } : p
                  ));
                  continue;
                }
                if (chunk.type === "content_block_delta" && chunk.delta?.type === "text_delta") {
                  accumulated += chunk.delta.text ?? "";
                  setPanels((prev) => prev.map((p) =>
                    p.id === panel.id ? { ...p, content: accumulated, fetchingUrls: null } : p
                  ));
                }
                if (chunk.type === "message_start") inputTokens = chunk.message?.usage?.input_tokens ?? null;
                if (chunk.type === "message_delta") outputTokens = chunk.usage?.output_tokens ?? null;
              } catch { /* skip malformed */ }
            }
          }

          const latencyMs = Math.round(performance.now() - start);
          setPanels((prev) => prev.map((p) =>
            p.id === panel.id
              ? { ...p, loading: false, content: accumulated || "(no content)", latencyMs, inputTokens, outputTokens }
              : p
          ));
        } catch (err) {
          const latencyMs = Math.round(performance.now() - start);
          const isNetwork = err instanceof TypeError && /fetch|network|failed/i.test(String(err));
          setPanels((prev) => prev.map((p) =>
            p.id === panel.id
              ? { ...p, loading: false, error: isNetwork ? "Network error — is the gateway running?" : String(err), errorStatus: null, latencyMs, searchQuery: null }
              : p
          ));
        }
        return;
      }

      // ── Standard streaming via compat/OpenAI endpoint ────────────────────
      const compatRequestBody = {
        model: panel.model,
        messages,
        temperature,
        max_tokens: maxTokens,
        stream: true,
        ...(webSearchActive && searchMode === "gemini" ? { tools: [WEB_SEARCH_TOOL] } : {}),
      };
      const compatUrl = `${compatBase}/chat/completions`;
      try {
        const res = await fetch(compatUrl, {
          method: "POST",
          headers: wsHeaders,
          body: JSON.stringify(compatRequestBody),
        });

        // Surface the search query from response header (Gemini / other providers)
        const searched = res.headers.get("X-Web-Search-Query");
        if (searched) {
          setPanels((prev) => prev.map((p) =>
            p.id === panel.id ? { ...p, searchQuery: searched } : p
          ));
        }

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
        let inputTokens: number | null = null;
        let outputTokens: number | null = null;
        let cacheCreationTokens: number | null = null;
        let cacheReadTokens: number | null = null;

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
            if (data === "[DONE]") {
              continue;
            }
            try {
              const chunk = JSON.parse(data);
              // Gateway status event — update fetching badge
              if (chunk?.aig_status === "fetching") {
                setPanels((prev) => prev.map((p) =>
                  p.id === panel.id ? { ...p, fetchingUrls: chunk.count ?? 1 } : p
                ));
                continue;
              }
              // Content delta — update text progressively
              const delta = chunk?.choices?.[0]?.delta?.content;
              if (delta != null) {
                accumulated += delta;
                setPanels((prev) =>
                  prev.map((p) =>
                    p.id === panel.id ? { ...p, content: accumulated, fetchingUrls: null } : p
                  )
                );
              }
              // Usage chunk — update token counts in real-time
              const usage = chunk?.usage;
              if (usage) {
                inputTokens = usage.prompt_tokens ?? null;
                outputTokens = usage.completion_tokens ?? null;
                cacheCreationTokens = usage.cache_creation_tokens ?? null;
                cacheReadTokens = usage.cache_read_tokens ?? null;
                setPanels((prev) =>
                  prev.map((p) =>
                    p.id === panel.id
                      ? { ...p, inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens }
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

  const addPanel = useCallback(() => {
    setPanels((prev) => prev.length >= 4 ? prev : [...prev, makePanel()]);
  }, []);

  const removePanel = useCallback((id: string) => {
    setPanels((prev) => prev.filter((p) => p.id !== id));
  }, []);

  const updatePanelModel = useCallback((id: string, model: string) => {
    setPanels((prev) =>
      prev.map((p) => (p.id === id ? { ...p, model } : p))
    );
  }, []);

  const isRunning = panels.some((p) => p.loading);

  const showSearchHint = useMemo(
    () => !webSearch && SEARCH_HINT_RE.test(userMessage) && panels.some((p) => getWebSearchMode(p.model) !== null),
    [webSearch, userMessage, panels, getWebSearchMode]
  );

  // True when web search is ON but at least one selected model doesn't support it
  const webSearchUnsupported = useMemo(
    () => webSearch && panels.some((p) => p.model !== "" && getWebSearchMode(p.model) === null),
    [webSearch, panels, getWebSearchMode]
  );

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
            <div style={{ display: "flex", alignItems: "baseline", gap: 8, marginBottom: 6 }}>
              <label htmlFor="system-prompt" className={s["form-label"]} style={{ margin: 0 }}>
                System prompt
              </label>
              {systemPrompt !== DEFAULT_SYSTEM_PROMPT && (
                <button
                  type="button"
                  onClick={() => setSystemPrompt(DEFAULT_SYSTEM_PROMPT)}
                  style={{ background: "none", border: "none", padding: 0,
                           fontSize: 11, color: "var(--text-secondary)",
                           cursor: "pointer", textDecoration: "underline" }}
                >
                  restore default
                </button>
              )}
            </div>
            <textarea
              id="system-prompt"
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
            onModelChange={updatePanelModel}
            onRemove={removePanel}
            canRemove={panels.length > 1}
            runnableProviders={runnableProviders}
          />
        ))}
      </div>

      {/* Message input */}
      <div className={s.card} style={{ marginBottom: 16 }}>
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
