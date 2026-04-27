import { useEffect, useState } from "react";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { useAuth } from "src/common/contexts/AuthContext";
import { api } from "src/api/client";
import { Tenant, Gateway, AuthToken } from "src/api/types";
import { fmtDate } from "src/common/utils/date";
import { docsUrl } from "src/common/components/DocLink";
import { Modal } from "src/common/components/Modal";
import { TokenRevealModal } from "src/common/components/TokenRevealModal";
import { StatusBadge, roleVariant } from "src/common/components/StatusBadge";
import s from "src/common/components/layout/Layout.module.scss";

// ---------------------------------------------------------------------------
// Token create modal
// ---------------------------------------------------------------------------

function TokenModal({ gateways, onClose, onCreated }: {
  gateways: (Gateway & { tenant_slug: string })[];
  onClose: () => void;
  onCreated: (token: string) => void;
}) {
  const [gatewayId, setGatewayId] = useState(gateways[0]?.id ?? "");
  const [label, setLabel] = useState("");
  const [expiresAt, setExpiresAt] = useState("");
  const [budgetUsd, setBudgetUsd] = useState("");
  const [rlRequests, setRlRequests] = useState("");
  const [rlWindow, setRlWindow] = useState("60");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!gatewayId) return setError("Select a gateway");
    setLoading(true); setError(null);
    try {
      const body: Record<string, unknown> = {
        gateway_id: gatewayId,
        label: label || null,
        scopes: ["inference"],
        expires_at: expiresAt || null,
        budget_usd: budgetUsd !== "" ? parseFloat(budgetUsd) : null,
      };
      if (rlRequests !== "") {
        body.rate_limit = { requests: parseInt(rlRequests), window_sec: parseInt(rlWindow) || 60 };
      }
      const res = await api.post<{ token: string }>("/me/tokens", body);
      onCreated(res.token);
    } catch (err: any) { setError(err.message); }
    finally { setLoading(false); }
  }

  return (
    <Modal title="New Token" onClose={onClose} error={error}>
      <form onSubmit={handleSubmit}>
          <div className={s["form-group"]}>
            <label className={s["form-label"]}>Gateway *</label>
            <select className={s["form-select"]} value={gatewayId} onChange={(e) => setGatewayId(e.target.value)} required>
              {gateways.map((g) => <option key={g.id} value={g.id}>{g.tenant_slug}/{g.slug}</option>)}
            </select>
          </div>
          <div className={s["form-row"]}>
            <div className={s["form-group"]}>
              <label className={s["form-label"]}>Label</label>
              <input className={s["form-input"]} value={label} onChange={(e) => setLabel(e.target.value)} placeholder="dev laptop" />
            </div>
            <div className={s["form-group"]}>
              <label className={s["form-label"]}>Expires At</label>
              <input className={s["form-input"]} type="datetime-local" value={expiresAt} onChange={(e) => setExpiresAt(e.target.value ? new Date(e.target.value).toISOString().slice(0, 19) + "Z" : "")} />
              <p className={s["form-hint"]}>Leave blank = never expires</p>
            </div>
          </div>
          <div className={s["form-row"]}>
            <div className={s["form-group"]}>
              <label className={s["form-label"]}>Budget (USD)</label>
              <input className={s["form-input"]} type="number" min="0" step="0.01" value={budgetUsd} onChange={(e) => setBudgetUsd(e.target.value)} placeholder="unlimited" />
            </div>
            <div className={s["form-group"]}>
              <label className={s["form-label"]}>Rate limit (req/window)</label>
              <div style={{ display: "flex", gap: 6 }}>
                <input className={s["form-input"]} type="number" min="1" value={rlRequests} onChange={(e) => setRlRequests(e.target.value)} placeholder="none" style={{ flex: 2 }} />
                <input className={s["form-input"]} type="number" min="1" value={rlWindow} onChange={(e) => setRlWindow(e.target.value)} placeholder="60s" style={{ flex: 1 }} />
              </div>
              <p className={s["form-hint"]}>requests / window_sec (blank = gateway default)</p>
            </div>
          </div>
          <div className={s["form-actions"]}>
            <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
            <button type="submit" className={`${s.btn} ${s["btn--primary"]}`} disabled={loading || !gatewayId}>
              {loading ? "Creating…" : "Create Token"}
            </button>
          </div>
        </form>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
// Profile page
// ---------------------------------------------------------------------------

const PROTECTED_EMAILS = [
  "apple-review@myrasecurity.com",
  "google-review@myrasecurity.com",
  "sascha@schumann.net",
];

export default function Profile() {
  useDocumentTitle("My Tokens");
  const { user: me, logout } = useAuth();
  const [gateways, setGateways] = useState<(Gateway & { tenant_slug: string })[]>([]);
  const [tokens, setTokens] = useState<AuthToken[]>([]);
  const [loadingTokens, setLoadingTokens] = useState(true);
  const [showCreate, setShowCreate] = useState(false);
  const [newToken, setNewToken] = useState<string | null>(null);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [deleteLoading, setDeleteLoading] = useState(false);
  const [deleteError, setDeleteError] = useState<string | null>(null);

  function loadTokens() {
    setLoadingTokens(true);
    api.get<AuthToken[]>("/me/tokens").then(setTokens).finally(() => setLoadingTokens(false));
  }

  function loadGateways() {
    api.get<Tenant[]>("/tenants")
      .then(async (tenants) => {
        const all: (Gateway & { tenant_slug: string })[] = [];
        for (const t of tenants) {
          const gs = await api.get<Gateway[]>(`/tenants/${t.id}/gateways`).catch(() => [] as Gateway[]);
          all.push(...gs.map((g) => ({ ...g, tenant_slug: t.slug })));
        }
        setGateways(all);
      })
      .catch(() => {});
  }

  useEffect(() => { loadTokens(); loadGateways(); }, []);

  async function revokeToken(tokenId: string) {
    if (!confirm("Revoke this token?")) return;
    try {
      await api.delete(`/me/tokens/${tokenId}`);
      loadTokens();
    } catch (e: any) { alert(e.message); }
  }

  async function handleDeleteAccount() {
    setDeleteLoading(true);
    setDeleteError(null);
    try {
      await api.delete("/me");
      await logout();
    } catch (e: any) {
      setDeleteError(e.message);
      setDeleteLoading(false);
    }
  }


  const canDelete = me?.email && !PROTECTED_EMAILS.includes(me.email);

  return (
    <div className={s.page}>
      {showCreate && gateways.length > 0 && (
        <TokenModal
          gateways={gateways}
          onClose={() => setShowCreate(false)}
          onCreated={(t) => { setShowCreate(false); setNewToken(t); loadTokens(); }}
        />
      )}
      {newToken && <TokenRevealModal token={newToken} onClose={() => setNewToken(null)} />}

      {showDeleteConfirm && (
        <Modal title="Delete Account" onClose={() => { setShowDeleteConfirm(false); setDeleteError(null); }} error={deleteError}>
          <p style={{ marginBottom: 12 }}>
            This deletes your account. You will be logged out immediately and will no longer be able to sign in.
          </p>
          <p style={{ marginBottom: 16, color: "var(--text-secondary)", fontSize: 14 }}>
            Your conversations and other data are retained per our{" "}
            <a href="/privacy" target="_blank" rel="noopener noreferrer">privacy policy</a>.
            Only an administrator can restore the account; you cannot reactivate it yourself.
            To request permanent erasure of your data, email us — see the privacy policy.
          </p>
          <div className={s["form-actions"]}>
            <button
              type="button"
              className={`${s.btn} ${s["btn--secondary"]}`}
              onClick={() => { setShowDeleteConfirm(false); setDeleteError(null); }}
              disabled={deleteLoading}
            >
              Cancel
            </button>
            <button
              type="button"
              className={`${s.btn} ${s["btn--danger"]}`}
              onClick={handleDeleteAccount}
              disabled={deleteLoading}
            >
              {deleteLoading ? "Deleting…" : "Delete Account"}
            </button>
          </div>
        </Modal>
      )}

      <div className={s["page-header"]}>
        <h1 className={s["page-title"]}>My Tokens</h1>
      </div>

      {/* Profile info */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Profile</h2>
        </div>
        <div className={s["stats-grid"]}>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Email</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`}>{me?.email}</div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Role</div>
            <div className={s["stat-value"]} style={{ marginTop: 6 }}>
              {me?.role && <StatusBadge value={me.role} variant={roleVariant(me.role)} />}
            </div>
          </div>
        </div>
      </div>

      {/* Tokens */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Tokens</h2>
          {me?.role !== "viewer" && (
            <button
              className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`}
              onClick={() => gateways.length > 0 ? setShowCreate(true) : alert("No gateways available")}
            >
              + New Token
            </button>
          )}
        </div>
        {me?.role === "viewer" ? (
          <div className={s.empty}>Viewer users cannot make inference requests.</div>
        ) : loadingTokens ? (
          <div className={s.empty}>Loading…</div>
        ) : tokens.length === 0 ? (
          <div className={s.empty}>No tokens yet. Create one to use the inference API. <a href={docsUrl("/admin-ui/my-tokens/")} target="_blank" rel="noopener noreferrer" style={{ color: "var(--text-secondary)" }}>Learn more</a></div>
        ) : (
          <div className={s["table-wrapper"]}>
            <table className={s.table}>
              <thead>
                <tr>
                  <th>Label</th>
                  <th>Gateway</th>
                  <th>Expires</th>
                  <th>Budget</th>
                  <th>Rate Limit</th>
                  <th>Created</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {tokens.map((t) => {
                  const gw = gateways.find((g) => g.id === t.gateway_id);
                  const rl = typeof t.rate_limit === "string" ? JSON.parse(t.rate_limit) : t.rate_limit;
                  return (
                    <tr key={t.id}>
                      <td>{t.label ?? <span style={{ color: "var(--text-secondary)" }}>—</span>}</td>
                      <td><span className={s.code}>{gw ? `${gw.tenant_slug}/${gw.slug}` : t.gateway_id.slice(0, 8)}</span></td>
                      <td className={s.mono} style={{ fontSize: 12 }}>
                        {t.expires_at ? fmtDate(t.expires_at) : <span style={{ color: "var(--text-secondary)" }}>never</span>}
                      </td>
                      <td>{t.budget_usd != null ? `$${t.budget_usd}` : <span style={{ color: "var(--text-secondary)" }}>—</span>}</td>
                      <td style={{ fontSize: 12 }}>
                        {rl ? `${rl.requests}/${rl.window_sec}s` : <span style={{ color: "var(--text-secondary)" }}>—</span>}
                      </td>
                      <td className={s.mono} style={{ fontSize: 12 }}>{fmtDate(t.created_at)}</td>
                      <td>
                        <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={() => revokeToken(t.id)}>Revoke</button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
      {canDelete && (
        <div className={s.card}>
          <div className={s["card-header"]}>
            <h2 className={s["card-title"]}>Danger Zone</h2>
          </div>
          <div style={{ padding: "12px 0" }}>
            <p style={{ color: "var(--text-secondary)", marginBottom: 12, fontSize: 14 }}>
              Deleting your account signs you out and locks you out of MYRA AI.
              Your data is retained per our{" "}
              <a href="/privacy" target="_blank" rel="noopener noreferrer">privacy policy</a>;
              only an administrator can restore the account.
            </p>
            <button
              className={`${s.btn} ${s["btn--danger"]}`}
              onClick={() => setShowDeleteConfirm(true)}
            >
              Delete Account
            </button>
          </div>
        </div>
      )}
    </div>
  );
}
