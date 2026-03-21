// PlaygroundDebugLog — append-only debug trace panel for the Playground.
// Every input, computed value, and output of every step is recorded here.

import { useCallback, useEffect, useRef, useState } from "react";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export type DebugLevel = "info" | "warn" | "error";

export interface DebugEntry {
  id: number;
  /** performance.now() at append time (ms since page load) */
  perfMs: number;
  /** Wall-clock HH:MM:SS.mmm */
  wallTime: string;
  level: DebugLevel;
  /** Dot-namespaced event identifier, e.g. "run.start", "panel.sse_chunk" */
  event: string;
  /** Panel model or id, if entry is panel-specific */
  panel?: string;
  /** Any JSON-serializable payload */
  data: unknown;
}

// Maximum entries kept in the log (oldest dropped when exceeded)
const MAX_ENTRIES = 5000;

// ---------------------------------------------------------------------------
// useDebugLog — log state + append function
// ---------------------------------------------------------------------------

export interface DebugLogHandle {
  entries: DebugEntry[];
  /** Append a new entry. level defaults to "info". */
  log: (event: string, data: unknown, panel?: string, level?: DebugLevel) => void;
  clear: () => void;
}

function wallClock(): string {
  const d = new Date();
  const pad2 = (n: number) => String(n).padStart(2, "0");
  const pad3 = (n: number) => String(n).padStart(3, "0");
  return `${pad2(d.getHours())}:${pad2(d.getMinutes())}:${pad2(d.getSeconds())}.${pad3(d.getMilliseconds())}`;
}

export function useDebugLog(): DebugLogHandle {
  const [entries, setEntries] = useState<DebugEntry[]>([]);
  const seq = useRef(0);

  const log = useCallback(
    (event: string, data: unknown, panel?: string, level: DebugLevel = "info") => {
      const entry: DebugEntry = {
        id: ++seq.current,
        perfMs: Math.round(performance.now()),
        wallTime: wallClock(),
        level,
        event,
        panel,
        data,
      };
      setEntries((prev) => {
        const next = [...prev, entry];
        return next.length > MAX_ENTRIES ? next.slice(next.length - MAX_ENTRIES) : next;
      });
    },
    []
  );

  const clear = useCallback(() => {
    setEntries([]);
    seq.current = 0;
  }, []);

  return { entries, log, clear };
}

// ---------------------------------------------------------------------------
// DebugLogPanel — collapsible table UI
// ---------------------------------------------------------------------------

interface DebugLogPanelProps {
  handle: DebugLogHandle;
}

const LEVEL_COLORS: Record<DebugLevel, string> = {
  info: "var(--text-primary)",
  warn: "var(--badge-warn-text, #92400e)",
  error: "var(--badge-error-text, #c0392b)",
};

const LEVEL_BG: Record<DebugLevel, string> = {
  info: "transparent",
  warn: "var(--badge-warn-bg, #fef3c7)",
  error: "var(--badge-error-bg, #fde8e8)",
};

const EVENT_COLOR: Record<string, string> = {
  "run.start":              "#7c3aed",
  "run.token_check":        "#0284c7",
  "run.token_refresh":      "#0284c7",
  "token.issued":           "#059669",
  "gateway.selected":       "#0891b2",
  "gateway.keys_loaded":    "#0891b2",
  "panel.search_mode":      "#7c3aed",
  "panel.request":          "#1d4ed8",
  "panel.http_response":    "#0f766e",
  "panel.stream_start":     "#0f766e",
  "panel.sse_chunk":        "#64748b",
  "panel.stream_complete":  "#059669",
  "panel.error":            "#dc2626",
  "panel.http_error":       "#dc2626",
  "panel.no_model":         "#d97706",
};

function eventColor(event: string): string {
  return EVENT_COLOR[event] ?? "#64748b";
}

// Inline expandable JSON cell
function DataCell({ data }: { data: unknown }) {
  const [expanded, setExpanded] = useState(false);

  if (data === undefined || data === null) {
    return <span style={{ color: "var(--text-muted, #aaa)", fontSize: 11 }}>—</span>;
  }

  const json = JSON.stringify(data, null, expanded ? 2 : 0);
  const preview = !expanded
    ? json.length > 120
      ? json.slice(0, 120) + "…"
      : json
    : json;

  return (
    <pre
      onClick={() => setExpanded((v) => !v)}
      style={{
        margin: 0,
        fontSize: 11,
        fontFamily: "var(--font-mono, monospace)",
        whiteSpace: expanded ? "pre-wrap" : "nowrap",
        overflow: "hidden",
        textOverflow: expanded ? undefined : "ellipsis",
        cursor: "pointer",
        color: "var(--text-primary)",
        lineHeight: 1.5,
        maxWidth: 600,
        wordBreak: expanded ? "break-all" : undefined,
        background: expanded ? "var(--section-bg)" : "transparent",
        borderRadius: expanded ? 3 : undefined,
        padding: expanded ? "2px 4px" : 0,
      }}
      title={expanded ? "Click to collapse" : "Click to expand"}
    >
      {preview}
    </pre>
  );
}

export function DebugLogPanel({ handle }: DebugLogPanelProps) {
  const { entries, log: _log, clear } = handle;
  const [open, setOpen] = useState(false);
  const [autoScroll, setAutoScroll] = useState(true);
  const [filter, setFilter] = useState("");
  const tableBodyRef = useRef<HTMLTableSectionElement>(null);

  // Auto-scroll to bottom when new entries arrive
  useEffect(() => {
    if (!open || !autoScroll || !tableBodyRef.current) return;
    const tbody = tableBodyRef.current;
    const container = tbody.parentElement?.parentElement;
    if (container) container.scrollTop = container.scrollHeight;
  }, [entries.length, open, autoScroll]);

  const copyJson = () => {
    const text = JSON.stringify(entries, null, 2);
    navigator.clipboard.writeText(text).catch(() => {
      const el = document.createElement("textarea");
      el.value = text;
      document.body.appendChild(el);
      el.select();
      document.execCommand("copy");
      document.body.removeChild(el);
    });
  };

  const lowerFilter = filter.toLowerCase();
  const visible = filter
    ? entries.filter(
        (e) =>
          e.event.toLowerCase().includes(lowerFilter) ||
          (e.panel ?? "").toLowerCase().includes(lowerFilter) ||
          e.level.includes(lowerFilter) ||
          JSON.stringify(e.data).toLowerCase().includes(lowerFilter)
      )
    : entries;

  const errorCount = entries.filter((e) => e.level === "error").length;
  const warnCount  = entries.filter((e) => e.level === "warn").length;

  return (
    <div
      style={{
        marginTop: 12,
        border: "1px solid var(--card-border)",
        borderRadius: 6,
        overflow: "hidden",
        background: "var(--card-bg)",
      }}
    >
      {/* Header / toggle */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 10,
          padding: "8px 12px",
          cursor: "pointer",
          background: "var(--section-bg)",
          borderBottom: open ? "1px solid var(--card-border)" : "none",
          userSelect: "none",
        }}
        onClick={() => setOpen((v) => !v)}
      >
        <span style={{ fontSize: 12, fontWeight: 600, color: "var(--text-secondary)" }}>
          {open ? "▾" : "▸"} Debug log
        </span>
        <span
          style={{
            fontSize: 11,
            background: "var(--section-bg)",
            border: "1px solid var(--card-border)",
            borderRadius: 10,
            padding: "1px 7px",
            color: "var(--text-secondary)",
          }}
        >
          {entries.length}
        </span>
        {errorCount > 0 && (
          <span
            style={{
              fontSize: 11,
              background: "var(--badge-error-bg, #fde8e8)",
              color: "var(--badge-error-text, #c0392b)",
              borderRadius: 10,
              padding: "1px 7px",
              fontWeight: 600,
            }}
          >
            {errorCount} error{errorCount !== 1 ? "s" : ""}
          </span>
        )}
        {warnCount > 0 && (
          <span
            style={{
              fontSize: 11,
              background: "var(--badge-warn-bg, #fef3c7)",
              color: "var(--badge-warn-text, #92400e)",
              borderRadius: 10,
              padding: "1px 7px",
              fontWeight: 600,
            }}
          >
            {warnCount} warn{warnCount !== 1 ? "s" : ""}
          </span>
        )}
        {/* Controls — stop propagation so they don't toggle open */}
        <div
          style={{ marginLeft: "auto", display: "flex", gap: 6 }}
          onClick={(e) => e.stopPropagation()}
        >
          <input
            type="text"
            placeholder="Filter…"
            value={filter}
            onChange={(e) => setFilter(e.target.value)}
            style={{
              fontSize: 11,
              padding: "2px 7px",
              borderRadius: 4,
              border: "1px solid var(--card-border)",
              background: "var(--card-bg)",
              color: "var(--text-primary)",
              width: 120,
            }}
            aria-label="Filter debug log"
          />
          <label
            style={{
              display: "flex",
              alignItems: "center",
              gap: 4,
              fontSize: 11,
              color: "var(--text-secondary)",
              cursor: "pointer",
              whiteSpace: "nowrap",
            }}
          >
            <input
              type="checkbox"
              checked={autoScroll}
              onChange={(e) => setAutoScroll(e.target.checked)}
              style={{ margin: 0 }}
            />
            Auto-scroll
          </label>
          <button
            type="button"
            onClick={copyJson}
            style={{
              fontSize: 11,
              padding: "2px 8px",
              borderRadius: 4,
              border: "1px solid var(--card-border)",
              background: "var(--card-bg)",
              color: "var(--text-secondary)",
              cursor: "pointer",
            }}
          >
            Copy JSON
          </button>
          <button
            type="button"
            onClick={clear}
            style={{
              fontSize: 11,
              padding: "2px 8px",
              borderRadius: 4,
              border: "1px solid var(--card-border)",
              background: "var(--card-bg)",
              color: "var(--badge-error-text, #c0392b)",
              cursor: "pointer",
            }}
          >
            Clear
          </button>
        </div>
      </div>

      {/* Table */}
      {open && (
        <div style={{ maxHeight: 500, overflowY: "auto" }}>
          {visible.length === 0 ? (
            <div
              style={{
                padding: "24px 16px",
                textAlign: "center",
                color: "var(--text-muted, #aaa)",
                fontSize: 12,
              }}
            >
              {entries.length === 0
                ? "No entries yet — run a request to start logging."
                : "No entries match the filter."}
            </div>
          ) : (
            <table
              style={{
                width: "100%",
                fontSize: 11,
                fontFamily: "var(--font-mono, monospace)",
                borderCollapse: "collapse",
                tableLayout: "fixed",
              }}
            >
              <colgroup>
                <col style={{ width: 28 }} />   {/* # */}
                <col style={{ width: 88 }} />   {/* time */}
                <col style={{ width: 44 }} />   {/* perf ms */}
                <col style={{ width: 44 }} />   {/* level */}
                <col style={{ width: 180 }} />  {/* event */}
                <col style={{ width: 110 }} />  {/* panel */}
                <col />                          {/* data */}
              </colgroup>
              <thead>
                <tr
                  style={{
                    borderBottom: "1px solid var(--card-border)",
                    position: "sticky",
                    top: 0,
                    background: "var(--section-bg)",
                    zIndex: 1,
                  }}
                >
                  {["#", "Time", "ms", "Level", "Event", "Panel", "Data"].map((h) => (
                    <th
                      key={h}
                      style={{
                        padding: "4px 8px",
                        textAlign: "left",
                        fontWeight: 600,
                        color: "var(--text-secondary)",
                        fontSize: 10,
                        textTransform: "uppercase",
                        letterSpacing: "0.05em",
                      }}
                    >
                      {h}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody ref={tableBodyRef}>
                {visible.map((e) => (
                  <tr
                    key={e.id}
                    style={{
                      borderBottom: "1px solid var(--card-border)",
                      background: LEVEL_BG[e.level],
                    }}
                  >
                    {/* # */}
                    <td
                      style={{
                        padding: "3px 8px",
                        color: "var(--text-muted, #aaa)",
                        whiteSpace: "nowrap",
                      }}
                    >
                      {e.id}
                    </td>
                    {/* Wall time */}
                    <td
                      style={{
                        padding: "3px 8px",
                        color: "var(--text-secondary)",
                        whiteSpace: "nowrap",
                      }}
                    >
                      {e.wallTime}
                    </td>
                    {/* Perf ms */}
                    <td
                      style={{
                        padding: "3px 8px",
                        color: "var(--text-muted, #aaa)",
                        whiteSpace: "nowrap",
                        textAlign: "right",
                      }}
                    >
                      {e.perfMs}
                    </td>
                    {/* Level */}
                    <td
                      style={{
                        padding: "3px 8px",
                        color: LEVEL_COLORS[e.level],
                        fontWeight: e.level !== "info" ? 700 : undefined,
                        whiteSpace: "nowrap",
                      }}
                    >
                      {e.level}
                    </td>
                    {/* Event */}
                    <td
                      style={{
                        padding: "3px 8px",
                        color: eventColor(e.event),
                        fontWeight: 600,
                        whiteSpace: "nowrap",
                        overflow: "hidden",
                        textOverflow: "ellipsis",
                      }}
                      title={e.event}
                    >
                      {e.event}
                    </td>
                    {/* Panel */}
                    <td
                      style={{
                        padding: "3px 8px",
                        color: "var(--text-secondary)",
                        whiteSpace: "nowrap",
                        overflow: "hidden",
                        textOverflow: "ellipsis",
                      }}
                      title={e.panel}
                    >
                      {e.panel ?? ""}
                    </td>
                    {/* Data */}
                    <td style={{ padding: "3px 8px", overflow: "hidden" }}>
                      <DataCell data={e.data} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      )}
    </div>
  );
}
