import { useEffect, useState } from "react";
import { useNavigate, useParams, Navigate } from "react-router-dom";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { useAuth } from "src/common/contexts/AuthContext";
import { api } from "src/api/client";
import { User, Organization, Gateway, AuthToken } from "src/api/types";
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

function UserModal({ orgs, user, onClose, onSaved }: {
  orgs: Organization[];
  user?: User;
  onClose: () => void;
  onSaved: () => void;
}) {
  const { user: me } = useAuth();
  const isEdit = !!user;
  // For non-platform-admin, lock org to their own
  const defaultOrgId = me?.role !== "admin" && me?.org_id
    ? me.org_id
    : (user?.organization_id ?? orgs[0]?.id ?? "");
  const [orgId, setOrgId] = useState(defaultOrgId);
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
        await api.post(`/organizations/${orgId}/users`, { email, name: name || null, role });
      }
      onSaved(); onClose();
    } catch (err: any) { setError(err.message); }
    finally { setLoading(false); }
  }

  const canChangeOrg = !isEdit && me?.role === "admin";
  const availableRoles: Array<{ value: User["role"]; label: string }> = [
    { value: "member", label: "member — full org access" },
    { value: "viewer", label: "viewer — read-only, no inference" },
    ...(me?.role === "admin" ? [{ value: "admin" as User["role"], label: "admin — platform superadmin" }] : []),
  ];

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
              <label className={s["form-label"]}>Organization *</label>
              {canChangeOrg ? (
                <select className={s["form-select"]} value={orgId} onChange={(e) => setOrgId(e.target.value)} required>
                  {orgs.map((o) => <option key={o.id} value={o.id}>{o.slug}</option>)}
                </select>
              ) : (
                <input className={s["form-input"]} value={orgs.find((o) => o.id === orgId)?.slug ?? orgId} readOnly />
              )}
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
                {availableRoles.map((r) => <option key={r.value} value={r.value}>{r.label}</option>)}
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

function UserDetail({ user: initialUser, orgs, onBack, onDeleted, onUpdated }: {
  user: User;
  orgs: Organization[];
  onBack: () => void;
  onDeleted: () => void;
  onUpdated: (u: User) => void;
}) {
  const { user: me } = useAuth();
  const [user, setUser] = useState(initialUser);
  const [orgGateways, setOrgGateways] = useState<Gateway[]>([]);
  const [tokens, setTokens] = useState<AuthToken[]>([]);
  const [loadingTokens, setLoadingTokens] = useState(true);
  const [showEdit, setShowEdit] = useState(false);
  const [showToken, setShowToken] = useState(false);
  const [newToken, setNewToken] = useState<string | null>(null);
  const [deleting, setDeleting] = useState(false);

  function loadTokens() {
    setLoadingTokens(true);
    api.get<AuthToken[]>(`/users/${user.id}/tokens`).then(setTokens).finally(() => setLoadingTokens(false));
  }

  function loadGateways() {
    // GET /tenants auto-filters to the caller's org for non-admin users
    api.get<{ id: string }[]>(`/tenants`)
      .then(async (tenants) => {
        const all: Gateway[] = [];
        for (const t of tenants) {
          const gs = await api.get<Gateway[]>(`/tenants/${t.id}/gateways`).catch(() => [] as Gateway[]);
          all.push(...gs);
        }
        setOrgGateways(all);
      })
      .catch(() => {});
  }

  useEffect(() => { loadTokens(); loadGateways(); }, [user.id]);

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

  function handleSaved() {
    if (!user.organization_id) return;
    api.get<User[]>(`/organizations/${user.organization_id}/users`).then((us) => {
      const updated = us.find((u) => u.id === user.id);
      if (updated) { setUser(updated); onUpdated(updated); }
    });
  }

  const canEdit = me?.role === "admin" || me?.org_id === user.organization_id;
  const roleColor = user.role === "admin" ? s["badge--success"] : user.role === "member" ? s["badge--warning"] : s["badge--neutral"];

  return (
    <>
      {showEdit && <UserModal orgs={orgs} user={user} onClose={() => setShowEdit(false)} onSaved={handleSaved} />}
      {showToken && (
        <TokenModal
          user={user}
          gateways={orgGateways}
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
          {canEdit && (
            <div style={{ display: "flex", gap: 8 }}>
              <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={() => setShowEdit(true)}>Edit</button>
              <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={handleDelete} disabled={deleting}>
                {deleting ? "Deleting…" : "Delete User"}
              </button>
            </div>
          )}
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
            <div className={s["stat-label"]}>Organization</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`}>
              {user.org_slug ? <span className={s.code}>{user.org_slug}</span> : <span style={{ color: "var(--text-secondary)" }}>—</span>}
            </div>
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
          {user.role !== "viewer" && (
            <button className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`} onClick={() => setShowToken(true)}>
              + New Token
            </button>
          )}
        </div>
        {user.role === "viewer" && (
          <div className={s.empty} style={{ paddingTop: 8 }}>Viewer users cannot make inference requests.</div>
        )}
        {user.role !== "viewer" && (
          loadingTokens ? (
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
                    const gw = orgGateways.find((g) => g.id === t.gateway_id);
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
          )
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
  const { user: me } = useAuth();
  const [orgs, setOrgs] = useState<Organization[]>([]);
  const [users, setUsers] = useState<User[]>([]);
  const [filterOrgId, setFilterOrgId] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showCreate, setShowCreate] = useState(false);

  function loadUsers(orgId?: string) {
    setLoading(true);
    if (!orgId) {
      // Load users from all accessible orgs
      const targetOrgs = me?.role === "admin" ? orgs : orgs.filter((o) => o.id === me?.org_id);
      if (targetOrgs.length === 0) {
        setUsers([]);
        setLoading(false);
        return;
      }
      Promise.all(targetOrgs.map((o) =>
        api.get<User[]>(`/organizations/${o.id}/users`).catch(() => [] as User[])
      )).then((results) => {
        setUsers(results.flat());
      }).catch((e) => setError(e.message)).finally(() => setLoading(false));
    } else {
      api.get<User[]>(`/organizations/${orgId}/users`)
        .then(setUsers).catch((e) => setError(e.message)).finally(() => setLoading(false));
    }
  }

  useEffect(() => {
    const loadOrgs = me?.role === "admin"
      ? api.get<Organization[]>("/organizations")
      : me?.org_id
        ? api.get<Organization>(`/organizations/${me.org_id}`).then((o) => [o]).catch(() => [] as Organization[])
        : Promise.resolve([] as Organization[]);

    loadOrgs.then(setOrgs).catch(() => {});
  }, [me]);

  useEffect(() => {
    if (orgs.length > 0) loadUsers(filterOrgId || undefined);
  }, [orgs, filterOrgId]);

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
          orgs={orgs}
          onBack={() => navigate("/users")}
          onDeleted={() => { navigate("/users"); loadUsers(filterOrgId || undefined); }}
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
          orgs={orgs}
          onClose={() => setShowCreate(false)}
          onSaved={() => loadUsers(filterOrgId || undefined)}
        />
      )}

      <div className={s["page-header"]}>
        <div>
          <h1 className={s["page-title"]}>Users</h1>
          <p className={s["page-subtitle"]}>{users.length} user{users.length !== 1 ? "s" : ""}</p>
        </div>
        <div style={{ display: "flex", gap: 8 }}>
          {me?.role === "admin" && (
            <select
              className={s["form-select"]}
              value={filterOrgId}
              onChange={(e) => setFilterOrgId(e.target.value)}
              style={{ minWidth: 160 }}
            >
              <option value="">All organizations</option>
              {orgs.map((o) => <option key={o.id} value={o.id}>{o.slug}</option>)}
            </select>
          )}
          <button className={`${s.btn} ${s["btn--primary"]}`} onClick={() => setShowCreate(true)} disabled={orgs.length === 0}>
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
                <th>Organization</th>
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
                  <td><span className={s.code}>{u.org_slug ?? "—"}</span></td>
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
