import { useEffect, useState } from "react";
import { useNavigate, useParams, Navigate } from "react-router-dom";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { useAuth } from "src/common/contexts/AuthContext";
import { api } from "src/api/client";
import { User, Tenant, Gateway, AuthToken } from "src/api/types";
import { fmtDate } from "src/common/utils/date";
import { DocLink } from "src/common/components/DocLink";
import { Modal } from "src/common/components/Modal";
import { TokenRevealModal } from "src/common/components/TokenRevealModal";
import { StatusBadge, roleVariant } from "src/common/components/StatusBadge";
import s from "src/common/components/layout/Layout.module.scss";

// ---------------------------------------------------------------------------
// User modal (create / edit)
// ---------------------------------------------------------------------------

function UserModal({ tenants, tenantId: defaultTenantId, user, onClose, onSaved }: {
  tenants: Tenant[];
  tenantId?: string;
  user?: User;
  onClose: () => void;
  onSaved: () => void;
}) {
  const { user: me } = useAuth();
  const isEdit = !!user;
  const [tenantId, setTenantId] = useState(user?.tenant_id ?? defaultTenantId ?? tenants[0]?.id ?? "");
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
        const payload: Record<string, unknown> = { email, name: name || null, role };
        if (canChangeTenant) payload.tenant_id = tenantId;
        await api.patch(`/users/${user!.id}`, payload);
      } else {
        await api.post(`/tenants/${tenantId}/users`, { email, name: name || null, role });
      }
      onSaved(); onClose();
    } catch (err: any) { setError(err.message); }
    finally { setLoading(false); }
  }

  const canChangeTenant = me?.role === "admin";
  const canAssignTenantAdmin = me?.role === "admin" || me?.role === "tenant_admin";
  const availableRoles: Array<{ value: User["role"]; label: string }> = [
    ...(canAssignTenantAdmin ? [{ value: "tenant_admin" as User["role"], label: "tenant admin — manages tenant users & settings" }] : []),
    { value: "member", label: "member — full tenant access" },
    { value: "viewer", label: "viewer — read-only, no inference" },
    ...(me?.role === "admin" ? [{ value: "admin" as User["role"], label: "admin — platform superadmin" }] : []),
  ];

  return (
    <Modal title={isEdit ? `Edit: ${user!.email}` : "New User"} onClose={onClose} error={error}>
      <form onSubmit={handleSubmit}>
          <div className={s["form-group"]}>
            <label className={s["form-label"]}>Tenant *</label>
            {canChangeTenant ? (
              <select className={s["form-select"]} value={tenantId} onChange={(e) => setTenantId(e.target.value)} required>
                {tenants.map((t) => <option key={t.id} value={t.id}>{t.slug}</option>)}
              </select>
            ) : (
              <input className={s["form-input"]} value={tenants.find((t) => t.id === tenantId)?.slug ?? tenantId} readOnly />
            )}
          </div>
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
    </Modal>
  );
}

// ---------------------------------------------------------------------------
// Token modal (create token for a user)
// ---------------------------------------------------------------------------

function TokenModal({ user, gateways, onClose, onCreated }: {
  user: User;
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
    <Modal
      title={<><span>New Token for {user.email}</span><DocLink path="/api-reference/users-tokens/" label="Token docs" /></>}
      onClose={onClose}
      error={error}
    >
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
    </Modal>
  );
}

// ---------------------------------------------------------------------------
// User detail panel
// ---------------------------------------------------------------------------

function UserDetail({ user: initialUser, tenants, onBack, onDeleted, onUpdated }: {
  user: User;
  tenants: Tenant[];
  onBack: () => void;
  onDeleted: () => void;
  onUpdated: (u: User) => void;
}) {
  const { user: me } = useAuth();
  const [user, setUser] = useState(initialUser);
  const [tenantGateways, setTenantGateways] = useState<(Gateway & { tenant_slug: string })[]>([]);
  const [tokens, setTokens] = useState<AuthToken[]>([]);
  const [loadingTokens, setLoadingTokens] = useState(true);
  const [showEdit, setShowEdit] = useState(false);
  const [showToken, setShowToken] = useState(false);
  const [newToken, setNewToken] = useState<string | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [inviteSent, setInviteSent] = useState(false);
  const [inviteError, setInviteError] = useState<string | null>(null);

  function loadTokens() {
    setLoadingTokens(true);
    api.get<AuthToken[]>(`/users/${user.id}/tokens`).then(setTokens).finally(() => setLoadingTokens(false));
  }

  function loadGateways() {
    // GET /tenants auto-filters to the caller's tenant for non-admin users
    api.get<Tenant[]>(`/tenants`)
      .then(async (tenants) => {
        const all: (Gateway & { tenant_slug: string })[] = [];
        for (const t of tenants) {
          const gs = await api.get<Gateway[]>(`/tenants/${t.id}/gateways`).catch(() => [] as Gateway[]);
          all.push(...gs.map((g) => ({ ...g, tenant_slug: t.slug })));
        }
        setTenantGateways(all);
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

  async function handleResendInvite() {
    setInviteError(null);
    try {
      await api.post(`/users/${user.id}/resend-invite`, {});
      setInviteSent(true);
      setTimeout(() => setInviteSent(false), 3000);
    } catch (e: any) { setInviteError(e.message); }
  }

  async function revokeToken(tokenId: string) {
    if (!confirm("Revoke this token?")) return;
    try {
      await api.delete(`/gateways/${tokens.find((t) => t.id === tokenId)?.gateway_id}/tokens/${tokenId}`);
      loadTokens();
    } catch (e: any) { alert(e.message); }
  }

  function handleSaved() {
    // Fetch the user by ID directly so that tenant changes are reflected
    // (fetching via old tenant_id would miss the user after a tenant move).
    api.get<User>(`/users/${user.id}`).then((updated) => {
      setUser(updated);
      onUpdated(updated);
    }).catch(() => {});
  }

  const canEdit = me?.role === "admin" || me?.tenant_id === user.tenant_id;

  return (
    <>
      {showEdit && <UserModal tenants={tenants} user={user} onClose={() => setShowEdit(false)} onSaved={handleSaved} />}
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
          {canEdit && (
            <div style={{ display: "flex", gap: 8 }}>
              <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={handleResendInvite} disabled={inviteSent}>
                {inviteSent ? "Invite Sent ✓" : "Resend Invite"}
              </button>
              <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={() => setShowEdit(true)}>Edit</button>
              <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={handleDelete} disabled={deleting}>
                {deleting ? "Deleting…" : "Delete User"}
              </button>
            </div>
          )}
          {inviteError && <div className={`${s.alert} ${s["alert--error"]}`} style={{ marginTop: 8 }}>{inviteError}</div>}
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
              <StatusBadge value={user.role} variant={roleVariant(user.role)} />
            </div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Tenant</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`}>
              {user.tenant_id
                ? <span className={s.code}>{tenants.find((t) => t.id === user.tenant_id)?.slug ?? user.tenant_id}</span>
                : <span style={{ color: "var(--text-secondary)" }}>—</span>}
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
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Last Login</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`}>
              {user.last_login_at
                ? fmtDate(user.last_login_at)
                : <span style={{ color: "var(--text-secondary)" }}>never</span>}
            </div>
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
                    const gw = tenantGateways.find((g) => g.id === t.gateway_id);
                    const scopes = typeof t.scopes === "string" ? JSON.parse(t.scopes) : (t.scopes ?? []);
                    const rl = typeof t.rate_limit === "string" ? JSON.parse(t.rate_limit) : t.rate_limit;
                    return (
                      <tr key={t.id}>
                        <td>{t.label ?? <span style={{ color: "var(--text-secondary)" }}>—</span>}</td>
                        <td><span className={s.code}>{gw ? `${gw.tenant_slug}/${gw.slug}` : t.gateway_id.slice(0, 8)}</span></td>
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

  if (me && me.role !== "admin" && me.role !== "tenant_admin") {
    return <Navigate to="/" replace />;
  }
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [users, setUsers] = useState<User[]>([]);
  const [filterTenantId, setFilterTenantId] = useState("");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showCreate, setShowCreate] = useState(false);

  function loadUsers(tenantId?: string) {
    setLoading(true);
    if (!tenantId) {
      const targetTenants = me?.role === "admin" ? tenants : tenants.filter((t) => t.id === me?.tenant_id);
      if (targetTenants.length === 0) {
        setUsers([]);
        setLoading(false);
        return;
      }
      const tenantFetches = targetTenants.map((t) =>
        api.get<User[]>(`/tenants/${t.id}/users`).catch(() => [] as User[])
      );
      const globalFetch = me?.role === "admin"
        ? api.get<User[]>("/users").catch(() => [] as User[])
        : Promise.resolve([] as User[]);
      Promise.all([...tenantFetches, globalFetch]).then((results) => {
        const all = results.flat();
        // deduplicate by id (admins may appear in multiple lists)
        setUsers(all.filter((u, i, arr) => arr.findIndex((x) => x.id === u.id) === i));
      }).catch((e) => setError(e.message)).finally(() => setLoading(false));
    } else {
      api.get<User[]>(`/tenants/${tenantId}/users`)
        .then(setUsers).catch((e) => setError(e.message)).finally(() => setLoading(false));
    }
  }

  useEffect(() => {
    api.get<Tenant[]>("/tenants").then(setTenants).catch(() => {});
  }, []);

  useEffect(() => {
    // Wait for both auth (me) and tenants before loading users.
    // Without me in deps, loadUsers() would run with me=null if /tenants
    // responds before /admin/auth/me, causing it to bail with an empty list.
    if (me && tenants.length > 0) loadUsers(filterTenantId || undefined);
  }, [me, tenants, filterTenantId]);

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
          tenants={tenants}
          onBack={() => { loadUsers(filterTenantId || undefined); navigate("/users"); }}
          onDeleted={() => { navigate("/users"); loadUsers(filterTenantId || undefined); }}
          onUpdated={(u) => setUsers((us) => us.map((x) => x.id === u.id ? u : x))}
        />
      </main>
    );
  }


  return (
    <main className={s.page}>
      {showCreate && (
        <UserModal
          tenants={tenants}
          tenantId={me?.tenant_id ?? tenants[0]?.id}
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
          {me?.role === "admin" && (
            <select
              className={s["form-select"]}
              value={filterTenantId}
              onChange={(e) => setFilterTenantId(e.target.value)}
              style={{ minWidth: 160 }}
            >
              <option value="">All tenants</option>
              {tenants.map((t) => <option key={t.id} value={t.id}>{t.slug}</option>)}
            </select>
          )}
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
                <th>Last Login</th>
                <th>Created</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {[...users].sort((a, b) => a.email.localeCompare(b.email)).map((u) => (
                <tr key={u.id} style={{ cursor: "pointer" }} onClick={() => navigate(`/users/${u.id}`)}>
                  <td>{u.email}</td>
                  <td style={{ color: u.name ? undefined : "var(--text-secondary)" }}>{u.name ?? "—"}</td>
                  <td><StatusBadge value={u.role} variant={roleVariant(u.role)} /></td>
                  <td><span className={s.code}>{tenants.find((t) => t.id === u.tenant_id)?.slug ?? "—"}</span></td>
                  <td className={s.mono} style={{ fontSize: 12 }}>
                    {u.last_login_at
                      ? fmtDate(u.last_login_at)
                      : <span style={{ color: "var(--text-secondary)" }}>never</span>}
                  </td>
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
