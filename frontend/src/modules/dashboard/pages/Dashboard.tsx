import { useEffect, useState } from "react";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { api } from "src/api/client";
import { UsageStats, PeriodStats, TimeseriesPoint } from "src/api/types";
import { fmtDateTime } from "src/common/utils/date";
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

type Timeframe = "today" | "yesterday" | "last_7d" | "hour" | "last_min";

const TIMEFRAMES: { key: Timeframe; label: string }[] = [
  { key: "today",     label: "Today" },
  { key: "yesterday", label: "Yesterday" },
  { key: "last_7d",   label: "Last 7 days" },
  { key: "hour",      label: "Last hour" },
  { key: "last_min",  label: "Last minute" },
];

const TIMEFRAME_SERIES: Record<Timeframe, keyof SeriesData> = {
  today:     "hourly",
  yesterday: "yesterday",
  last_7d:   "last7d",
  hour:      "recent",
  last_min:  "recent",
};

interface SeriesData {
  hourly:    TimeseriesPoint[];  // 1h × today's hours
  yesterday: TimeseriesPoint[];  // 1h × 24, ending at midnight today
  last7d:    TimeseriesPoint[];  // 1d × 7
  recent:    TimeseriesPoint[];  // 5m × 12
}

// Pure SVG sparkline — no dependencies
function Sparkline({ values, height = 44 }: { values: number[]; height?: number }) {
  if (values.length < 2) return <div style={{ height }} />;

  const max = Math.max(...values);
  if (max === 0) return <div style={{ height }} />;

  const W = 300;
  const H = height;
  const step = W / (values.length - 1);
  const pts = values.map((v, i) => `${i * step},${H - (v / max) * H * 0.92}`);
  const areaPath =
    `M0,${H} ` +
    pts.map((p) => `L${p}`).join(" ") +
    ` L${(values.length - 1) * step},${H} Z`;

  return (
    <svg
      className={s["hero-sparkline"]}
      width="100%"
      height={height}
      viewBox={`0 0 ${W} ${H}`}
      preserveAspectRatio="none"
    >
      <defs>
        <linearGradient id="sg" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="currentColor" stopOpacity="0.25" />
          <stop offset="100%" stopColor="currentColor" stopOpacity="0" />
        </linearGradient>
      </defs>
      <path d={areaPath} fill="url(#sg)" />
      <polyline
        points={pts.join(" ")}
        fill="none"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinejoin="round"
        strokeLinecap="round"
      />
    </svg>
  );
}

function HeroCards({ data, series }: { data: PeriodStats; series: TimeseriesPoint[] | null }) {
  const blockRate = data.requests > 0
    ? ((data.blocked / data.requests) * 100).toFixed(1)
    : null;
  const cacheRate = data.requests > 0
    ? ((data.cached / data.requests) * 100).toFixed(1)
    : null;

  const requestsSeries = series?.map(p => p.requests) ?? null;
  const costSeries     = series?.map(p => p.cost_usd) ?? null;
  const blockedSeries  = series?.map(p => p.blocked)  ?? null;

  return (
    <div className={s["hero-grid"]}>
      <div className={s["hero-card"]}>
        <div className={s["hero-label"]}>Requests</div>
        <div className={s["hero-value"]}>{fmt(data.requests)}</div>
        <div className={s["hero-sub"]}>
          {cacheRate != null
            ? <><span className={s["hero-sub-highlight"]}>{cacheRate}%</span> cache hit rate</>
            : "No requests yet"}
        </div>
        {requestsSeries && <Sparkline values={requestsSeries} />}
      </div>

      <div className={s["hero-card"]}>
        <div className={s["hero-label"]}>Cost</div>
        <div className={s["hero-value"]}>{fmtCost(data.cost_usd)}</div>
        <div className={s["hero-sub"]}>
          {data.saved_cost_usd > 0
            ? <><span className={s["hero-sub-highlight"]}>{fmtCost(data.saved_cost_usd)}</span> saved via cache</>
            : "No cache savings yet"}
        </div>
        {costSeries && <Sparkline values={costSeries} />}
      </div>

      <div className={s["hero-card"]}>
        <div className={s["hero-label"]}>Blocked</div>
        <div className={s["hero-value"]}>{fmt(data.blocked)}</div>
        <div className={s["hero-sub"]}>
          {blockRate != null && data.blocked > 0
            ? <><span className={s["hero-sub-highlight"]}>{blockRate}%</span> of requests blocked</>
            : "No blocked requests"}
        </div>
        {blockedSeries && <Sparkline values={blockedSeries} />}
      </div>
    </div>
  );
}

export default function Dashboard() {
  useDocumentTitle("Dashboard");
  const [stats, setStats] = useState<UsageStats | null>(null);
  const [series, setSeries] = useState<SeriesData | null>(null);
  const [loading, setLoading] = useState(true);
  const [timeframe, setTimeframe] = useState<Timeframe>("today");

  useEffect(() => {
    const hoursToday = Math.max(2, new Date().getUTCHours() + 1);
    // yesterday ends at midnight UTC today (as unix seconds)
    const midnightToday = Math.floor(Date.now() / 86400000) * 86400;
    Promise.allSettled([
      api.get<UsageStats>("/stats"),
      api.get<TimeseriesPoint[]>(`/stats/timeseries?bucket=1h&n=${hoursToday}`),
      api.get<TimeseriesPoint[]>(`/stats/timeseries?bucket=1h&n=24&until=${midnightToday - 1}`),
      api.get<TimeseriesPoint[]>("/stats/timeseries?bucket=1d&n=7"),
      api.get<TimeseriesPoint[]>("/stats/timeseries?bucket=5m&n=12"),
    ])
      .then(([statsResult, hourlyResult, yesterdayResult, last7dResult, recentResult]) => {
        if (statsResult.status === "fulfilled") setStats(statsResult.value);
        setSeries({
          hourly:    hourlyResult.status    === "fulfilled" ? hourlyResult.value    : [],
          yesterday: yesterdayResult.status === "fulfilled" ? yesterdayResult.value : [],
          last7d:    last7dResult.status    === "fulfilled" ? last7dResult.value    : [],
          recent:    recentResult.status    === "fulfilled" ? recentResult.value    : [],
        });
      })
      .finally(() => setLoading(false));
  }, []);

  if (loading) return <div className={s.page}><p className={s.empty}>Loading…</p></div>;

  const emptyPeriod: PeriodStats = { requests: 0, cached: 0, blocked: 0, input_tokens: 0, output_tokens: 0, cost_usd: 0, saved_cost_usd: 0, avg_latency_ms: 0, avg_upstream_latency_ms: 0 };
  const periodData: Record<Timeframe, PeriodStats> = {
    today:     stats?.today     ?? emptyPeriod,
    yesterday: stats?.yesterday ?? emptyPeriod,
    last_7d:   stats?.last_7d   ?? emptyPeriod,
    hour:      stats?.hour      ?? emptyPeriod,
    last_min:  stats?.last_min  ?? emptyPeriod,
  };

  const periods = [
    { label: "Last minute", data: stats?.last_min  ?? emptyPeriod },
    { label: "Last hour",   data: stats?.hour      ?? emptyPeriod },
    { label: "Today",       data: stats?.today     ?? emptyPeriod },
    { label: "Yesterday",   data: stats?.yesterday ?? emptyPeriod },
    { label: "Last 7 days", data: stats?.last_7d   ?? emptyPeriod },
  ];

  return (
    <main className={s.page}>
      <div className={s["page-header"]}>
        <div>
          <h1 className={s["page-title"]}>Dashboard</h1>
          <p className={s["page-subtitle"]}>Real-time AI Gateway metrics</p>
        </div>
      </div>

      {/* Hero cards */}
      <div className={s["hero-section"]}>
        <div className={s["hero-header"]}>
          <div className={s["timeframe-tabs"]}>
            {TIMEFRAMES.map(({ key, label }) => (
              <button
                key={key}
                className={`${s["timeframe-tab"]} ${timeframe === key ? s["timeframe-tab--active"] : ""}`}
                onClick={() => setTimeframe(key)}
              >
                {label}
              </button>
            ))}
          </div>
        </div>
        <HeroCards
          data={periodData[timeframe]}
          series={series ? series[TIMEFRAME_SERIES[timeframe]] : null}
        />
      </div>

      {/* Period stats */}
      <div className={s["periods-grid"]} style={{ display: "none" }}>
        {periods.map(({ label, data }) => {
          const rows: [string, string][] = [
            ["Requests",      fmt(data?.requests)],
            ["Cached",        fmt(data?.cached)],
            ["Blocked",       fmt(data?.blocked)],
            ["Cost",          fmtCost(data?.cost_usd)],
            ["Saved",         data?.saved_cost_usd ? fmtCost(data.saved_cost_usd) : "—"],
            ["Avg latency",   data?.avg_latency_ms != null ? `${fmt(data.avg_latency_ms)} ms` : "—"],
            ["Provider ms",   data?.avg_upstream_latency_ms ? `${fmt(data.avg_upstream_latency_ms)} ms` : "—"],
            ["Input tokens",  fmt(data?.input_tokens)],
            ["Output tokens", fmt(data?.output_tokens)],
          ];
          return (
            <div key={label} className={s["period-card"]}>
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
        })}
      </div>

      {/* By tenant */}
      {(stats?.by_tenant?.length ?? 0) > 0 && (
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
                {stats?.by_tenant.map((row) => (
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
        {(stats?.recent?.length ?? 0) === 0 ? (
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
                {stats?.recent.map((row, i) => (
                  <tr key={i} className={row.blocked ? s.blocked : ""}>
                    <td className={s.mono}>{fmtDateTime(row.ts)}</td>
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
      {(stats?.recent_blocked?.length ?? 0) > 0 && (
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
                {stats?.recent_blocked.map((row, i) => (
                  <tr key={i} className={s.blocked}>
                    <td className={s.mono}>{fmtDateTime(row.ts)}</td>
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
