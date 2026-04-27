import { useEffect, useState, useCallback } from "react";
import { useNavigate } from "react-router-dom";
import { api } from "src/api/client";
import type { ProviderHealth } from "src/api/types";
import s from "src/common/components/layout/Layout.module.scss";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function relativeTime(unixSec: number): string {
  const diff = Math.floor(Date.now() / 1000) - unixSec;
  if (diff < 60)  return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

// ---------------------------------------------------------------------------
// Sub-components
// ---------------------------------------------------------------------------

function StatusBadge({ status, message }: { status: ProviderHealth["status"]; message: string | null }) {
  if (status === "ok")       return <span className={`${s.badge} ${s["badge--success"]}`} title={message ?? undefined}>Operational</span>;
  if (status === "degraded") return <span className={`${s.badge} ${s["badge--warning"]}`} title={message ?? undefined}>Degraded</span>;
  if (status === "down")     return <span className={`${s.badge} ${s["badge--error"]}`}   title={message ?? undefined}>Outage</span>;
  return <span className={s["badge"]} style={{ opacity: 0.5 }}>–</span>;
}

function ConfiguredBadge({ configured, navigate }: { configured: boolean | null; navigate: ReturnType<typeof useNavigate> }) {
  if (configured === null) {
    return <span className={`${s.badge} ${s["badge--neutral"]}`}>No key needed</span>;
  }
  if (configured) {
    return <span className={`${s.badge} ${s["badge--success"]}`}>Configured</span>;
  }
  return (
    <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
      <span className={`${s.badge} ${s["badge--warning"]}`}>Not configured</span>
      <button
        className={`${s.btn} ${s["btn--sm"]} ${s["btn--secondary"]}`}
        onClick={() => navigate("/gateways")}
        title="Add an API key for this provider"
      >
        Add key →
      </button>
    </span>
  );
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

export default function Providers() {
  useDocumentTitle("Providers");
  const navigate = useNavigate();

  const [providers, setProviders] = useState<ProviderHealth[]>([]);
  const [loading, setLoading]     = useState(true);
  const [error, setError]         = useState<string | null>(null);
  const [refreshedAt, setRefreshedAt] = useState<Date | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const data = await api.get<ProviderHealth[]>("/providers/health");
      // Sort: configured first, then alphabetically
      data.sort((a, b) => {
        if ((a.configured === true) !== (b.configured === true)) {
          return a.configured === true ? -1 : 1;
        }
        return a.name.localeCompare(b.name);
      });
      setProviders(data);
      setRefreshedAt(new Date());
    } catch (e) {
      setError(String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => { load(); }, [load]);

  const configuredCount    = providers.filter(p => p.configured === true).length;
  const operationalCount   = providers.filter(p => p.status === "ok").length;
  const withStatusPage     = providers.filter(p => p.has_status_page).length;

  return (
    <div className={s.page}>
      <div className={s["page-header"]}>
        <div>
          <h1 className={s["page-title"]}>Providers</h1>
          <p className={s["page-subtitle"]}>
            Supported AI providers — configuration and live availability status
          </p>
        </div>
        <button className={`${s.btn} ${s["btn--secondary"]}`} onClick={load} disabled={loading}>
          {loading ? "Refreshing…" : "Refresh"}
        </button>
      </div>

      {/* Summary cards */}
      <div className={s["stats-grid"]} style={{ marginBottom: "1.5rem" }}>
        <div className={s["stat-card"]}>
          <div className={s["stat-label"]}>Supported providers</div>
          <div className={s["stat-value"]}>{providers.length}</div>
        </div>
        <div className={s["stat-card"]}>
          <div className={s["stat-label"]}>Configured (any gateway)</div>
          <div className={s["stat-value"]}>{loading ? "–" : configuredCount}</div>
        </div>
        <div className={s["stat-card"]}>
          <div className={s["stat-label"]}>Operational (status page)</div>
          <div className={s["stat-value"]}>{loading ? "–" : `${operationalCount} / ${withStatusPage}`}</div>
        </div>
        {refreshedAt && (
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Status last refreshed</div>
            <div className={s["stat-value"] + " " + s["stat-value--text"]}>
              {refreshedAt.toLocaleTimeString()}
            </div>
          </div>
        )}
      </div>

      {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}

      {!loading && providers.length === 0 && !error && (
        <div className={s.empty}>No provider data available.</div>
      )}

      {providers.length > 0 && (
        <div className={s["table-wrapper"]}>
          <table className={s.table}>
            <thead>
              <tr>
                <th>Provider</th>
                <th>Supported</th>
                <th>Configured</th>
                <th>Live Status</th>
                <th>Last Checked</th>
              </tr>
            </thead>
            <tbody>
              {providers.map(p => (
                <tr key={p.name}>
                  <td style={{ fontFamily: "var(--font-mono, monospace)", fontWeight: 600 }}>
                    {p.name}
                  </td>
                  <td>
                    <span className={`${s.badge} ${s["badge--success"]}`}>✓ Supported</span>
                  </td>
                  <td>
                    <ConfiguredBadge configured={p.configured} navigate={navigate} />
                  </td>
                  <td>
                    {p.has_status_page
                      ? <StatusBadge status={p.status} message={p.message} />
                      : <span className={s.badge} style={{ opacity: 0.45 }} title="No public status page">–</span>
                    }
                  </td>
                  <td style={{ color: "var(--text-secondary)", fontSize: "0.85em" }}>
                    {p.checked_at ? relativeTime(p.checked_at) : "–"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <p style={{ marginTop: "1rem", color: "var(--text-secondary)", fontSize: "0.8em" }}>
        Status is polled from provider status pages every 5 minutes. Providers without a
        public status page show "–". The gateway polls only providers with known Atlassian
        Statuspage endpoints.
      </p>
    </div>
  );
}
