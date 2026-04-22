import { useEffect, useState } from "react";
import { useSearchParams } from "react-router-dom";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { api } from "src/api/client";
import { UsageStats, PeriodStats, TimeseriesPoint, AnalyticsDepth, CacheEfficiency } from "src/api/types";
import { fmtDateTime } from "src/common/utils/date";
import { fmtNumber, fmtCost } from "src/common/utils/format";
import { GuardrailEventsTable } from "src/common/components/GuardrailEventsTable";
import { StatusBadge } from "src/common/components/StatusBadge";
import s from "src/common/components/layout/Layout.module.scss";


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

function timeframeSince(tf: Timeframe): number {
  const now = Date.now();
  const todayMs = Math.floor(now / 86400000) * 86400000;
  switch (tf) {
    case "today":     return todayMs;
    case "yesterday": return todayMs - 86400000;
    case "last_7d":   return todayMs - 7 * 86400000;
    case "hour":      return now - 3600000;
    case "last_min":  return now - 60000;
  }
}

// Returns an exclusive upper bound for closed-window timeframes (null = open-ended / "until now").
// Only "yesterday" has a hard upper bound: midnight today.
function timeframeUntil(tf: Timeframe): number | null {
  if (tf === "yesterday") return Math.floor(Date.now() / 86400000) * 86400000;
  return null;
}

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
        <div className={s["hero-value"]}>{fmtNumber(data.requests)}</div>
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
        <div className={s["hero-label"]}>Guardrail Hits</div>
        <div className={s["hero-value"]}>{fmtNumber((data.blocked ?? 0) + (data.scrubbed ?? 0) + (data.flagged ?? 0))}</div>
        <div className={s["hero-sub"]}>
          {(data.blocked ?? 0) > 0 || (data.scrubbed ?? 0) > 0 || (data.flagged ?? 0) > 0 ? (
            <>{fmtNumber(data.blocked ?? 0)} blocked · {fmtNumber(data.scrubbed ?? 0)} scrubbed · {fmtNumber(data.flagged ?? 0)} flagged</>
          ) : "No guardrail hits"}
        </div>
        {blockedSeries && <Sparkline values={blockedSeries} />}
      </div>

    </div>
  );
}

function fmtTokens(n: number): string {
  if (n >= 1_000_000_000) return (n / 1_000_000_000).toFixed(1) + "B";
  if (n >= 1_000_000)     return (n / 1_000_000).toFixed(1) + "M";
  if (n >= 1_000)         return (n / 1_000).toFixed(1) + "k";
  return String(n);
}

function CacheEfficiencyCard({ data }: { data: CacheEfficiency }) {
  const totalInput = data.cache_write_tokens + data.cache_read_tokens + data.uncached_input_tokens;
  const hitPct     = data.cache_hit_pct ?? 0;
  const hitColor   = hitPct >= 60 ? "#10b981" : hitPct >= 30 ? "#f59e0b" : "#ef4444";
  const totalCachedCost   = data.cached_cost_usd ?? 0;
  const totalUncachedCost = data.uncached_cost_usd ?? 0;
  const totalCost         = totalCachedCost + totalUncachedCost;

  // What uncached cost would have been without cache writes (all at standard rate)
  // Use the ratio of actual uncached cost as a proxy for the per-token rate
  const uncachedRate = data.uncached_input_tokens > 0
    ? totalUncachedCost / data.uncached_input_tokens
    : 0;
  const wouldHaveCost = uncachedRate > 0
    ? totalInput * uncachedRate
    : null;
  const savedByCache = wouldHaveCost != null ? wouldHaveCost - totalCost : null;

  if (totalInput === 0) return null;

  return (
    <div className={s["hero-card"]} style={{ gridColumn: "1 / -1" }}>
      <div style={{ display: "flex", alignItems: "baseline", justifyContent: "space-between", marginBottom: 4 }}>
        <div className={s["hero-label"]}>Anthropic Input Token Caching Efficiency</div>
        <div style={{ fontSize: 11, color: "var(--text-secondary)" }}>
          {fmtTokens(totalInput)} total input tokens
        </div>
      </div>

      {/* Hit rate bar */}
      <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 10 }}>
        <div style={{ flex: 1, height: 8, background: "var(--table-row-hover)", borderRadius: 4, overflow: "hidden" }}>
          <div style={{ width: `${hitPct}%`, height: "100%", background: hitColor, borderRadius: 4, transition: "width 0.4s" }} />
        </div>
        <div style={{ fontSize: 20, fontWeight: 700, color: hitColor, minWidth: 64, textAlign: "right" }}>
          {hitPct.toFixed(1)}%
        </div>
        <div style={{ fontSize: 12, color: "var(--text-secondary)", minWidth: 80 }}>cache hit rate</div>
      </div>

      {/* Token breakdown */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(3, 1fr)", gap: 12, marginBottom: 10 }}>
        <div style={{ background: "var(--table-row-hover)", borderRadius: 8, padding: "10px 14px" }}>
          <div style={{ fontSize: 11, color: "var(--text-secondary)", marginBottom: 3 }}>Cache reads</div>
          <div style={{ fontSize: 18, fontWeight: 700, color: "#10b981" }}>{fmtTokens(data.cache_read_tokens)}</div>
          <div style={{ fontSize: 11, color: "var(--text-secondary)", marginTop: 2 }}>
            {totalInput > 0 ? ((data.cache_read_tokens / totalInput) * 100).toFixed(1) : 0}% of total · {fmtCost(totalCachedCost * (data.cache_read_tokens / Math.max(data.cache_read_tokens + data.cache_write_tokens, 1)))}
          </div>
        </div>
        <div style={{ background: "var(--table-row-hover)", borderRadius: 8, padding: "10px 14px" }}>
          <div style={{ fontSize: 11, color: "var(--text-secondary)", marginBottom: 3 }}>Cache writes</div>
          <div style={{ fontSize: 18, fontWeight: 700, color: "#f59e0b" }}>{fmtTokens(data.cache_write_tokens)}</div>
          <div style={{ fontSize: 11, color: "var(--text-secondary)", marginTop: 2 }}>
            {totalInput > 0 ? ((data.cache_write_tokens / totalInput) * 100).toFixed(1) : 0}% of total · {fmtCost(totalCachedCost * (data.cache_write_tokens / Math.max(data.cache_read_tokens + data.cache_write_tokens, 1)))}
          </div>
        </div>
        <div style={{ background: "var(--table-row-hover)", borderRadius: 8, padding: "10px 14px" }}>
          <div style={{ fontSize: 11, color: "var(--text-secondary)", marginBottom: 3 }}>Uncached input</div>
          <div style={{ fontSize: 18, fontWeight: 700, color: "#ef4444" }}>{fmtTokens(data.uncached_input_tokens)}</div>
          <div style={{ fontSize: 11, color: "var(--text-secondary)", marginTop: 2 }}>
            {totalInput > 0 ? ((data.uncached_input_tokens / totalInput) * 100).toFixed(1) : 0}% of total · {fmtCost(totalUncachedCost)}
          </div>
        </div>
      </div>

      {/* Cost summary */}
      <div style={{ display: "flex", gap: 20, fontSize: 12, color: "var(--text-secondary)", borderTop: "1px solid var(--card-border)", paddingTop: 8 }}>
        <span>Cached input cost: <strong style={{ color: "var(--text-primary)" }}>{fmtCost(totalCachedCost)}</strong></span>
        <span>Uncached input cost: <strong style={{ color: "var(--text-primary)" }}>{fmtCost(totalUncachedCost)}</strong></span>
        {savedByCache != null && savedByCache > 0 && (
          <span style={{ marginLeft: "auto" }}>
            Saved vs all-uncached: <strong style={{ color: "#10b981" }}>{fmtCost(savedByCache)}</strong>
          </span>
        )}
      </div>
    </div>
  );
}

export default function Dashboard() {
  useDocumentTitle("Dashboard");
  const [stats, setStats] = useState<UsageStats | null>(null);
  const [series, setSeries] = useState<SeriesData | null>(null);
  const [analytics, setAnalytics] = useState<AnalyticsDepth | null>(null);
  const [loading, setLoading] = useState(true);
  const [searchParams, setSearchParams] = useSearchParams();
  const rawTf = searchParams.get("timeframe") ?? "";
  const timeframe: Timeframe = (["today","yesterday","last_7d","hour","last_min"] as const).includes(rawTf as Timeframe)
    ? rawTf as Timeframe
    : "today";

  useEffect(() => {
    const hoursToday = Math.max(2, new Date().getUTCHours() + 1);
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

  useEffect(() => {
    setAnalytics(null);
    const since = timeframeSince(timeframe);
    const until = timeframeUntil(timeframe);
    const url = until
      ? `/stats/analytics?since=${since}&until=${until}`
      : `/stats/analytics?since=${since}`;
    api.get<AnalyticsDepth>(url)
      .then(setAnalytics)
      .catch(() => {});
  }, [timeframe]);

  if (loading) return <div className={s.page}><p className={s.empty}>Loading…</p></div>;

  const emptyPeriod: PeriodStats = { requests: 0, cached: 0, blocked: 0, scrubbed: 0, flagged: 0, input_tokens: 0, output_tokens: 0, cost_usd: 0, saved_cost_usd: 0, avg_latency_ms: 0, avg_upstream_latency_ms: 0 };
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
                onClick={() => setSearchParams({ timeframe: key }, { replace: true })}
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
        {analytics?.cache_efficiency && analytics.cache_efficiency.cache_write_tokens + analytics.cache_efficiency.cache_read_tokens > 0 && (
          <div className={s["hero-grid"]} style={{ marginTop: 12 }}>
            <CacheEfficiencyCard data={analytics.cache_efficiency} />
          </div>
        )}
      </div>

      {/* Period stats */}
      <div className={s["periods-grid"]} style={{ display: "none" }}>
        {periods.map(({ label, data }) => {
          const rows: [string, string][] = [
            ["Requests",      fmtNumber(data?.requests)],
            ["Cached",        fmtNumber(data?.cached)],
            ["Blocked",       fmtNumber(data?.blocked)],
            ["Cost",          fmtCost(data?.cost_usd)],
            ["Saved",         data?.saved_cost_usd ? fmtCost(data.saved_cost_usd) : "—"],
            ["Avg latency",   data?.avg_latency_ms != null ? `${fmtNumber(data.avg_latency_ms)} ms` : "—"],
            ["Provider ms",   data?.avg_upstream_latency_ms ? `${fmtNumber(data.avg_upstream_latency_ms)} ms` : "—"],
            ["Input tokens",  fmtNumber(data?.input_tokens)],
            ["Output tokens", fmtNumber(data?.output_tokens)],
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
      {(analytics?.by_tenant?.length ?? 0) > 0 && (
        <div className={s.card}>
          <div className={s["card-header"]}>
            <h2 className={s["card-title"]}>Usage by Tenant — {TIMEFRAMES.find(t => t.key === timeframe)?.label}</h2>
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
                {analytics!.by_tenant.map((row) => (
                  <tr key={row.tenant_id}>
                    <td><span className={s.code}>{row.tenant}</span></td>
                    <td>{fmtNumber(row.requests)}</td>
                    <td>{fmtNumber(row.input_tokens)}</td>
                    <td>{fmtNumber(row.output_tokens)}</td>
                    <td>{fmtCost(row.cost_usd)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Top models */}
      {analytics && (
        <>
          {analytics.top_models.length > 0 && (
            <div className={s.card}>
              <div className={s["card-header"]}>
                <h2 className={s["card-title"]}>Top Models — {TIMEFRAMES.find(t => t.key === timeframe)?.label}</h2>
              </div>
              <div className={s["table-wrapper"]}>
                <table className={s.table}>
                  <thead>
                    <tr>
                      <th>Provider</th>
                      <th>Model</th>
                      <th>Requests</th>
                      <th>Cost</th>
                      <th>Avg Latency</th>
                    </tr>
                  </thead>
                  <tbody>
                    {analytics.top_models.slice(0, 5).map((row, i) => (
                      <tr key={i}>
                        <td>{row.provider}</td>
                        <td className={`${s.mono} ${s.truncate}`} style={{ fontSize: 11, maxWidth: 160 }}>{row.model}</td>
                        <td>{fmtNumber(row.requests)}</td>
                        <td>{row.cost_usd > 0 ? `$${row.cost_usd.toFixed(4)}` : "—"}</td>
                        <td>{fmtNumber(row.avg_latency_ms)} ms</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </div>
          )}
        </>
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
                  <th>Gateway</th>
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
                    <td><span className={s.code}>{row.gateway ?? row.gateway_id}</span></td>
                    <td>{row.provider}</td>
                    <td className={s.mono} style={{ fontSize: 11 }}>{row.model}</td>
                    <td>
                      <StatusBadge
                        value={row.status}
                        variant={row.status >= 200 && row.status < 300 ? "success" : "error"}
                      />
                    </td>
                    <td>{fmtNumber(row.input_tokens)}+{fmtNumber(row.output_tokens)}</td>
                    <td>{fmtCost(row.cost_usd)}</td>
                    <td>{fmtNumber(row.latency_ms)} ms</td>
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

      {/* Recent guardrail events */}
      {(stats?.recent_blocked?.length ?? 0) > 0 && (
        <div className={s.card}>
          <div className={s["card-header"]}>
            <h2 className={s["card-title"]}>Recent Guardrail Events</h2>
          </div>
          <GuardrailEventsTable rows={stats!.recent_blocked} />
        </div>
      )}
    </main>
  );
}
