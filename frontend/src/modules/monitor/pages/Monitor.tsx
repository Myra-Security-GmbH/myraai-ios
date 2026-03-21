import { useEffect, useRef, useState, useCallback } from "react";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { api } from "src/api/client";
import { UsageStats, LogEntry } from "src/api/types";
import s from "src/common/components/layout/Layout.module.scss";
import ms from "./Monitor.module.scss";

const LLAMA_GUARD_LABELS: Record<string, string> = {
  S1: "Violent Crimes", S2: "Non-Violent Crimes", S3: "Sex Crimes",
  S4: "Child Exploitation", S5: "Defamation", S6: "Specialized Advice",
  S7: "Privacy", S8: "IP Infringement", S9: "WMD/CBRN", S10: "Hate Speech",
  S11: "Self-Harm", S12: "Explicit Sexual", S13: "Elections", S14: "Code Abuse",
};

function decodeBlockReason(reason: string | null): string {
  if (!reason) return "—";
  if (/^S\d/.test(reason)) {
    return reason.split(/,\s*/).map((code) => {
      const key = code.trim();
      return LLAMA_GUARD_LABELS[key] ? `${key}: ${LLAMA_GUARD_LABELS[key]}` : key;
    }).join(", ");
  }
  return reason;
}

function fmt(n: number | null | undefined, dec = 0) {
  if (n == null) return "—";
  return n.toLocaleString("en-US", { maximumFractionDigits: dec });
}

function fmtCost(n: number | null | undefined) {
  if (n == null || n === 0) return "$0";
  return `$${n.toFixed(5)}`;
}

function PeriodCard({ label, data }: { label: string; data: any }) {
  const rows: [string, string][] = [
    ["Requests",      fmt(data?.requests)],
    ["Cached",        fmt(data?.cached)],
    ["Blocked",       fmt(data?.blocked)],
    ["Cost",          fmtCost(data?.cost_usd)],
    ["Saved",         fmtCost(data?.saved_cost_usd)],
    ["Avg latency",   data?.avg_latency_ms != null ? `${fmt(data.avg_latency_ms)} ms` : "—"],
    ["Provider ms",   data?.avg_upstream_latency_ms ? `${fmt(data.avg_upstream_latency_ms)} ms` : "—"],
    ["Input tokens",  fmt(data?.input_tokens)],
    ["Output tokens", fmt(data?.output_tokens)],
  ];
  return (
    <div className={s["period-card"]}>
      <div className={s["period-card-header"]}>{label}</div>
      <div className={s["period-card-rows"]}>
        {rows.map(([key, val]) => (
          <div key={key} className={s["period-card-row"]}>
            <span className={s["period-card-key"]}>{key}</span>
            <span className={s["period-card-val"]}>{val}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// Sparkline chart using canvas
function Sparkline({ values, color = "#3edcfe" }: { values: number[]; color?: string }) {
  const ref = useRef<HTMLCanvasElement>(null);
  useEffect(() => {
    const canvas = ref.current;
    if (!canvas || values.length < 2) return;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    const W = canvas.width, H = canvas.height;
    ctx.clearRect(0, 0, W, H);
    const max = Math.max(...values, 1);
    ctx.beginPath();
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    values.forEach((v, i) => {
      const x = (i / (values.length - 1)) * W;
      const y = H - (v / max) * (H - 4) - 2;
      i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
    });
    ctx.stroke();
  }, [values, color]);
  return <canvas ref={ref} width={120} height={32} style={{ display: "block" }} />;
}

export default function Monitor() {
  useDocumentTitle("Monitor");
  const [stats, setStats] = useState<UsageStats | null>(null);
  const [interval, setIntervalMs] = useState(3000);
  const [running, setRunning] = useState(true);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const [reqHistory, setReqHistory] = useState<number[]>([]);
  const [error, setError] = useState<string | null>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const fetchStats = useCallback(() => {
    api.get<UsageStats>("/stats")
      .then((data) => {
        setStats(data);
        setLastUpdated(new Date());
        setError(null);
        setReqHistory((h) => [...h.slice(-59), data.last_min?.requests ?? 0]);
      })
      .catch((e) => setError(e.message));
  }, []);

  useEffect(() => {
    fetchStats();
    if (!running) return;
    timerRef.current = setInterval(fetchStats, interval);
    return () => { if (timerRef.current) clearInterval(timerRef.current); };
  }, [running, interval, fetchStats]);

  const togglePause = () => setRunning((r) => !r);

  return (
    <main className={s.page}>
      {/* Header bar */}
      <div className={ms["monitor-header"]}>
        <div>
          <h1 className={s["page-title"]}>Live Monitor</h1>
          {lastUpdated && (
            <p className={s["page-subtitle"]}>
              Last updated: {lastUpdated.toLocaleTimeString()} · auto-refresh {running ? "on" : "paused"}
            </p>
          )}
        </div>
        <div className={ms["controls"]}>
          <label className={s["form-label"]} style={{ margin: 0 }}>Interval</label>
          <select
            className={s["form-select"]}
            style={{ width: 100 }}
            value={interval}
            onChange={(e) => setIntervalMs(Number(e.target.value))}
          >
            <option value={1000}>1 s</option>
            <option value={2000}>2 s</option>
            <option value={3000}>3 s</option>
            <option value={5000}>5 s</option>
            <option value={10000}>10 s</option>
            <option value={30000}>30 s</option>
          </select>
          <button
            className={`${s.btn} ${running ? s["btn--secondary"] : s["btn--primary"]}`}
            onClick={togglePause}
          >
            {running ? "⏸ Pause" : "▶ Resume"}
          </button>
          <button className={`${s.btn} ${s["btn--secondary"]}`} onClick={fetchStats}>
            ↻ Refresh
          </button>
        </div>
      </div>

      {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}

      {stats && (
        <>
          {/* Sparkline activity chart */}
          {reqHistory.length > 1 && (
            <div className={ms["sparkline-card"]}>
              <span className={ms["sparkline-label"]}>Requests/min (last {reqHistory.length} samples)</span>
              <Sparkline values={reqHistory} />
              <span className={ms["sparkline-current"]}>{reqHistory[reqHistory.length - 1]} now</span>
            </div>
          )}

          {/* Period summaries */}
          <div className={s["periods-grid"]}>
            <PeriodCard label="Last minute" data={stats.last_min} />
            <PeriodCard label="Last hour"   data={stats.hour} />
            <PeriodCard label="Today"       data={stats.today} />
          </div>

          {/* Per-tenant today */}
          {(stats.by_tenant?.length ?? 0) > 0 && (
            <div className={s.card}>
              <div className={s["card-header"]}>
                <h2 className={s["card-title"]}>Tenants — Today</h2>
              </div>
              <div className={s["table-wrapper"]}>
                <table className={s.table}>
                  <thead>
                    <tr>
                      <th>Tenant</th>
                      <th>Requests</th>
                      <th>In Tokens</th>
                      <th>Out Tokens</th>
                      <th>Cost</th>
                      <th>Quota Left</th>
                    </tr>
                  </thead>
                  <tbody>
                    {stats.by_tenant.map((row) => (
                      <tr key={row.tenant_id}>
                        <td><span className={s.code}>{row.tenant}</span></td>
                        <td>{fmt(row.requests)}</td>
                        <td>{fmt(row.input_tokens)}</td>
                        <td>{fmt(row.output_tokens)}</td>
                        <td>{fmtCost(row.cost_usd)}</td>
                        <td>
                          <span style={{ color: "var(--text-secondary)", fontSize: 12 }}>no limit</span>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}

          {/* Last 10 requests */}
          <div className={s.card}>
            <div className={s["card-header"]}>
              <h2 className={s["card-title"]}>Last 10 Requests</h2>
            </div>
            {(stats.recent?.length ?? 0) === 0 ? (
              <div className={s.empty}>No requests yet.</div>
            ) : (
              <div className={s["table-wrapper"]}>
                <table className={s.table}>
                  <thead>
                    <tr>
                      <th>Time</th>
                      <th>Tenant</th>
                      <th>Provider</th>
                      <th>Model</th>
                      <th>Status</th>
                      <th>In</th>
                      <th>Out</th>
                      <th>Cost</th>
                      <th>Saved</th>
                      <th>Latency</th>
                      <th>Prov ms</th>
                    </tr>
                  </thead>
                  <tbody>
                    {stats.recent.map((row: any, i: number) => (
                      <tr key={i} className={row.blocked ? s.blocked : ""}>
                        <td className={s.mono} style={{ fontSize: 11 }}>{row.ts}</td>
                        <td><span className={s.code}>{row.tenant ?? row.tenant_id?.slice(0, 8)}</span></td>
                        <td>{row.provider}</td>
                        <td className={s.mono} style={{ fontSize: 11, maxWidth: 160, overflow: "hidden", textOverflow: "ellipsis" }}>{row.model}</td>
                        <td>
                          {row.blocked ? (
                            <span className={`${s.badge} ${s["badge--error"]}`}>[{row.blocked_by ?? "blocked"}]</span>
                          ) : row.cached ? (
                            <span className={`${s.badge} ${s["badge--neutral"]}`}>[cached]</span>
                          ) : (
                            <span className={`${s.badge} ${row.status >= 200 && row.status < 300 ? s["badge--success"] : s["badge--error"]}`}>
                              {row.status}
                            </span>
                          )}
                        </td>
                        <td>{fmt(row.input_tokens)}</td>
                        <td>{fmt(row.output_tokens)}</td>
                        <td>{fmtCost(row.cost_usd)}</td>
                        <td>{row.saved_cost_usd ? fmtCost(row.saved_cost_usd) : "—"}</td>
                        <td>{fmt(row.latency_ms)} ms</td>
                        <td>{row.upstream_latency_ms != null ? `${fmt(row.upstream_latency_ms)} ms` : "—"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>

          {/* Last 10 blocked */}
          {(stats.recent_blocked?.length ?? 0) > 0 && (
            <div className={s.card}>
              <div className={s["card-header"]}>
                <h2 className={s["card-title"]}>Last 10 Blocked Requests</h2>
              </div>
              <div className={s["table-wrapper"]}>
                <table className={s.table}>
                  <thead>
                    <tr>
                      <th>Time</th>
                      <th>Tenant</th>
                      <th>Blocked By</th>
                      <th>Reason</th>
                      <th>Latency</th>
                      <th>Guardrail</th>
                    </tr>
                  </thead>
                  <tbody>
                    {stats.recent_blocked.map((row: any, i: number) => (
                      <tr key={i} className={s.blocked}>
                        <td className={s.mono} style={{ fontSize: 11 }}>{row.ts}</td>
                        <td><span className={s.code}>{row.tenant ?? row.tenant_id?.slice(0, 8)}</span></td>
                        <td><span className={`${s.badge} ${s["badge--error"]}`}>{row.blocked_by ?? "?"}</span></td>
                        <td style={{ maxWidth: 280, fontSize: 12 }}>{decodeBlockReason(row.block_reason)}</td>
                        <td>{fmt(row.latency_ms)} ms</td>
                        <td>{(row as any).guardrail_latency_ms != null ? `${fmt((row as any).guardrail_latency_ms)} ms` : "—"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </>
      )}

      {!stats && !error && <div className={s.empty}>Loading…</div>}
    </main>
  );
}
