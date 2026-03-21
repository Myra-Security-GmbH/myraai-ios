import { useEffect, useState } from "react";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { api } from "src/api/client";
import { UsageStats } from "src/api/types";
import s from "src/common/components/layout/Layout.module.scss";

function fmt(n: number | undefined | null, decimals = 0) {
  if (n == null) return "—";
  return n.toLocaleString("en-US", { maximumFractionDigits: decimals });
}

function fmtCost(n: number | undefined | null) {
  if (n == null) return "—";
  return `$${n.toFixed(4)}`;
}

function StatusBadge({ value, variant }: { value: string | number; variant: "success" | "error" | "warning" | "neutral" }) {
  return <span className={`${s.badge} ${s[`badge--${variant}`]}`}>{value}</span>;
}

export default function Dashboard() {
  useDocumentTitle("Dashboard");
  const [stats, setStats] = useState<UsageStats | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api.get<UsageStats>("/stats")
      .then(setStats)
      .catch((e) => setError(e.message))
      .finally(() => setLoading(false));
  }, []);

  if (loading) return <div className={s.page}><p className={s.empty}>Loading…</p></div>;
  if (error) return <div className={s.page}><div className={`${s.alert} ${s["alert--error"]}`}>{error}</div></div>;
  if (!stats) return null;

  const periods = [
    { label: "Last minute", data: stats.last_min },
    { label: "Last hour",   data: stats.hour },
    { label: "Today",       data: stats.today },
  ];

  return (
    <main className={s.page}>
      <div className={s["page-header"]}>
        <div>
          <h1 className={s["page-title"]}>Dashboard</h1>
          <p className={s["page-subtitle"]}>Real-time AI Gateway metrics</p>
        </div>
      </div>

      {/* Period stats */}
      {periods.map(({ label, data }) => (
        <div key={label} className={s.card}>
          <div className={s["card-header"]}>
            <h2 className={s["card-title"]}>{label}</h2>
          </div>
          <div className={s["stats-grid"]}>
            <div className={s["stat-card"]}>
              <div className={s["stat-label"]}>Requests</div>
              <div className={s["stat-value"]}>{fmt(data?.requests)}</div>
            </div>
            <div className={s["stat-card"]}>
              <div className={s["stat-label"]}>Cached</div>
              <div className={s["stat-value"]}>{fmt(data?.cached)}</div>
            </div>
            <div className={s["stat-card"]}>
              <div className={s["stat-label"]}>Blocked</div>
              <div className={s["stat-value"]}>{fmt(data?.blocked)}</div>
            </div>
            <div className={s["stat-card"]}>
              <div className={s["stat-label"]}>Cost</div>
              <div className={s["stat-value"]}>{fmtCost(data?.cost_usd)}</div>
            </div>
            <div className={s["stat-card"]}>
              <div className={s["stat-label"]}>Avg Latency</div>
              <div className={s["stat-value"]}>{fmt(data?.avg_latency_ms)}<span style={{ fontSize: 14, fontWeight: 400 }}> ms</span></div>
            </div>
            <div className={s["stat-card"]}>
              <div className={s["stat-label"]}>Input Tokens</div>
              <div className={s["stat-value"]}>{fmt(data?.input_tokens)}</div>
            </div>
            <div className={s["stat-card"]}>
              <div className={s["stat-label"]}>Output Tokens</div>
              <div className={s["stat-value"]}>{fmt(data?.output_tokens)}</div>
            </div>
          </div>
        </div>
      ))}

      {/* By tenant */}
      {(stats.by_tenant?.length ?? 0) > 0 && (
        <div className={s.card}>
          <div className={s["card-header"]}>
            <h2 className={s["card-title"]}>Usage by Tenant (Today)</h2>
          </div>
          <div className={s["table-wrapper"]}>
            <table className={s.table}>
              <thead>
                <tr>
                  <th>Tenant</th>
                  <th>Requests</th>
                  <th>Input Tokens</th>
                  <th>Output Tokens</th>
                  <th>Cost</th>
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
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Recent requests */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Recent Requests</h2>
        </div>
        {(stats.recent?.length ?? 0) === 0 ? (
          <div className={s.empty}><div className={s["empty-icon"]}>📋</div>No requests yet</div>
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
                  <th>Tokens</th>
                  <th>Cost</th>
                  <th>Latency</th>
                  <th>Flags</th>
                </tr>
              </thead>
              <tbody>
                {stats.recent.map((row, i) => (
                  <tr key={i} className={row.blocked ? s.blocked : ""}>
                    <td className={s.mono}>{row.ts}</td>
                    <td><span className={s.code}>{row.tenant}</span></td>
                    <td>{row.provider}</td>
                    <td className={s.mono} style={{ fontSize: 11 }}>{row.model}</td>
                    <td>
                      <StatusBadge
                        value={row.status}
                        variant={row.status >= 200 && row.status < 300 ? "success" : "error"}
                      />
                    </td>
                    <td>{fmt(row.input_tokens)}+{fmt(row.output_tokens)}</td>
                    <td>{fmtCost(row.cost_usd)}</td>
                    <td>{fmt(row.latency_ms)} ms</td>
                    <td style={{ display: "flex", gap: 4, flexWrap: "wrap" }}>
                      {row.cached === 1 && <StatusBadge value="cached" variant="neutral" />}
                      {row.blocked === 1 && <StatusBadge value="blocked" variant="error" />}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Recent blocked */}
      {(stats.recent_blocked?.length ?? 0) > 0 && (
        <div className={s.card}>
          <div className={s["card-header"]}>
            <h2 className={s["card-title"]}>Recently Blocked</h2>
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
                </tr>
              </thead>
              <tbody>
                {stats.recent_blocked.map((row, i) => (
                  <tr key={i} className={s.blocked}>
                    <td className={s.mono}>{row.ts}</td>
                    <td><span className={s.code}>{row.tenant}</span></td>
                    <td>{row.blocked_by ?? "—"}</td>
                    <td>{row.block_reason ?? "—"}</td>
                    <td>{fmt(row.latency_ms)} ms</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </main>
  );
}
