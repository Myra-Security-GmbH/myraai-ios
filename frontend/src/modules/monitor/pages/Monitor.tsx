import { useEffect, useRef, useState, useCallback } from "react";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { useCurrency } from "src/common/hooks/useCurrency";
import { CurrencySelector } from "src/common/components/CurrencySelector";
import { api } from "src/api/client";
import { UsageStats, LogEntry, Tenant } from "src/api/types";
import { fmtDateTime, fmtTime } from "src/common/utils/date";
import { fmtNumber } from "src/common/utils/format";
import { GuardrailEventsTable } from "src/common/components/GuardrailEventsTable";
import s from "src/common/components/layout/Layout.module.scss";
import ms from "./Monitor.module.scss";

function PeriodCard({ label, data, fc }: { label: string; data: any; fc: (n: number | null | undefined) => string }) {
  const rows: [string, string][] = [
    ["Requests",      fmtNumber(data?.requests)],
    ["Cached",        fmtNumber(data?.cached)],
    ["Blocked",       fmtNumber(data?.blocked)],
    ["Scrubbed",      fmtNumber(data?.scrubbed ?? 0)],
    ["Flagged",       fmtNumber(data?.flagged ?? 0)],
    ["Cost",          fc(data?.cost_usd)],
    ["Saved",         fc(data?.saved_cost_usd)],
    ["Avg latency",   data?.avg_latency_ms != null ? `${fmtNumber(data.avg_latency_ms)} ms` : "—"],
    ["Provider ms",   data?.avg_upstream_latency_ms ? `${fmtNumber(data.avg_upstream_latency_ms)} ms` : "—"],
    ["Input tokens",  fmtNumber(data?.input_tokens)],
    ["Output tokens", fmtNumber(data?.output_tokens)],
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
  const { currency, setCurrency, fc } = useCurrency();
  const [stats, setStats] = useState<UsageStats | null>(null);
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [tenantFilter, setTenantFilter] = useState("");
  const [interval, setIntervalMs] = useState(3000);
  const [running, setRunning] = useState(true);
  const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
  const [reqHistory, setReqHistory] = useState<number[]>([]);
  const [error, setError] = useState<string | null>(null);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    api.get<Tenant[]>("/tenants").then(setTenants).catch(() => {});
  }, []);

  const fetchStats = useCallback(() => {
    const params = tenantFilter ? `?tenant_id=${tenantFilter}` : "";
    api.get<UsageStats>(`/stats${params}`)
      .then((data) => {
        setStats(data);
        setLastUpdated(new Date());
        setError(null);
        setReqHistory((h) => [...h.slice(-59), data.last_min?.requests ?? 0]);
      })
      .catch((e) => setError(e.message));
  }, [tenantFilter]);

  useEffect(() => {
    setReqHistory([]);
    fetchStats();
  }, [tenantFilter]);

  useEffect(() => {
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
              Last updated: {fmtTime(lastUpdated)} · auto-refresh {running ? "on" : "paused"}
            </p>
          )}
        </div>
        <div className={ms["controls"]}>
          <CurrencySelector value={currency} onChange={setCurrency} />
          {tenants.length > 0 && (
            <>
              <label className={s["form-label"]} style={{ margin: 0 }}>Tenant</label>
              <select
                className={s["form-select"]}
                style={{ width: 160 }}
                value={tenantFilter}
                onChange={(e) => setTenantFilter(e.target.value)}
              >
                <option value="">All tenants</option>
                {tenants.map((t) => <option key={t.id} value={t.id}>{t.slug}</option>)}
              </select>
            </>
          )}
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
            <PeriodCard label="Last minute" data={stats.last_min} fc={fc} />
            <PeriodCard label="Last hour"   data={stats.hour}     fc={fc} />
            <PeriodCard label="Today"       data={stats.today}    fc={fc} />
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
                        <td>{fmtNumber(row.requests)}</td>
                        <td>{fmtNumber(row.input_tokens)}</td>
                        <td>{fmtNumber(row.output_tokens)}</td>
                        <td>{fc(row.cost_usd)}</td>
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
                        <td className={s.mono} style={{ fontSize: 11 }}>{fmtDateTime(row.ts)}</td>
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
                        <td>{fmtNumber(row.input_tokens)}</td>
                        <td>{fmtNumber(row.output_tokens)}</td>
                        <td>{fc(row.cost_usd)}</td>
                        <td>{row.saved_cost_usd ? fc(row.saved_cost_usd) : "—"}</td>
                        <td>{fmtNumber(row.latency_ms)} ms</td>
                        <td>{row.upstream_latency_ms != null ? `${fmtNumber(row.upstream_latency_ms)} ms` : "—"}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>

          {/* Recent guardrail events */}
          {(stats.recent_blocked?.length ?? 0) > 0 && (
            <div className={s.card}>
              <div className={s["card-header"]}>
                <h2 className={s["card-title"]}>Recent Guardrail Events</h2>
              </div>
              <GuardrailEventsTable rows={stats.recent_blocked} showGuardrailLatency />
            </div>
          )}
        </>
      )}

      {!stats && !error && <div className={s.empty}>Loading…</div>}
    </main>
  );
}
