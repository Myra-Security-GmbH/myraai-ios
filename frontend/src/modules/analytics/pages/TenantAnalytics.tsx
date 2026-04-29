import { useEffect, useState, useRef } from "react";
import { useSearchParams } from "react-router-dom";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { useCurrency } from "src/common/hooks/useCurrency";
import { CurrencySelector } from "src/common/components/CurrencySelector";
import { api } from "src/api/client";
import {
  AnalyticsDepth, Tenant, TenantStats, GatewayStats, UserStats,
  TenantAnalyticsDetail, SpendRecord, TopModelRow, TimeseriesPoint,
  LatencyPercentiles, AnthropicUsage, AnthropicUsageRow,
} from "src/api/types";
import { fmtNumber, fmtCost, fmtMs } from "src/common/utils/format";
import { useChartHover, ChartTooltip } from "../components/ChartHover";
import s from "src/common/components/layout/Layout.module.scss";
import ta from "./TenantAnalytics.module.scss";

function fmtRate(numerator: number, denominator: number): string {
  if (denominator === 0) return "—";
  const pct = (numerator / denominator) * 100;
  if (pct === 0) return "0%";
  return pct < 0.1 ? "<0.1%" : `${pct.toFixed(1)}%`;
}

function dateLabel(ts: number, opts?: Intl.DateTimeFormatOptions): string {
  return new Date(ts).toLocaleDateString("en-US", { month: "short", day: "numeric", ...opts });
}

type Period = "today" | "7d" | "30d";
type Tab    = "tenant" | "gateway" | "provider" | "model" | "user";

function periodSince(p: Period): number {
  const now = Date.now();
  if (p === "today") return Math.floor(now / 86400000) * 86400000;
  if (p === "7d")    return now - 7  * 86400000;
  return               now - 30 * 86400000;
}
function periodLabel(p: Period) {
  return p === "today" ? "Today" : p === "7d" ? "Last 7 days" : "Last 30 days";
}

// ---------------------------------------------------------------------------
// Sub-components
// ---------------------------------------------------------------------------

function OverviewChart({
  data, formatCurrency,
}: {
  data: TimeseriesPoint[];
  formatCurrency: (n: number) => string;
}) {
  const hover = useChartHover();
  const containerRef = useRef<HTMLDivElement | null>(null);
  if (!data.length) return null;
  const W = 600; const H = 64; const gap = 1;
  const n    = data.length;
  const barW = Math.max(1, Math.floor((W - gap * (n - 1)) / n));
  const slotW = (W - gap * (n - 1)) / n + gap;  // includes gap so slots tile flush
  const maxCost = Math.max(...data.map(d => d.cost_usd), 0.0001);
  const maxReq  = Math.max(...data.map(d => d.requests), 1);
  const pts = data.map((d, i) => {
    const x = i * (barW + gap) + barW / 2;
    const y = H - (d.requests / maxReq) * (H - 4);
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(" ");
  return (
    <div ref={containerRef} className={s.card} style={{ marginBottom: 20, position: "relative" }}>
      <div className={`${s["card-header"]} ${ta["overview-chart-header"]}`}>
        <h2 className={s["card-title"]}>30-Day Overview</h2>
        <div className={ta["chart-legend"]}>
          <span className={ta["legend-item"]}>
            <span className={ta["legend-dot"]} style={{ background: "var(--badge-success-text, #16a34a)" }} />
            Cost
          </span>
          <span className={ta["legend-item"]}>
            <span className={ta["legend-line"]} style={{ background: "var(--accent)" }} />
            Requests
          </span>
        </div>
      </div>
      <svg
        width="100%" height={H} viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none"
        style={{ display: "block" }}
        aria-label="30-day overview chart"
        onMouseLeave={hover.onLeave}
      >
        {data.map((d, i) => {
          const bh = Math.max(1, (d.cost_usd / maxCost) * (H - 2));
          const isHovered = hover.hovered === i;
          return (
            <rect
              key={i}
              x={i * (barW + gap)} y={H - bh} width={barW} height={bh}
              fill="var(--badge-success-text, #16a34a)"
              opacity={isHovered ? 1.0 : 0.55}
              stroke={isHovered ? "var(--accent)" : "none"}
              strokeWidth={isHovered ? 1 : 0}
              rx={1}
            />
          );
        })}
        <polyline points={pts} fill="none" stroke="var(--accent)" strokeWidth="1.5" opacity={0.8} />
        {/* Invisible hit-targets last so they sit on top of bars+line in z-order
            and capture pointer events for any vertical position over a column. */}
        {data.map((d, i) => (
          <rect
            key={`hit-${i}`}
            data-chart-hit
            x={i * slotW} y={0} width={slotW} height={H}
            fill="transparent" cursor="pointer"
            aria-label={`${dateLabel(d.ts, { weekday: "short" })}: ${formatCurrency(d.cost_usd)}, ${fmtNumber(d.requests)} request${d.requests === 1 ? "" : "s"}`}
            onClick={() => hover.togglePin(i)}
            {...hover.bind(i)}
          />
        ))}
      </svg>
      <ChartTooltip
        hover={hover}
        data={data}
        containerRef={containerRef}
        render={d => (
          <div data-cy="overview-tooltip">
            <div style={{ color: "var(--text-secondary)", marginBottom: 2 }}>
              {dateLabel(d.ts, { weekday: "short" })}
            </div>
            <div><strong>{formatCurrency(d.cost_usd)}</strong></div>
            <div style={{ color: "var(--text-secondary)" }}>
              {fmtNumber(d.requests)} request{d.requests === 1 ? "" : "s"}
            </div>
          </div>
        )}
      />
    </div>
  );
}

function LatencyStrip({ percentiles }: { percentiles: LatencyPercentiles }) {
  if (percentiles.p50 == null && percentiles.p95 == null && percentiles.p99 == null) return null;
  const items: [string, number | null][] = [
    ["p50", percentiles.p50],
    ["p95", percentiles.p95],
    ["p99", percentiles.p99],
  ];
  return (
    <div className={ta["latency-strip"]}>
      {items.map(([label, val]) => (
        <div key={label} className={ta["latency-item"]}>
          <span className={ta["latency-label"]}>{label}</span>
          <span className={ta["latency-value"]}>{val != null ? `${val} ms` : "—"}</span>
        </div>
      ))}
      <span className={ta["latency-caption"]}>Latency percentiles (non-blocked)</span>
    </div>
  );
}

function ProportionBar({ value, max }: { value: number; max: number }) {
  const pct = max > 0 ? Math.round((value / max) * 100) : 0;
  return (
    <div className={ta["proportion-bar"]}>
      <div className={ta["proportion-track"]}>
        <div className={ta["proportion-fill"]} style={{ width: `${pct}%` }} />
      </div>
      <span className={ta["proportion-pct"]}>{pct}%</span>
    </div>
  );
}

function BudgetBar({ used, total, fmtFn = fmtCost }: { used: number; total: number; fmtFn?: (n: number) => string }) {
  const pct   = total > 0 ? Math.min((used / total) * 100, 100) : 0;
  const color = pct >= 100 ? "var(--badge-error-text)" : pct >= 80 ? "var(--badge-warning-text)" : "var(--badge-success-text)";
  return (
    <div>
      <div className={ta["budget-label-row"]}>
        <span>{fmtFn(used)}</span>
        <span>{fmtFn(total)}</span>
      </div>
      <div className={ta["budget-track"]}>
        <div className={ta["budget-fill"]} style={{ width: `${pct}%`, background: color }} />
      </div>
    </div>
  );
}

function BarChart({
  data, height = 72, formatCurrency,
}: {
  data: TimeseriesPoint[];
  height?: number;
  formatCurrency: (n: number) => string;
}) {
  const hover = useChartHover();
  const containerRef = useRef<HTMLDivElement | null>(null);

  if (!data.length) return <div style={{ height }} />;
  const max = Math.max(...data.map(d => d.cost_usd));
  if (max === 0) return (
    <div className={ta["no-spend"]} style={{ height }}>
      No spend in this period
    </div>
  );
  const W = 400; const H = height; const gap = 2;
  const barW = Math.max(2, (W - gap * (data.length - 1)) / data.length);
  const slotW = (W - gap * (data.length - 1)) / data.length + gap;

  return (
    <div ref={containerRef} style={{ position: "relative" }}>
      <svg
        width="100%" height={H} viewBox={`0 0 ${W} ${H}`} preserveAspectRatio="none"
        style={{ color: "var(--badge-success-text, #16a34a)", display: "block" }}
        onMouseLeave={hover.onLeave}
      >
        {data.map((d, i) => {
          const bh = (d.cost_usd / max) * H * 0.92;
          const isHovered = hover.hovered === i;
          return (
            <rect
              key={i}
              x={i * (barW + gap)} y={H - bh} width={barW} height={bh}
              fill="currentColor"
              opacity={isHovered ? 1.0 : 0.65}
              rx={1}
            />
          );
        })}
        {data.map((d, i) => (
          <rect
            key={`hit-${i}`}
            data-chart-hit
            x={i * slotW} y={0} width={slotW} height={H}
            fill="transparent" cursor="pointer"
            aria-label={`${dateLabel(d.ts)}: ${formatCurrency(d.cost_usd)}`}
            onClick={() => hover.togglePin(i)}
            {...hover.bind(i)}
          />
        ))}
      </svg>
      <ChartTooltip
        hover={hover}
        data={data}
        containerRef={containerRef}
        render={d => (
          <div data-cy="barchart-tooltip">
            <span style={{ color: "var(--text-secondary)" }}>{dateLabel(d.ts)}</span>
            {" "}<strong>{formatCurrency(d.cost_usd)}</strong>
          </div>
        )}
      />
    </div>
  );
}

// ---------------------------------------------------------------------------
// Detail panel
// ---------------------------------------------------------------------------

function anthropicToTimeseries(usage: AnthropicUsage, n = 30): TimeseriesPoint[] {
  const byDate = new Map<string, number>();
  for (const row of usage.daily) {
    byDate.set(row.snapshot_date, (byDate.get(row.snapshot_date) ?? 0) + parseFloat(row.cost_usd));
  }
  const result: TimeseriesPoint[] = [];
  const now = Date.now();
  for (let i = n - 1; i >= 0; i--) {
    const d = new Date(now - i * 86400000);
    const dateStr = d.toISOString().slice(0, 10);
    result.push({
      ts: Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()),
      cost_usd: byDate.get(dateStr) ?? 0,
      requests: 0,
      blocked: 0,
      rate_limited: 0,
    });
  }
  return result;
}

function fmtTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000)     return `${(n / 1_000).toFixed(1)}K`;
  return String(n);
}

function AnthropicUsagePanel({ usage }: { usage: AnthropicUsage | null }) {
  if (!usage || !usage.daily) return null;
  if (usage.daily.length === 0) return (
    <div className={s.card} style={{ marginBottom: 20 }}>
      <div className={s["card-header"]}><h2 className={s["card-title"]}>Anthropic Usage (API)</h2></div>
      <div className={s.empty}>No usage data yet. Syncs hourly once an admin key is configured.</div>
    </div>
  );

  const lastSync = usage.last_synced_at
    ? new Date(usage.last_synced_at * 1000).toLocaleString()
    : "never";

  const isAuthoritative = usage.daily.some(r => r.source === "byok");

  const byDate = new Map<string, AnthropicUsageRow[]>();
  for (const row of usage.daily) {
    const rows = byDate.get(row.snapshot_date) ?? [];
    rows.push(row);
    byDate.set(row.snapshot_date, rows);
  }
  const dates = [...byDate.keys()].sort((a, b) => b.localeCompare(a)).slice(0, 14);

  return (
    <div className={s.card} style={{ marginBottom: 20 }}>
      <div className={s["card-header"]}>
        <h2 className={s["card-title"]}>Anthropic Usage (API)</h2>
        <span className={`${s.badge} ${isAuthoritative ? s["badge--success"] : s["badge--neutral"]}`}>
          {isAuthoritative ? "Authoritative" : "Estimated"}
        </span>
      </div>

      <div className={s["stats-grid"]} style={{ marginBottom: 16 }}>
        {([
          ["Input Tokens",       fmtTokens(usage.totals.uncached_input_tokens)],
          ["Output Tokens",      fmtTokens(usage.totals.output_tokens)],
          ["Cache Read",         fmtTokens(usage.totals.cache_read_tokens)],
          ["Web Searches",       String(usage.totals.web_search_requests)],
          ["Total Cost",         `$${parseFloat(usage.totals.cost_usd).toFixed(4)}`],
        ] as [string, string][]).map(([label, value]) => (
          <div key={label} className={s["stat-card"]}>
            <div className={s["stat-label"]}>{label}</div>
            <div className={s["stat-value"]}>{value}</div>
          </div>
        ))}
      </div>

      <div className={s["table-wrapper"]}>
        <table className={s.table}>
          <thead>
            <tr>
              <th>Date</th>
              <th>Model</th>
              <th>Tier</th>
              <th style={{ textAlign: "right" }}>Input</th>
              <th style={{ textAlign: "right" }}>Output</th>
              <th style={{ textAlign: "right" }}>Cache Read</th>
              <th style={{ textAlign: "right" }}>Cost</th>
            </tr>
          </thead>
          <tbody>
            {dates.flatMap(date =>
              (byDate.get(date) ?? []).map((row, i) => (
                <tr key={`${date}-${i}`}>
                  <td className={s.mono} style={{ fontSize: 11 }}>{i === 0 ? date : ""}</td>
                  <td><span className={s.mono} style={{ fontSize: 11 }}>{row.model || "—"}</span></td>
                  <td>{row.service_tier}</td>
                  <td style={{ textAlign: "right" }}>{fmtTokens(row.uncached_input_tokens)}</td>
                  <td style={{ textAlign: "right" }}>{fmtTokens(row.output_tokens)}</td>
                  <td style={{ textAlign: "right" }}>{fmtTokens(row.cache_read_tokens)}</td>
                  <td style={{ textAlign: "right" }}>${parseFloat(row.cost_usd).toFixed(4)}</td>
                </tr>
              ))
            )}
          </tbody>
        </table>
      </div>
      <p style={{ fontSize: 11, color: "var(--text-secondary)", marginTop: 8, padding: "0 4px" }}>
        Last synced: {lastSync}
      </p>
    </div>
  );
}

function DetailPanel({
  tenant, tenantMeta, detail, spend, anthropicUsage, onClose, fc,
}: {
  tenant: TenantStats;
  tenantMeta: Tenant | undefined;
  detail: TenantAnalyticsDetail | null;
  spend: SpendRecord[] | null;
  anthropicUsage: AnthropicUsage | null;
  onClose: () => void;
  fc: (n: number | undefined | null) => string;
}) {
  const monthlySpend = spend
    ?.filter(r => /^\d{4}-\d{2}$/.test(r.period))
    .sort((a, b) => b.period.localeCompare(a.period))
    .slice(0, 12) ?? [];

  return (
    <>
      <div onClick={onClose} className={ta["detail-backdrop"]} />
      <div className={ta["detail-drawer"]}>
        <div className={ta["detail-header"]}>
          <div>
            <div className={ta["detail-tenant-name"]}>
              <span className={s.code}>{tenant.tenant}</span>
            </div>
            {tenantMeta && (
              <div className={ta["detail-badges"]}>
                <span className={`${s.badge} ${s["badge--neutral"]}`}>{tenantMeta.plan}</span>
                {tenantMeta.budget_usd != null && (
                  <span className={`${s.badge} ${s["badge--neutral"]}`}>
                    {fc(tenantMeta.budget_usd)} / {tenantMeta.budget_period}
                  </span>
                )}
              </div>
            )}
          </div>
          <button className={s["modal-close"]} onClick={onClose} aria-label="Close">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
              <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
        </div>

        <div className={s["stats-grid"]} style={{ marginBottom: 24 }}>
          {([
            ["Requests",    fmtNumber(tenant.requests)],
            ["Cost",        fc(tenant.cost_usd)],
            ["Avg Latency", fmtMs(tenant.avg_latency_ms)],
          ] as [string, string][]).map(([label, value]) => (
            <div key={label} className={s["stat-card"]}>
              <div className={s["stat-label"]}>{label}</div>
              <div className={s["stat-value"]}>{value}</div>
            </div>
          ))}
        </div>

        {tenantMeta?.budget_usd != null && (
          <div className={s.card} style={{ marginBottom: 20 }}>
            <div className={s["card-header"]}><h2 className={s["card-title"]}>Budget Utilization</h2></div>
            <BudgetBar used={tenant.cost_usd} total={tenantMeta.budget_usd} fmtFn={fc} />
          </div>
        )}

        {(() => {
          const anthropicTs = anthropicUsage && anthropicUsage.daily && anthropicUsage.daily.length > 0
            ? anthropicToTimeseries(anthropicUsage) : null;
          const chartData = anthropicTs ?? detail?.timeseries ?? [];
          const authoritative = anthropicTs !== null;
          return (
            <div className={s.card} style={{ marginBottom: 20 }}>
              <div className={s["card-header"]}>
                <h2 className={s["card-title"]}>Cost — Last 30 Days</h2>
                {authoritative && (
                  <span className={`${s.badge} ${s["badge--success"]}`}>Authoritative</span>
                )}
              </div>
              {chartData.length > 0
                ? <BarChart data={chartData} formatCurrency={fc} />
                : <div className={s.empty} style={{ padding: 24 }}>Loading…</div>}
            </div>
          );
        })()}

        {(detail?.top_models?.length ?? 0) > 0 && (
          <div className={s.card} style={{ marginBottom: 20 }}>
            <div className={s["card-header"]}><h2 className={s["card-title"]}>Top Models</h2></div>
            <div className={s["table-wrapper"]}>
              <table className={s.table}>
                <thead><tr><th>Model</th><th>Requests</th><th>Cost</th><th>Avg Latency</th></tr></thead>
                <tbody>
                  {detail!.top_models.map((m: TopModelRow, i: number) => (
                    <tr key={i}>
                      <td>
                        <div className={`${s.mono} ${s.truncate}`} style={{ fontSize: 11, maxWidth: 160 }}>{m.model}</div>
                        <div className={s["stat-label"]}>{m.provider}</div>
                      </td>
                      <td>{fmtNumber(m.requests)}</td>
                      <td>{fc(m.cost_usd)}</td>
                      <td>{fmtMs(m.avg_latency_ms)}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}

        {monthlySpend.length > 0 && (
          <div className={s.card} style={{ marginBottom: 20 }}>
            <div className={s["card-header"]}><h2 className={s["card-title"]}>Monthly Spend</h2></div>
            <div className={s["table-wrapper"]}>
              <table className={s.table}>
                <thead><tr><th>Month</th><th>Spend</th></tr></thead>
                <tbody>
                  {monthlySpend.map((r: SpendRecord) => (
                    <tr key={r.period}><td>{r.period}</td><td>{fc(r.amount_usd)}</td></tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        )}

        <AnthropicUsagePanel usage={anthropicUsage} />
      </div>
    </>
  );
}

// ---------------------------------------------------------------------------
// Main page
// ---------------------------------------------------------------------------

type ProviderAgg = {
  provider: string;
  requests: number;
  cost_usd: number;
  avg_latency_ms: number;
  model_count: number;
};

function computeByProvider(topModels: TopModelRow[]): ProviderAgg[] {
  const map = new Map<string, { requests: number; cost_usd: number; lat_sum: number; lat_cnt: number; models: Set<string> }>();
  for (const row of topModels) {
    const p = map.get(row.provider) ?? { requests: 0, cost_usd: 0, lat_sum: 0, lat_cnt: 0, models: new Set() };
    p.requests += row.requests;
    p.cost_usd += row.cost_usd;
    if (row.avg_latency_ms > 0) { p.lat_sum += row.avg_latency_ms * row.requests; p.lat_cnt += row.requests; }
    p.models.add(row.model);
    map.set(row.provider, p);
  }
  return [...map.entries()]
    .map(([provider, p]) => ({
      provider,
      requests:       p.requests,
      cost_usd:       Math.round(p.cost_usd * 10000) / 10000,
      avg_latency_ms: p.lat_cnt > 0 ? Math.round(p.lat_sum / p.lat_cnt) : 0,
      model_count:    p.models.size,
    }))
    .sort((a, b) => b.cost_usd - a.cost_usd);
}

export default function TenantAnalytics() {
  useDocumentTitle("Cost Analytics");

  const [searchParams, setSearchParams] = useSearchParams();
  const rawPeriod = searchParams.get("timeframe") ?? "";
  const period: Period = (["today","7d","30d"] as const).includes(rawPeriod as Period)
    ? rawPeriod as Period
    : "7d";
  const [tab, setTab]                     = useState<Tab>("tenant");
  const [analytics, setAnalytics]         = useState<AnalyticsDepth | null>(null);
  const [tenants, setTenants]             = useState<Tenant[] | null>(null);
  const [globalTimeseries, setGlobalTs]   = useState<TimeseriesPoint[] | null>(null);
  const [loading, setLoading]             = useState(true);
  const [loadError, setLoadError]         = useState<string | null>(null);
  const [selected, setSelected]           = useState<TenantStats | null>(null);
  const [detail, setDetail]               = useState<TenantAnalyticsDetail | null>(null);
  const [spend, setSpend]                 = useState<SpendRecord[] | null>(null);
  const [anthropicUsage, setAnthropicUsage] = useState<AnthropicUsage | null>(null);
  const [filterText, setFilterText]       = useState("");
  const { currency, setCurrency, fc } = useCurrency();

  // Fetch analytics + tenants + global timeseries on period change
  useEffect(() => {
    setLoading(true);
    setLoadError(null);
    const since = periodSince(period);
    Promise.all([
      api.get<AnalyticsDepth>(`/stats/analytics?since=${since}`),
      api.get<Tenant[]>("/tenants"),
      api.get<TimeseriesPoint[]>("/stats/timeseries?bucket=1d&n=30"),
    ]).then(([a, t, ts]) => {
      setAnalytics(a);
      setTenants(t);
      setGlobalTs(ts);
    }).catch((err: any) => setLoadError(err.message ?? "Failed to load analytics"))
      .finally(() => setLoading(false));
  }, [period]);

  // Reset filter when switching tabs
  useEffect(() => { setFilterText(""); }, [tab]);

  // Fetch detail + spend + Anthropic usage when a tenant row is selected
  useEffect(() => {
    if (!selected) { setDetail(null); setSpend(null); setAnthropicUsage(null); return; }
    const since = periodSince("30d");
    const from  = new Date(since).toISOString().slice(0, 10);
    const to    = new Date().toISOString().slice(0, 10);
    setDetail(null); setSpend(null); setAnthropicUsage(null);
    Promise.all([
      api.get<TenantAnalyticsDetail>(`/tenants/${selected.tenant_id}/analytics?since=${since}&bucket=1d&n=30`),
      api.get<SpendRecord[]>(`/tenants/${selected.tenant_id}/spend?limit=18`),
      api.get<AnthropicUsage>(`/tenants/${selected.tenant_id}/anthropic-usage?from=${from}&to=${to}`),
    ]).then(([d, sp, au]) => { setDetail(d); setSpend(sp); setAnthropicUsage(au); }).catch(() => {});
  }, [selected]);

  // Derived values
  const tenantMap    = new Map<string, Tenant>((tenants ?? []).map(t => [t.id, t]));
  const byTenant     = analytics?.by_tenant  ?? [];
  const byGateway    = analytics?.by_gateway ?? [];
  const byModel      = analytics?.top_models ?? [];
  const byUser       = analytics?.by_user    ?? [];
  const byProvider   = computeByProvider(byModel);

  const totalCost      = byTenant.reduce((sum, r) => sum + r.cost_usd, 0);
  const totalSavedCost = byTenant.reduce((sum, r) => sum + r.saved_cost_usd, 0);
  const totalRequests  = byTenant.reduce((sum, r) => sum + r.requests, 0);
  const totalErrors    = byTenant.reduce((sum, r) => sum + (r.errors ?? 0), 0);

  const maxTenantCost   = byTenant[0]?.cost_usd   ?? 0;
  const maxGwCost       = byGateway[0]?.cost_usd  ?? 0;
  const maxModelCost    = byModel[0]?.cost_usd     ?? 0;
  const maxProviderCost = byProvider[0]?.cost_usd  ?? 0;
  const maxUserCost     = byUser[0]?.cost_usd      ?? 0;

  const overBudgetCount = byTenant.filter(r => {
    const meta = tenantMap.get(r.tenant_id);
    return meta?.budget_usd != null && r.cost_usd / meta.budget_usd >= 0.8;
  }).length;

  const topSpender = byTenant[0];

  // Filtered arrays
  const ft                = filterText.trim().toLowerCase();
  const filteredByTenant  = ft ? byTenant.filter(r => r.tenant.toLowerCase().includes(ft)) : byTenant;
  const filteredByGateway = ft ? byGateway.filter(r => r.gateway.toLowerCase().includes(ft) || (r.tenant ?? "").toLowerCase().includes(ft)) : byGateway;
  const filteredByProvider = ft ? byProvider.filter(r => r.provider.toLowerCase().includes(ft)) : byProvider;
  const filteredByModel   = ft ? byModel.filter(r => r.model.toLowerCase().includes(ft) || r.provider.toLowerCase().includes(ft)) : byModel;
  const filteredByUser    = byUser
    .filter(r => !selected || r.tenant_id === selected.tenant_id)
    .filter(r => !ft      || r.user_id.toLowerCase().includes(ft));

  const activeFiltered = tab === "tenant" ? filteredByTenant.length
    : tab === "gateway"  ? filteredByGateway.length
    : tab === "provider" ? filteredByProvider.length
    : tab === "model"    ? filteredByModel.length
    : filteredByUser.length;
  const activeTotal = tab === "tenant" ? byTenant.length
    : tab === "gateway"  ? byGateway.length
    : tab === "provider" ? byProvider.length
    : tab === "model"    ? byModel.length
    : byUser.length;

  if (loading) return <div className={s.page}><p className={s.empty}>Loading…</p></div>;
  if (loadError) return <div className={s.page}><div className={`${s.alert} ${s["alert--error"]}`}>{loadError}</div></div>;

  const tabLabel = (t: Tab) => ({ tenant: "By Tenant", gateway: "By Gateway", provider: "By Provider", model: "By Model", user: "By User" }[t]);
  const filterPlaceholder = { tenant: "Filter tenants…", gateway: "Filter gateways…", provider: "Filter providers…", model: "Filter models…", user: "Filter users…" }[tab];

  return (
    <main className={s.page}>
      {/* Header */}
      <div className={s["page-header"]}>
        <div>
          <h1 className={s["page-title"]}>Cost Analytics</h1>
          <p className={s["page-subtitle"]}>Spend breakdown by tenant, gateway, provider, model, and user</p>
        </div>
        <div style={{ display: "flex", gap: 12, alignItems: "center" }}>
          <CurrencySelector value={currency} onChange={setCurrency} />
          <div className={s["timeframe-tabs"]}>
            {(["today", "7d", "30d"] as Period[]).map(p => (
              <button key={p} className={`${s["timeframe-tab"]} ${period === p ? s["timeframe-tab--active"] : ""}`}
                onClick={() => setSearchParams({ timeframe: p }, { replace: true })}>
                {periodLabel(p)}
              </button>
            ))}
          </div>
        </div>
      </div>

      {/* 30-day overview chart */}
      {globalTimeseries && globalTimeseries.length > 0 && (
        <OverviewChart data={globalTimeseries} formatCurrency={fc} />
      )}

      {/* Latency percentile strip */}
      {analytics && <LatencyStrip percentiles={analytics.percentiles} />}

      {/* Hero cards */}
      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))", gap: 16, marginBottom: 24 }}>
        <div className={s["hero-card"]}>
          <div className={s["hero-label"]}>Total Spend</div>
          <div className={s["hero-value"]}>{fc(totalCost)}</div>
          <div className={s["hero-sub"]}>{periodLabel(period)}</div>
        </div>
        <div className={s["hero-card"]}>
          <div className={s["hero-label"]}>Cache Savings</div>
          <div className={s["hero-value"]} style={{ color: totalSavedCost > 0 ? "var(--badge-success-text, #16a34a)" : undefined }}>
            {fc(totalSavedCost)}
          </div>
          <div className={s["hero-sub"]}>{periodLabel(period)}</div>
        </div>
        <div className={s["hero-card"]}>
          <div className={s["hero-label"]}>Total Requests</div>
          <div className={s["hero-value"]}>{fmtNumber(totalRequests)}</div>
          <div className={s["hero-sub"]}>{periodLabel(period)}</div>
        </div>
        <div className={s["hero-card"]}>
          <div className={s["hero-label"]}>Error Rate</div>
          <div className={s["hero-value"]} style={{ color: totalErrors > 0 ? "var(--badge-warning-text)" : undefined }}>
            {fmtRate(totalErrors, totalRequests)}
          </div>
          <div className={s["hero-sub"]}>{totalErrors} error{totalErrors !== 1 ? "s" : ""}</div>
        </div>
        <div className={s["hero-card"]}>
          <div className={s["hero-label"]}>Top Spender</div>
          <div className={s["hero-value"]} style={{ fontSize: 20 }}>
            {topSpender ? <span className={s.code}>{topSpender.tenant}</span> : "—"}
          </div>
          <div className={s["hero-sub"]}>
            {topSpender
              ? <><span className={s["hero-sub-highlight"]}>{fc(topSpender.cost_usd)}</span> this period</>
              : "No data"}
          </div>
        </div>
        <div className={s["hero-card"]}>
          <div className={s["hero-label"]}>Budget Warnings</div>
          <div className={s["hero-value"]} style={{ color: overBudgetCount > 0 ? "var(--badge-warning-text)" : undefined }}>
            {overBudgetCount}
          </div>
          <div className={s["hero-sub"]}>tenants ≥ 80% of budget</div>
        </div>
      </div>

      {/* Filter bar */}
      <div style={{ display: "flex", gap: 8, marginBottom: 12, alignItems: "center" }}>
        <input
          type="text"
          value={filterText}
          onChange={e => setFilterText(e.target.value)}
          placeholder={filterPlaceholder}
          aria-label="Filter rows"
          style={{
            background: "var(--section-bg)", border: "1px solid var(--card-border)",
            borderRadius: 6, padding: "6px 12px", fontSize: 13,
            color: "var(--text-primary)", width: 240, outline: "none",
          }}
        />
        {filterText && (
          <button onClick={() => setFilterText("")}
            style={{ fontSize: 12, padding: "4px 10px", borderRadius: 6, border: "1px solid var(--card-border)", background: "var(--section-bg)", color: "var(--text-secondary)", cursor: "pointer" }}>
            Clear
          </button>
        )}
        {ft && (
          <span style={{ fontSize: 12, color: "var(--text-secondary)" }}>
            {activeFiltered} of {activeTotal}
          </span>
        )}
      </div>

      {/* Tab bar */}
      <div className={s["timeframe-tabs"]} style={{ marginBottom: 20 }}>
        {(["tenant", "gateway", "provider", "model", "user"] as Tab[]).map(t => (
          <button key={t} className={`${s["timeframe-tab"]} ${tab === t ? s["timeframe-tab--active"] : ""}`}
            onClick={() => setTab(t)}>
            {tabLabel(t)}
          </button>
        ))}
      </div>

      {/* ── By Tenant ─────────────────────────────────────────────────── */}
      {tab === "tenant" && (
        <div className={s.card}>
          <div className={s["card-header"]}>
            <h2 className={s["card-title"]}>Tenant Breakdown — {periodLabel(period)}</h2>
          </div>
          {filteredByTenant.length === 0
            ? <div className={s.empty}>No data for this period.</div>
            : (
              <div className={s["table-wrapper"]}>
                <table className={s.table}>
                  <thead>
                    <tr>
                      <th>Tenant</th><th>Requests</th><th>Cost</th>
                      <th style={{ minWidth: 140 }}>Share</th>
                      <th>Cache</th><th>Errors</th><th>Blocked</th>
                      <th>Avg Latency</th><th>Budget</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filteredByTenant.map(row => {
                      const meta      = tenantMap.get(row.tenant_id);
                      const cacheRate = row.requests > 0 ? ((row.cached / row.requests) * 100).toFixed(0) : null;
                      return (
                        <tr key={row.tenant_id} style={{ cursor: "pointer" }}
                          onClick={() => setSelected(selected?.tenant_id === row.tenant_id ? null : row)}>
                          <td><span className={s.code}>{row.tenant}</span></td>
                          <td>{fmtNumber(row.requests)}</td>
                          <td>{fc(row.cost_usd)}</td>
                          <td><ProportionBar value={row.cost_usd} max={maxTenantCost} /></td>
                          <td>{cacheRate != null ? `${cacheRate}%` : "—"}</td>
                          <td>{row.errors > 0
                            ? <span className={`${s.badge} ${s["badge--warning"]}`}>{fmtRate(row.errors, row.requests)}</span>
                            : "—"}</td>
                          <td>{row.blocked > 0
                            ? <span className={`${s.badge} ${s["badge--error"]}`}>{fmtNumber(row.blocked)}</span>
                            : "—"}</td>
                          <td>{fmtMs(row.avg_latency_ms)}</td>
                          <td style={{ minWidth: 160 }}>
                            {meta?.budget_usd != null
                              ? <BudgetBar used={row.cost_usd} total={meta.budget_usd} fmtFn={fc} />
                              : <span style={{ fontSize: 11, color: "var(--text-secondary)" }}>unlimited</span>}
                          </td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )
          }
        </div>
      )}

      {/* ── By Gateway ────────────────────────────────────────────────── */}
      {tab === "gateway" && (
        <div className={s.card}>
          <div className={s["card-header"]}>
            <h2 className={s["card-title"]}>Gateway Breakdown — {periodLabel(period)}</h2>
          </div>
          {filteredByGateway.length === 0
            ? <div className={s.empty}>No data for this period.</div>
            : (
              <div className={s["table-wrapper"]}>
                <table className={s.table}>
                  <thead>
                    <tr>
                      <th>Gateway</th><th>Tenant</th><th>Requests</th><th>Cost</th>
                      <th style={{ minWidth: 140 }}>Share</th>
                      <th>Cache</th><th>Errors</th><th>Blocked</th><th>Avg Latency</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filteredByGateway.map((row: GatewayStats) => {
                      const cacheRate = row.requests > 0 ? ((row.cached / row.requests) * 100).toFixed(0) : null;
                      return (
                        <tr key={row.gateway_id}>
                          <td><span className={s.code}>{row.gateway}</span></td>
                          <td>{row.tenant ? <span className={s.code}>{row.tenant}</span> : "—"}</td>
                          <td>{fmtNumber(row.requests)}</td>
                          <td>{fc(row.cost_usd)}</td>
                          <td><ProportionBar value={row.cost_usd} max={maxGwCost} /></td>
                          <td>{cacheRate != null ? `${cacheRate}%` : "—"}</td>
                          <td>{row.errors > 0
                            ? <span className={`${s.badge} ${s["badge--warning"]}`}>{fmtRate(row.errors, row.requests)}</span>
                            : "—"}</td>
                          <td>{row.blocked > 0
                            ? <span className={`${s.badge} ${s["badge--error"]}`}>{fmtNumber(row.blocked)}</span>
                            : "—"}</td>
                          <td>{fmtMs(row.avg_latency_ms)}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )
          }
        </div>
      )}

      {/* ── By Provider ───────────────────────────────────────────────── */}
      {tab === "provider" && (
        <div className={s.card}>
          <div className={s["card-header"]}>
            <h2 className={s["card-title"]}>Provider Breakdown — {periodLabel(period)}</h2>
          </div>
          {filteredByProvider.length === 0
            ? <div className={s.empty}>No data for this period.</div>
            : (
              <div className={s["table-wrapper"]}>
                <table className={s.table}>
                  <thead>
                    <tr>
                      <th>Provider</th><th>Models</th><th>Requests</th><th>Cost</th>
                      <th style={{ minWidth: 140 }}>Share</th>
                      <th>Avg Latency</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filteredByProvider.map((row: ProviderAgg) => (
                      <tr key={row.provider}>
                        <td><span className={s.code}>{row.provider}</span></td>
                        <td>{row.model_count}</td>
                        <td>{fmtNumber(row.requests)}</td>
                        <td>{fc(row.cost_usd)}</td>
                        <td><ProportionBar value={row.cost_usd} max={maxProviderCost} /></td>
                        <td>{fmtMs(row.avg_latency_ms)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )
          }
        </div>
      )}

      {/* ── By Model ──────────────────────────────────────────────────── */}
      {tab === "model" && (
        <div className={s.card}>
          <div className={s["card-header"]}>
            <h2 className={s["card-title"]}>Model Breakdown — {periodLabel(period)}</h2>
          </div>
          {filteredByModel.length === 0
            ? <div className={s.empty}>No data for this period.</div>
            : (
              <div className={s["table-wrapper"]}>
                <table className={s.table}>
                  <thead>
                    <tr>
                      <th>Model</th><th>Provider</th><th>Requests</th><th>Cost</th>
                      <th style={{ minWidth: 140 }}>Share</th>
                      <th>Avg Latency</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filteredByModel.map((row, i) => (
                      <tr key={i}>
                        <td className={s.mono} style={{ fontSize: 11 }}>{row.model}</td>
                        <td>{row.provider}</td>
                        <td>{fmtNumber(row.requests)}</td>
                        <td>{fc(row.cost_usd)}</td>
                        <td><ProportionBar value={row.cost_usd} max={maxModelCost} /></td>
                        <td>{fmtMs(row.avg_latency_ms)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )
          }
        </div>
      )}

      {/* ── By User ───────────────────────────────────────────────────── */}
      {tab === "user" && (
        <div className={s.card}>
          <div className={s["card-header"]}>
            <h2 className={s["card-title"]}>User Breakdown — {periodLabel(period)}</h2>
          </div>
          {filteredByUser.length === 0
            ? <div className={s.empty}>No data for this period.</div>
            : (
              <div className={s["table-wrapper"]}>
                <table className={s.table}>
                  <thead>
                    <tr>
                      <th>User</th><th>Requests</th><th>Cost</th>
                      <th style={{ minWidth: 140 }}>Share</th>
                      <th>Cache</th><th>Errors</th><th>Blocked</th><th>Avg Latency</th>
                    </tr>
                  </thead>
                  <tbody>
                    {filteredByUser.map((row: UserStats) => {
                      const cacheRate = row.requests > 0 ? ((row.cached / row.requests) * 100).toFixed(0) : null;
                      return (
                        <tr key={row.user_id}>
                          <td><span className={s.code}>{row.email ?? row.user_id}</span></td>
                          <td>{fmtNumber(row.requests)}</td>
                          <td>{fc(row.cost_usd)}</td>
                          <td><ProportionBar value={row.cost_usd} max={maxUserCost} /></td>
                          <td>{cacheRate != null ? `${cacheRate}%` : "—"}</td>
                          <td>{row.errors > 0
                            ? <span className={`${s.badge} ${s["badge--warning"]}`}>{fmtRate(row.errors, row.requests)}</span>
                            : "—"}</td>
                          <td>{row.blocked > 0
                            ? <span className={`${s.badge} ${s["badge--error"]}`}>{fmtNumber(row.blocked)}</span>
                            : "—"}</td>
                          <td>{fmtMs(row.avg_latency_ms)}</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )
          }
        </div>
      )}

      {/* Detail panel */}
      {selected && (
        <DetailPanel
          tenant={selected}
          tenantMeta={tenantMap.get(selected.tenant_id)}
          detail={detail}
          spend={spend}
          anthropicUsage={anthropicUsage}
          onClose={() => setSelected(null)}
          fc={fc}
        />
      )}
    </main>
  );
}
