import { useEffect, useState } from "react";
import { useNavigate, useParams, Navigate } from "react-router-dom";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { api } from "src/api/client";
import { User, Tenant, Gateway, AuthToken } from "src/api/types";
import { fmtDate } from "src/common/utils/date";
import s from "src/common/components/layout/Layout.module.scss";

// ---------------------------------------------------------------------------
// Icons
// ---------------------------------------------------------------------------

function CloseIcon() {
  return <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>;
}

// ---------------------------------------------------------------------------
// User modal (create / edit)
// ---------------------------------------------------------------------------

function UserModal({ tenants, user, onClose, onSaved }: {
  tenants: Tenant[];
  user?: User;
  onClose: () => void;
  onSaved: () => void;
}) {
  const isEdit = !!user;
  const [tenantId, setTenantId] = useState(user?.tenant_id ?? tenants[0]?.id ?? "");
  const [email, setEmail] = useState(user?.email ?? "");
  const [name, setName] = useState(user?.name ?? "");
  const [role, setRole] = useState<User["role"]>(user?.role ?? "member");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true); setError(null);
    try {
      if (isEdit) {
        await api.patch(`/users/${user!.id}`, { email, name: name || null, role });
      } else {
        await api.post(`/tenants/${tenantId}/users`, { email, name: name || null, role });
      }
      onSaved(); onClose();
    } catch (err: any) { setError(err.message); }
    finally { setLoading(false); }
  }

  return (
    <div className={s["modal-overlay"]} onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className={s.modal}>
        <div className={s["modal-header"]}>
          <h2 className={s["modal-title"]}>{isEdit ? `Edit: ${user!.email}` : "New User"}</h2>
          <button className={s["modal-close"]} onClick={onClose}><CloseIcon /></button>
        </div>
        {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}
        <form onSubmit={handleSubmit}>
          {!isEdit && (
            <div className={s["form-group"]}>
              <label className={s["form-label"]}>Tenant *</label>
              <select className={s["form-select"]} value={tenantId} onChange={(e) => setTenantId(e.target.value)} required>
                {tenants.map((t) => <option key={t.id} value={t.id}>{t.slug}</option>)}
              </select>
            </div>
          )}
          <div className={s["form-group"]}>
            <label className={s["form-label"]}>Email *</label>
            <input className={s["form-input"]} type="email" value={email} onChange={(e) => setEmail(e.target.value)} placeholder="alice@example.com" required />
          </div>
          <div className={s["form-row"]}>
            <div className={s["form-group"]}>
              <label className={s["form-label"]}>Name</label>
              <input className={s["form-input"]} value={name} onChange={(e) => setName(e.target.value)} placeholder="Alice" />
            </div>
            <div className={s["form-group"]}>
              <label className={s["form-label"]}>Role</label>
              <select className={s["form-select"]} value={role} onChange={(e) => setRole(e.target.value as User["role"])}>
                <option value="admin">admin — full tenant access</option>
                <option value="member">member — granted gateways only</option>
                <option value="viewer">viewer — read-only, no inference</option>
              </select>
            </div>
          </div>
          <div className={s["form-actions"]}>
            <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
            <button type="submit" className={`${s.btn} ${s["btn--primary"]}`} disabled={loading}>
              {loading ? (isEdit ? "Saving…" : "Creating…") : (isEdit ? "Save Changes" : "Create User")}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Token modal (create token for a user)
// ---------------------------------------------------------------------------

function TokenModal({ user, gateways, onClose, onCreated }: {
  user: User;
  gateways: Gateway[];
  onClose: () => void;
  onCreated: (token: string) => void;
}) {
  const [gatewayId, setGatewayId] = useState(gateways[0]?.id ?? "");
  const [label, setLabel] = useState("");
  const [expiresAt, setExpiresAt] = useState("");
  const [budgetUsd, setBudgetUsd] = useState("");
  const [rlRequests, setRlRequests] = useState("");
  const [rlWindow, setRlWindow] = useState("60");
  const [scopes, setScopes] = useState<string[]>(["inference"]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function toggleScope(sc: string) {
    setScopes((prev) => prev.includes(sc) ? prev.filter((s) => s !== sc) : [...prev, sc]);
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!gatewayId) return setError("Select a gateway");
    setLoading(true); setError(null);
    try {
      const body: Record<string, unknown> = {
        gateway_id: gatewayId,
        label: label || null,
        scopes,
        expires_at: expiresAt || null,
        budget_usd: budgetUsd !== "" ? parseFloat(budgetUsd) : null,
      };
      if (rlRequests !== "") {
        body.rate_limit = { requests: parseInt(rlRequests), window_sec: parseInt(rlWindow) || 60 };
      }
      const res = await api.post<{ token: string }>(`/users/${user.id}/tokens`, body);
      onCreated(res.token);
    } catch (err: any) { setError(err.message); }
    finally { setLoading(false); }
  }

  return (
    <div className={s["modal-overlay"]} onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className={s.modal}>
        <div className={s["modal-header"]}>
          <h2 className={s["modal-title"]}>New Token for {user.email}</h2>
          <button className={s["modal-close"]} onClick={onClose}><CloseIcon /></button>
        </div>
        {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}
        <form onSubmit={handleSubmit}>
          <div className={s["form-group"]}>
            <label className={s["form-label"]}>Gateway *</label>
            <select className={s["form-select"]} value={gatewayId} onChange={(e) => setGatewayId(e.target.value)} required>
              {gateways.map((g) => <option key={g.id} value={g.id}>{g.slug}</option>)}
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
          <div className={s["form-group"]}>
            <label className={s["form-label"]}>Scopes</label>
            <div style={{ display: "flex", gap: 16 }}>
              {["inference", "read", "admin"].map((sc) => (
                <label key={sc} style={{ display: "flex", alignItems: "center", gap: 6, cursor: "pointer" }}>
                  <input type="checkbox" checked={scopes.includes(sc)} onChange={() => toggleScope(sc)} />
                  <span className={s["form-label"]} style={{ margin: 0 }}>{sc}</span>
                </label>
              ))}
            </div>
          </div>
          <div className={s["form-actions"]}>
            <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
            <button type="submit" className={`${s.btn} ${s["btn--primary"]}`} disabled={loading || !gatewayId}>
              {loading ? "Creating…" : "Create Token"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Token reveal modal
// ---------------------------------------------------------------------------

function TokenRevealModal({ token, onClose }: { token: string; onClose: () => void }) {
  const [copied, setCopied] = useState(false);
  function copy() {
    navigator.clipboard.writeText(token);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }
  return (
    <div className={s["modal-overlay"]} onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className={s.modal}>
        <div className={s["modal-header"]}>
          <h2 className={s["modal-title"]}>Token Created</h2>
          <button className={s["modal-close"]} onClick={onClose}><CloseIcon /></button>
        </div>
        <div className={`${s.alert} ${s["alert--warning"]}`} style={{ marginBottom: 12 }}>
          Copy this token now — it will not be shown again.
        </div>
        <div className={s.mono} style={{ background: "var(--bg-secondary)", padding: "10px 14px", borderRadius: 6, wordBreak: "break-all", fontSize: 13, marginBottom: 14 }}>
          {token}
        </div>
        <div className={s["form-actions"]}>
          <button className={`${s.btn} ${s["btn--primary"]}`} onClick={copy}>{copied ? "Copied!" : "Copy"}</button>
          <button className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Done</button>
        </div>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// User detail panel
// ---------------------------------------------------------------------------

function UserDetail({ user: initialUser, onBack, onDeleted, onUpdated }: {
  user: User;
  onBack: () => void;
  onDeleted: () => void;
  onUpdated: (u: User) => void;
}) {
  const [user, setUser] = useState(initialUser);
  const [tenantGateways, setTenantGateways] = useState<Gateway[]>([]);
  const [tokens, setTokens] = useState<AuthToken[]>([]);
  const [accessGateways, setAccessGateways] = useState<{ id: string; slug: string }[]>([]);
  const [loadingTokens, setLoadingTokens] = useState(true);
  const [loadingAccess, setLoadingAccess] = useState(true);
  const [showEdit, setShowEdit] = useState(false);
  const [showToken, setShowToken] = useState(false);
  const [newToken, setNewToken] = useState<string | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [addGwId, setAddGwId] = useState("");

  function loadTokens() {
    setLoadingTokens(true);
    api.get<AuthToken[]>(`/users/${user.id}/tokens`).then(setTokens).finally(() => setLoadingTokens(false));
  }
  function loadAccess() {
    setLoadingAccess(true);
    api.get<{ id: string; slug: string }[]>(`/users/${user.id}/gateways`).then(setAccessGateways).finally(() => setLoadingAccess(false));
  }
  function loadGateways() {
    api.get<Gateway[]>(`/tenants/${user.tenant_id}/gateways`).then(setTenantGateways).catch(() => {});
  }

  useEffect(() => { loadTokens(); loadAccess(); loadGateways(); }, [user.id]);

  async function handleDelete() {
    if (!confirm(`Delete user "${user.email}"? Their tokens will also be revoked.`)) return;
    setDeleting(true);
    try { await api.delete(`/users/${user.id}`); onDeleted(); }
    catch (e: any) { alert(e.message); setDeleting(false); }
  }

  async function revokeToken(tokenId: string) {
    if (!confirm("Revoke this token?")) return;
    await api.delete(`/gateways/${tokens.find((t) => t.id === tokenId)?.gateway_id}/tokens/${tokenId}`);
    loadTokens();
  }

  async function grantGateway() {
    if (!addGwId) return;
    await api.post(`/users/${user.id}/gateways/${addGwId}`, {});
    setAddGwId("");
    loadAccess();
  }

  async function revokeGateway(gwId: string) {
    await api.delete(`/users/${user.id}/gateways/${gwId}`);
    loadAccess();
  }

  function handleSaved() {
    api.get<User[]>(`/tenants/${user.tenant_id}/users`).then((us) => {
      const updated = us.find((u) => u.id === user.id);
      if (updated) { setUser(updated); onUpdated(updated); }
    });
  }

  const roleColor = user.role === "admin" ? s["badge--success"] : user.role === "member" ? s["badge--warning"] : s["badge--neutral"];
  const accessibleIds = new Set(accessGateways.map((g) => g.id));
  const grantableGateways = tenantGateways.filter((g) => !accessibleIds.has(g.id));

  return (
    <>
      {showEdit && <UserModal tenants={[]} user={user} onClose={() => setShowEdit(false)} onSaved={handleSaved} />}
      {showToken && (
        <TokenModal
          user={user}
          gateways={tenantGateways}
          onClose={() => setShowToken(false)}
          onCreated={(t) => { setShowToken(false); setNewToken(t); loadTokens(); }}
        />
      )}
      {newToken && <TokenRevealModal token={newToken} onClose={() => setNewToken(null)} />}

      <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={onBack} style={{ marginBottom: 16 }}>
        ← Users
      </button>

      {/* User info card */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>{user.email}</h2>
          <div style={{ display: "flex", gap: 8 }}>
            <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={() => setShowEdit(true)}>Edit</button>
            <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={handleDelete} disabled={deleting}>
              {deleting ? "Deleting…" : "Delete User"}
            </button>
          </div>
        </div>
        <div className={s["stats-grid"]}>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Email</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`}>{user.email}</div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Name</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`}>{user.name ?? <span style={{ color: "var(--text-secondary)" }}>—</span>}</div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Role</div>
            <div className={s["stat-value"]} style={{ marginTop: 6 }}>
              <span className={`${s.badge} ${roleColor}`}>{user.role}</span>
            </div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Tenant</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`}><span className={s.code}>{user.tenant_slug}</span></div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>User ID</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`} style={{ color: "var(--text-secondary)" }}>{user.id}</div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Created</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`}>{fmtDate(user.created_at)}</div>
          </div>
        </div>
      </div>

      {/* Tokens card */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Tokens</h2>
          <button className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`} onClick={() => setShowToken(true)}>
            + New Token
          </button>
        </div>
        {loadingTokens ? (
          <div className={s.empty}>Loading…</div>
        ) : tokens.length === 0 ? (
          <div className={s.empty}>No tokens yet.</div>
        ) : (
          <div className={s["table-wrapper"]}>
            <table className={s.table}>
              <thead>
                <tr>
                  <th>Label</th>
                  <th>Gateway</th>
                  <th>Scopes</th>
                  <th>Expires</th>
                  <th>Budget</th>
                  <th>Rate Limit</th>
                  <th>Created</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {tokens.map((t) => {
                  const gw = tenantGateways.find((g) => g.id === t.gateway_id);
                  const scopes = typeof t.scopes === "string" ? JSON.parse(t.scopes) : (t.scopes ?? []);
                  const rl = typeof t.rate_limit === "string" ? JSON.parse(t.rate_limit) : t.rate_limit;
                  return (
                    <tr key={t.id}>
                      <td>{t.label ?? <span style={{ color: "var(--text-secondary)" }}>—</span>}</td>
                      <td><span className={s.code}>{gw?.slug ?? t.gateway_id.slice(0, 8)}</span></td>
                      <td>
                        {scopes.length === 0
                          ? <span className={`${s.badge} ${s["badge--neutral"]}`}>all</span>
                          : scopes.map((sc: string) => (
                            <span key={sc} className={`${s.badge} ${s["badge--neutral"]}`} style={{ marginRight: 4 }}>{sc}</span>
                          ))}
                      </td>
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

      {/* Gateway access card (only relevant for member role) */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Gateway Access</h2>
          {user.role === "admin" && (
            <span className={`${s.badge} ${s["badge--success"]}`}>admin — all gateways</span>
          )}
          {user.role === "viewer" && (
            <span className={`${s.badge} ${s["badge--neutral"]}`}>viewer — read-only</span>
          )}
        </div>

        {user.role === "member" && (
          <>
            {/* Grant access */}
            {grantableGateways.length > 0 && (
              <div style={{ display: "flex", gap: 8, marginBottom: 16 }}>
                <select className={s["form-select"]} value={addGwId} onChange={(e) => setAddGwId(e.target.value)} style={{ flex: 1 }}>
                  <option value="">— select gateway to grant —</option>
                  {grantableGateways.map((g) => <option key={g.id} value={g.id}>{g.slug}</option>)}
                </select>
                <button className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`} onClick={grantGateway} disabled={!addGwId}>
                  Grant
                </button>
              </div>
            )}

            {loadingAccess ? (
              <div className={s.empty}>Loading…</div>
            ) : accessGateways.length === 0 ? (
              <div className={s.empty}>No gateways granted. Use the selector above to grant access.</div>
            ) : (
              <div className={s["table-wrapper"]}>
                <table className={s.table}>
                  <thead><tr><th>Gateway</th><th>ID</th><th></th></tr></thead>
                  <tbody>
                    {accessGateways.map((g) => (
                      <tr key={g.id}>
                        <td><span className={s.code}>{g.slug}</span></td>
                        <td className={s.mono} style={{ fontSize: 11, color: "var(--text-secondary)" }}>{g.id}</td>
                        <td>
                          <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={() => revokeGateway(g.id)}>Revoke</button>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </>
        )}

        {user.role !== "member" && (
          <div className={s.empty} style={{ paddingTop: 8 }}>
            {user.role === "admin"
              ? "Admin users have access to all gateways in their tenant."
              : "Viewer users cannot make inference requests regardless of gateway access."}
          </div>
        )}
      </div>
    </>
  );
}

// ---------------------------------------------------------------------------
// Main page
// ---------------------------------------------------------------------------

export default function Users() {
  useDocumentTitle("Users");
  const { userId } = useParams<{ userId?: string }>();
  const navigate = useNavigate();
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [users, setUsers] = useState<User[]>([]);
  const [filterTenantId, setFilterTenantId] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showCreate, setShowCreate] = useState(false);

  function loadUsers(tenantId?: string) {
    setLoading(true);
    if (!tenantId) {
      // load all users across tenants
      api.get<Tenant[]>("/tenants").then(async (ts) => {
        const all: User[] = [];
        for (const t of ts) {
          const us = await api.get<User[]>(`/tenants/${t.id}/users`).catch(() => [] as User[]);
          all.push(...us);
        }
        setUsers(all);
      }).catch((e) => setError(e.message)).finally(() => setLoading(false));
    } else {
      api.get<User[]>(`/tenants/${tenantId}/users`).then(setUsers).catch((e) => setError(e.message)).finally(() => setLoading(false));
    }
  }

  useEffect(() => {
    api.get<Tenant[]>("/tenants").then(setTenants);
    loadUsers();
  }, []);

  useEffect(() => {
    loadUsers(filterTenantId || undefined);
  }, [filterTenantId]);

  const selected = users.find((u) => u.id === userId) ?? null;

  if (userId) {
    if (loading) return <main className={s.page}><div className={s.empty}>Loading…</div></main>;
    if (!selected) return <Navigate to="/users" replace />;
    return (
      <main className={s.page}>
        <h1 className={s["page-title"]} style={{ marginBottom: 20 }}>{selected.email}</h1>
        <UserDetail
          key={userId}
          user={selected}
          onBack={() => navigate("/users")}
          onDeleted={() => { navigate("/users"); loadUsers(filterTenantId || undefined); }}
          onUpdated={(u) => setUsers((us) => us.map((x) => x.id === u.id ? u : x))}
        />
      </main>
    );
  }

  const roleColor = (role: User["role"]) =>
    role === "admin" ? s["badge--success"] : role === "member" ? s["badge--warning"] : s["badge--neutral"];

  return (
    <main className={s.page}>
      {showCreate && (
        <UserModal
          tenants={tenants}
          onClose={() => setShowCreate(false)}
          onSaved={() => loadUsers(filterTenantId || undefined)}
        />
      )}

      <div className={s["page-header"]}>
        <div>
          <h1 className={s["page-title"]}>Users</h1>
          <p className={s["page-subtitle"]}>{users.length} user{users.length !== 1 ? "s" : ""}</p>
        </div>
        <div style={{ display: "flex", gap: 8 }}>
          <select
            className={s["form-select"]}
            value={filterTenantId}
            onChange={(e) => setFilterTenantId(e.target.value)}
            style={{ minWidth: 160 }}
          >
            <option value="">All tenants</option>
            {tenants.map((t) => <option key={t.id} value={t.id}>{t.slug}</option>)}
          </select>
          <button className={`${s.btn} ${s["btn--primary"]}`} onClick={() => setShowCreate(true)} disabled={tenants.length === 0}>
            + New User
          </button>
        </div>
      </div>

      {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}

      {loading ? (
        <div className={s.empty}>Loading…</div>
      ) : users.length === 0 ? (
        <div className={s.card}>
          <div className={s.empty}>No users yet. Create the first user to get started.</div>
        </div>
      ) : (
        <div className={s["table-wrapper"]}>
          <table className={s.table}>
            <thead>
              <tr>
                <th>Email</th>
                <th>Name</th>
                <th>Role</th>
                <th>Tenant</th>
                <th>Created</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {users.map((u) => (
                <tr key={u.id} style={{ cursor: "pointer" }} onClick={() => navigate(`/users/${u.id}`)}>
                  <td>{u.email}</td>
                  <td style={{ color: u.name ? undefined : "var(--text-secondary)" }}>{u.name ?? "—"}</td>
                  <td><span className={`${s.badge} ${roleColor(u.role)}`}>{u.role}</span></td>
                  <td><span className={s.code}>{u.tenant_slug}</span></td>
                  <td className={s.mono}>{fmtDate(u.created_at)}</td>
                  <td>
                    <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={(e) => { e.stopPropagation(); navigate(`/users/${u.id}`); }}>
                      Open →
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </main>
  );
}
