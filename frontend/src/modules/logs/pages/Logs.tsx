import { useEffect, useState, Fragment } from "react";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { api } from "src/api/client";
import { LogEntry, Tenant, TraceDetail, TraceStep } from "src/api/types";
import { fmtDateTime } from "src/common/utils/date";
import { fmtNumber } from "src/common/utils/format";
import s from "src/common/components/layout/Layout.module.scss";
import tp from "./TracePanel.module.scss";

// Step name → display label + color
const STEP_META: Record<string, { label: string; color: string }> = {
  request_received:    { label: "Received",         color: "#3b82f6" },
  request_transformed: { label: "Transformed",      color: "#6366f1" },
  routing_applied:     { label: "Routing",           color: "#8b5cf6" },
  guardrail_result:    { label: "Guardrail",         color: "#f59e0b" },
  upstream_request:    { label: "→ Provider",        color: "#6b7280" },
  upstream_response:   { label: "← Provider",        color: "#10b981" },
  upstream_error:      { label: "Provider Error",    color: "#ef4444" },
  response_delivered:  { label: "Delivered",         color: "#14b8a6" },
  leg2_response:       { label: "Leg-2 Response",    color: "#6b7280" },
};

function stepMeta(name: string) {
  return STEP_META[name] ?? { label: name, color: "#6b7280" };
}

function statusBadgeClass(status: string): string {
  if (status === "done")    return `${s.badge} ${s["badge--success"]}`;
  if (status === "blocked") return `${s.badge} ${s["badge--error"]}`;
  if (status === "error")   return `${s.badge} ${s["badge--error"]}`;
  return `${s.badge} ${s["badge--warning"]}`;
}

function TracePanel({ traceId, onClose }: { traceId: string; onClose: () => void }) {
  const [detail, setDetail] = useState<TraceDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [expanded, setExpanded] = useState<number | null>(null);

  useEffect(() => {
    setLoading(true);
    setDetail(null);
    api.get<TraceDetail>(`/traces/${traceId}`)
      .then(setDetail)
      .catch(() => {})
      .finally(() => setLoading(false));
  }, [traceId]);

  const startTs = detail?.trace.created_at ?? 0;

  return (
    <div className={tp.drawer}>
      <div className={tp.header}>
        <div>
          <div className={tp["header-title"]}>Request Trace</div>
          <div className={tp["header-id"]}>{traceId.slice(0, 8)}…</div>
        </div>
        <div className={tp["header-actions"]}>
          {detail && (
            <span className={statusBadgeClass(detail.trace.status)}>
              {detail.trace.status}
            </span>
          )}
          <button className={tp["close-btn"]} onClick={onClose} aria-label="Close">✕</button>
        </div>
      </div>

      <div className={tp.body}>
        {loading && <div className={tp.muted}>Loading…</div>}
        {!loading && !detail && <div className={tp.error}>Trace not found.</div>}
        {detail && detail.steps.map((step: TraceStep) => {
          const meta = stepMeta(step.step);
          const relMs = (step.ts - startTs) * 1000;
          const isOpen = expanded === step.id;
          return (
            <div key={step.id} className={tp.step}>
              <div
                className={`${tp["step-row"]} ${isOpen ? tp["step-row--open"] : ""}`}
                onClick={() => setExpanded(isOpen ? null : step.id)}
              >
                <div className={tp["step-dot-col"]}>
                  <div className={tp["step-dot"]} style={{ background: meta.color }} />
                </div>
                <div className={tp["step-content"]}>
                  <div className={tp["step-header"]}>
                    <span className={tp["step-label"]} style={{ color: meta.color }}>{meta.label}</span>
                    <span className={tp["step-time"]}>+{relMs >= 0 ? relMs : "?"}ms</span>
                  </div>
                  <div className={tp["step-name"]}>{step.step}</div>
                  <StepSummary step={step} />
                </div>
                <span className={tp["step-chevron"]}>{isOpen ? "▲" : "▼"}</span>
              </div>
              {isOpen && (
                <div className={tp["step-detail"]}>
                  <pre>{JSON.stringify(step.data, null, 2)}</pre>
                </div>
              )}
            </div>
          );
        })}
        {detail && detail.steps.length === 0 && (
          <div className={tp.empty}>No steps recorded.</div>
        )}
      </div>
    </div>
  );
}

function StepSummary({ step }: { step: TraceStep }) {
  const d = step.data;
  if (step.step === "request_received") {
    return (
      <div className={tp["step-summary"]}>
        {String(d.model ?? "")} · {String(d.messages_count ?? 0)} msg{Number(d.messages_count) !== 1 ? "s" : ""}
        {d.streaming ? " · stream" : ""}
        {d.size_bytes != null ? ` · ${d.size_bytes}B` : ""}
      </div>
    );
  }
  if (step.step === "request_transformed") {
    return (
      <div className={tp["step-summary"]}>
        {String(d.model_before ?? "")} → {String(d.model_after ?? "")}
        {d.provider_before !== d.provider_after ? ` (${String(d.provider_after ?? "")})` : ""}
      </div>
    );
  }
  if (step.step === "routing_applied") {
    return (
      <div className={tp["step-summary"]}>
        {String(d.provider_before ?? "")} → {String(d.provider_after ?? "")} / {String(d.model_after ?? "")}
        {Number(d.fallbacks_count) > 0 ? ` + ${d.fallbacks_count} fallbacks` : ""}
      </div>
    );
  }
  if (step.step === "guardrail_result") {
    return (
      <div className={d.blocked ? tp["step-summary--err"] : tp["step-summary--ok"]}>
        {String(d.verdict ?? "safe")}
        {d.blocked ? ` — ${String(d.block_reason ?? "")}` : ""}
        {d.latency_ms != null ? ` · ${d.latency_ms}ms` : ""}
      </div>
    );
  }
  if (step.step === "upstream_request") {
    return (
      <div className={tp["step-summary"]}>
        {String(d.provider ?? "")} / {String(d.model ?? "")}
        {d.attempt && Number(d.attempt) > 1 ? ` (attempt ${d.attempt})` : ""}
        {d.streaming ? " · stream" : ""}
      </div>
    );
  }
  if (step.step === "upstream_response") {
    return (
      <div className={Number(d.status) < 400 ? tp["step-summary--ok"] : tp["step-summary--err"]}>
        HTTP {String(d.status ?? "")} · {String(d.latency_ms ?? "")}ms
      </div>
    );
  }
  if (step.step === "upstream_error") {
    return (
      <div className={tp["step-summary--err"]}>
        {String(d.error ?? "")} · {String(d.latency_ms ?? "")}ms
      </div>
    );
  }
  if (step.step === "response_delivered") {
    return (
      <div className={tp["step-summary"]}>
        {d.streaming ? "streaming" : `${d.body_size}B`}
        {d.provider_status != null ? ` · HTTP ${d.provider_status}` : ""}
      </div>
    );
  }
  return null;
}


export default function Logs() {
  useDocumentTitle("Request Logs");
  const [logs, setLogs] = useState<LogEntry[]>([]);
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [loading, setLoading] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [tenantFilter, setTenantFilter] = useState("");
  const [providerFilter, setProviderFilter] = useState("");
  const [modelFilter, setModelFilter] = useState("");
  const [statusFilter, setStatusFilter] = useState("");
  const [blockedFilter, setBlockedFilter] = useState("");
  const [guardrailFilter, setGuardrailFilter] = useState("");
  const [limit, setLimit] = useState(50);
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [traceId, setTraceId] = useState<string | null>(null);

  useEffect(() => {
    api.get<Tenant[]>("/tenants").then(setTenants).catch(() => {});
  }, []);

  function load() {
    setLoading(true);
    setLoadError(null);
    const params = new URLSearchParams();
    if (tenantFilter) params.set("tenant_id", tenantFilter);
    if (providerFilter) params.set("provider", providerFilter);
    if (modelFilter) params.set("model", modelFilter);
    if (statusFilter) params.set("status", statusFilter);
    if (blockedFilter) params.set("blocked", blockedFilter);
    if (guardrailFilter) params.set("guardrail_outcome", guardrailFilter);
    params.set("limit", String(limit));
    api.get<LogEntry[]>(`/logs?${params}`)
      .then(setLogs)
      .catch((err: any) => setLoadError(err.message ?? "Failed to load logs"))
      .finally(() => setLoading(false));
  }

  useEffect(load, [tenantFilter, providerFilter, modelFilter, statusFilter, blockedFilter, guardrailFilter, limit]);

  const PROVIDERS = ["anthropic", "openai", "gemini", "mistral", "groq", "deepseek", "xai"];

  return (
    <main className={s.page}>
      <div className={s["page-header"]}>
        <div>
          <h1 className={s["page-title"]}>Request Logs</h1>
          <p className={s["page-subtitle"]}>{logs.length} entries</p>
        </div>
        <button className={`${s.btn} ${s["btn--secondary"]}`} onClick={load}>Refresh</button>
      </div>

      {/* Filters */}
      <div className={s.card}>
        <div style={{ display: "flex", gap: 16, flexWrap: "wrap", alignItems: "flex-end" }}>
          <div className={s["form-group"]} style={{ margin: 0, minWidth: 180 }}>
            <label className={s["form-label"]}>Tenant</label>
            <select className={s["form-select"]} value={tenantFilter} onChange={(e) => setTenantFilter(e.target.value)}>
              <option value="">All tenants</option>
              {tenants.map((t) => <option key={t.id} value={t.id}>{t.slug}</option>)}
            </select>
          </div>
          <div className={s["form-group"]} style={{ margin: 0, minWidth: 160 }}>
            <label className={s["form-label"]}>Provider</label>
            <select className={s["form-select"]} value={providerFilter} onChange={(e) => setProviderFilter(e.target.value)}>
              <option value="">All providers</option>
              {PROVIDERS.map((p) => <option key={p} value={p}>{p}</option>)}
            </select>
          </div>
          <div className={s["form-group"]} style={{ margin: 0, minWidth: 160 }}>
            <label className={s["form-label"]}>Model</label>
            <input className={s["form-input"]} placeholder="e.g. gpt-4o" value={modelFilter}
              onChange={(e) => setModelFilter(e.target.value)} />
          </div>
          <div className={s["form-group"]} style={{ margin: 0, minWidth: 120 }}>
            <label className={s["form-label"]}>Status</label>
            <select className={s["form-select"]} value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)}>
              <option value="">All</option>
              <option value="200">200 OK</option>
              <option value="400">400</option>
              <option value="401">401</option>
              <option value="429">429</option>
              <option value="500">500</option>
            </select>
          </div>
          <div className={s["form-group"]} style={{ margin: 0, minWidth: 120 }}>
            <label className={s["form-label"]}>Blocked</label>
            <select className={s["form-select"]} value={blockedFilter} onChange={(e) => setBlockedFilter(e.target.value)}>
              <option value="">All</option>
              <option value="1">Blocked only</option>
            </select>
          </div>
          <div className={s["form-group"]} style={{ margin: 0, minWidth: 160 }}>
            <label className={s["form-label"]}>Guardrail outcome</label>
            <select className={s["form-select"]} value={guardrailFilter} onChange={(e) => setGuardrailFilter(e.target.value)}>
              <option value="">All</option>
              <option value="any">Any hit</option>
              <option value="blocked">Blocked</option>
              <option value="scrubbed">Scrubbed</option>
              <option value="flagged">Flagged</option>
            </select>
          </div>
          <div className={s["form-group"]} style={{ margin: 0, minWidth: 100 }}>
            <label className={s["form-label"]}>Limit</label>
            <select className={s["form-select"]} value={limit} onChange={(e) => setLimit(Number(e.target.value))}>
              <option value={20}>20</option>
              <option value={50}>50</option>
              <option value={100}>100</option>
              <option value={200}>200</option>
            </select>
          </div>
        </div>
      </div>

      {loadError && <div className={`${s.alert} ${s["alert--error"]}`}>{loadError}</div>}
      {loading ? (
        <div className={s.empty}>Loading…</div>
      ) : logs.length === 0 ? (
        <div className={s.card}>
          <div className={s.empty}>
            <div className={s["empty-icon"]}>📋</div>
            No logs match your filters.
          </div>
        </div>
      ) : (
        <div className={s["table-wrapper"]}>
          <table className={s.table}>
            <thead>
              <tr>
                <th>Time</th>
                <th>Provider</th>
                <th>Model</th>
                <th>Status</th>
                <th>In</th>
                <th>Out</th>
                <th title="Cache write / read tokens">Cache</th>
                <th>Cost</th>
                <th>Latency</th>
                <th>Upstream</th>
                <th>Guardrail</th>
                <th>Detectors</th>
                <th>Flags</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {logs.map((row) => (
                <Fragment key={row.id}>
                <tr className={row.blocked ? s.blocked : ""}
                    style={(row.prompt || row.response_raw) ? { cursor: "pointer" } : undefined}
                    onClick={(row.prompt || row.response_raw) ? () => setExpandedId(expandedId === row.id ? null : row.id) : undefined}
                >
                  <td className={s.mono} style={{ fontSize: 11 }}>{fmtDateTime(row.ts)}</td>
                  <td>{row.provider}</td>
                  <td className={s.mono} style={{ fontSize: 11 }}>{row.model}</td>
                  <td>
                    <span className={`${s.badge} ${row.status >= 200 && row.status < 300 ? s["badge--success"] : s["badge--error"]}`}>
                      {row.status}
                    </span>
                  </td>
                  <td>{fmtNumber(row.input_tokens)}</td>
                  <td>{fmtNumber(row.output_tokens)}</td>
                  <td style={{ fontSize: 11, whiteSpace: "nowrap" }}>
                    {(() => {
                      const w = row.cache_creation_tokens ?? 0;
                      const r = row.cache_read_tokens ?? 0;
                      if (w === 0 && r === 0) return "—";
                      const total = w + r + (row.input_tokens ?? 0);
                      const hitPct = total > 0 ? Math.round(r * 100 / total) : 0;
                      const color = hitPct >= 80 ? "#10b981" : hitPct >= 40 ? "#f59e0b" : "#ef4444";
                      return (
                        <span title={`Cache write: ${fmtNumber(w)} · Cache read: ${fmtNumber(r)}`}>
                          {r > 0 && <span style={{ color, fontWeight: 600 }}>{hitPct}% hit</span>}
                          {r > 0 && w > 0 && " · "}
                          {w > 0 && <span style={{ color: "#94a3b8" }}>↑{fmtNumber(Math.round(w/1000))}k</span>}
                        </span>
                      );
                    })()}
                  </td>
                  <td>{row.cost_usd != null ? `$${row.cost_usd.toFixed(5)}` : "—"}</td>
                  <td>{fmtNumber(row.latency_ms)} ms</td>
                  <td>{row.upstream_latency_ms != null ? `${fmtNumber(row.upstream_latency_ms)} ms` : "—"}</td>
                  <td>
                    {row.guardrail_latency_ms != null ? (
                      <span title={row.guardrail_verdict ?? ""}>
                        {fmtNumber(row.guardrail_latency_ms)} ms
                        {row.guardrail_verdict && (
                          <span className={`${s.badge} ${s["badge--neutral"]}`} style={{ marginLeft: 4 }}>
                            {row.guardrail_verdict}
                          </span>
                        )}
                      </span>
                    ) : "—"}
                  </td>
                  <td>
                    {(row.detectors_fired?.length ?? 0) > 0 ? (
                      <span title={row.detectors_fired.join(", ")} style={{ display: "flex", gap: 3, flexWrap: "wrap" }}>
                        {row.detectors_fired.slice(0, 2).map((d) => (
                          <span key={d} className={`${s.badge} ${row.blocked === 1 ? s["badge--error"] : row.scrub_applied === 1 ? s["badge--warning"] : s["badge--neutral"]}`}
                            style={{ fontSize: 10 }}>{d}</span>
                        ))}
                        {row.detectors_fired.length > 2 && (
                          <span className={`${s.badge} ${s["badge--neutral"]}`} style={{ fontSize: 10 }}>+{row.detectors_fired.length - 2}</span>
                        )}
                      </span>
                    ) : "—"}
                  </td>
                  <td>
                    <span style={{ display: "flex", gap: 4, flexWrap: "wrap" }}>
                      {row.cached === 1 && <span className={`${s.badge} ${s["badge--neutral"]}`}>cached</span>}
                      {row.blocked === 1 && <span className={`${s.badge} ${s["badge--error"]}`}>blocked</span>}
                      {row.scrub_applied === 1 && <span className={`${s.badge} ${s["badge--warning"]}`}>scrubbed</span>}
                      {row.fallback_provider && <span className={`${s.badge} ${s["badge--warning"]}`}>fallback</span>}
                      {(row.upstream_attempts ?? 0) > 1 && (
                        <span className={`${s.badge} ${s["badge--warning"]}`}>{row.upstream_attempts} attempts</span>
                      )}
                    </span>
                  </td>
                  <td style={{ whiteSpace: "nowrap" }}>
                    {row.trace_id && (
                      <button
                        className={`${s.btn} ${s["btn--secondary"]}`}
                        style={{ fontSize: 11, padding: "2px 8px" }}
                        onClick={(e) => { e.stopPropagation(); setTraceId(traceId === row.trace_id ? null : row.trace_id!); }}
                      >
                        {traceId === row.trace_id ? "Close" : "Trace ›"}
                      </button>
                    )}
                  </td>
                </tr>
                {(row.prompt || row.response_raw) && expandedId === row.id && (
                  <tr>
                    <td colSpan={13} style={{ padding: "8px 12px", background: "var(--bg-subtle, #f6f8fa)" }}>
                      {row.prompt && (
                        <>
                          <div style={{ fontSize: 11, fontWeight: 600, marginBottom: 4, color: "var(--text-muted, #666)" }}>
                            Prompt{row.scrub_applied === 1 ? " (PII scrubbed)" : ""}
                          </div>
                          <pre style={{ margin: 0, marginBottom: row.response_raw ? 12 : 0, fontSize: 11, whiteSpace: "pre-wrap", wordBreak: "break-all" }}>
                            {row.prompt}
                          </pre>
                        </>
                      )}
                      {row.response_raw && (
                        <>
                          <div style={{ fontSize: 11, fontWeight: 600, marginBottom: 4, color: "var(--text-muted, #666)" }}>
                            LLM response{row.scrub_applied === 1 ? " (PII tokens visible if echoed)" : ""}
                          </div>
                          <pre style={{ margin: 0, fontSize: 11, whiteSpace: "pre-wrap", wordBreak: "break-all" }}>
                            {row.response_raw}
                          </pre>
                        </>
                      )}
                    </td>
                  </tr>
                )}
                </Fragment>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {traceId && (
        <TracePanel traceId={traceId} onClose={() => setTraceId(null)} />
      )}
    </main>
  );
}
