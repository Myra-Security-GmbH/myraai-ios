import { useEffect, useState } from "react";
import { useNavigate, useParams, Navigate } from "react-router-dom";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { useAuth } from "src/common/contexts/AuthContext";
import { api } from "src/api/client";
import { Tenant, Gateway, BudgetPeriod, TenantPreset, ModelPrice, ProviderMeta } from "src/api/types";
import ModelPicker from "src/common/components/ModelPicker/ModelPicker";
import { fmtDate } from "src/common/utils/date";
import { fmtCost } from "src/common/utils/format";
import { Modal } from "src/common/components/Modal";
import { StatusBadge, planVariant } from "src/common/components/StatusBadge";
import s from "src/common/components/layout/Layout.module.scss";

// ---------------------------------------------------------------------------
// Modals
// ---------------------------------------------------------------------------

function TenantModal({ tenant, onClose, onSaved }: {
  tenant?: Tenant; onClose: () => void; onSaved: () => void;
}) {
  const { user } = useAuth();
  const isEdit = !!tenant;
  const [slug, setSlug] = useState(tenant?.slug ?? "");
  const [plan, setPlan] = useState(tenant?.plan ?? "standard");
  const [budget, setBudget] = useState(tenant?.budget_usd != null ? String(tenant.budget_usd) : "");
  const [budgetPeriod, setBudgetPeriod] = useState<BudgetPeriod>(tenant?.budget_period ?? "monthly");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true); setError(null);
    try {
      const budgetVal = budget !== "" ? parseFloat(budget) : null;
      if (isEdit) {
        await api.patch(`/tenants/${tenant!.id}`, {
          plan, budget_usd: budgetVal, budget_period: budgetPeriod,
        });
      } else {
        await api.post("/tenants", {
          slug, plan, budget_usd: budgetVal, budget_period: budgetPeriod,
        });
      }
      onSaved(); onClose();
    } catch (err: any) { setError(err.message); }
    finally { setLoading(false); }
  }

  return (
    <Modal title={isEdit ? `Edit: ${tenant!.slug}` : "New Tenant"} onClose={onClose} error={error}>
      <form onSubmit={handleSubmit}>
          {!isEdit && (
            <div className={s["form-group"]}>
              <label htmlFor="slug" className={s["form-label"]}>Slug *</label>
              <input id="slug" className={s["form-input"]} value={slug} onChange={(e) => setSlug(e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ""))} placeholder="my-company" required />
              <p className={s["form-hint"]}>Lowercase letters, numbers, and hyphens only.</p>
            </div>
          )}
          <div className={s["form-row"]}>
            <div className={s["form-group"]}>
              <label htmlFor="plan" className={s["form-label"]}>Plan</label>
              <select id="plan" className={s["form-select"]} value={plan} onChange={(e) => setPlan(e.target.value)}>
                <option value="free">Free</option>
                <option value="standard">Standard</option>
                <option value="enterprise">Enterprise</option>
              </select>
            </div>
            <div className={s["form-group"]}>
              <label htmlFor="budget" className={s["form-label"]}>Budget (USD)</label>
              <input id="budget" className={s["form-input"]} type="number" min="0" step="0.01" value={budget} onChange={(e) => setBudget(e.target.value)} placeholder="unlimited" />
            </div>
            <div className={s["form-group"]}>
              <label htmlFor="budgetperiod" className={s["form-label"]}>Budget Period</label>
              <select id="budgetperiod" className={s["form-select"]} value={budgetPeriod} onChange={(e) => setBudgetPeriod(e.target.value as BudgetPeriod)} disabled={budget === ""}>
                <option value="monthly">Monthly</option>
                <option value="daily">Daily</option>
                <option value="total">Lifetime</option>
              </select>
            </div>
          </div>
          <div className={s["form-actions"]}>
            <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
            <button type="submit" className={`${s.btn} ${s["btn--primary"]}`} disabled={loading}>
              {loading ? (isEdit ? "Saving…" : "Creating…") : (isEdit ? "Save Changes" : "Create Tenant")}
            </button>
          </div>
        </form>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
// PresetModal — add or edit a single chat preset
// ---------------------------------------------------------------------------

function PresetModal({ preset, gateways, onClose, onSaved }: {
  preset?: TenantPreset;
  gateways: Gateway[];
  onClose: () => void;
  onSaved: (p: TenantPreset) => void;
}) {
  const isEdit = !!preset;
  const [name, setName]           = useState(preset?.name       ?? "");
  const [gatewayId, setGatewayId] = useState(preset?.gateway_id ?? (gateways[0]?.id ?? ""));
  const [model, setModel]         = useState(preset?.model       ?? "");
  const [provider, setProvider]   = useState(preset?.provider    ?? "");
  const [models, setModels]       = useState<ModelPrice[]>([]);
  const [providerMeta, setProviderMeta] = useState<ProviderMeta[]>([]);
  const [error, setError]         = useState<string | null>(null);

  useEffect(() => {
    api.get<ModelPrice[]>("/models").then(setModels).catch(() => {});
    api.get<ProviderMeta[]>("/providers").then(setProviderMeta).catch(() => {});
  }, []);

  const selectedGateway = gateways.find((g) => g.id === gatewayId);
  const configuredProviders = new Set<string>(
    ((selectedGateway as any)?.configured_providers ?? []) as string[]
  );
  const freeProviders = new Set(providerMeta.filter((p) => !p.requires_key).map((p) => p.name));
  const runnableProviders = new Set<string>([...freeProviders, ...configuredProviders]);

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!name.trim())      { setError("Name is required"); return; }
    if (!gatewayId)        { setError("Gateway is required"); return; }
    if (!model.trim())     { setError("Model is required"); return; }
    if (!provider.trim())  { setError("Select a model from the picker"); return; }
    onSaved({
      id:         preset?.id ?? crypto.randomUUID(),
      name:       name.trim(),
      gateway_id: gatewayId,
      provider:   provider.trim(),
      model:      model.trim(),
    });
    onClose();
  }

  return (
    <Modal title={isEdit ? `Edit preset: ${preset!.name}` : "Add Chat Preset"} onClose={onClose} error={error}>
      <form onSubmit={handleSubmit}>
        <div className={s["form-group"]}>
          <label className={s["form-label"]}>Name *</label>
          <input className={s["form-input"]} value={name} onChange={(e) => setName(e.target.value)}
            placeholder="e.g. Safe PII" required />
          <p className={s["form-hint"]}>Shown to member users as the mode label.</p>
        </div>
        <div className={s["form-group"]}>
          <label className={s["form-label"]}>Gateway *</label>
          <select className={s["form-select"]} value={gatewayId}
            onChange={(e) => { setGatewayId(e.target.value); setModel(""); setProvider(""); }} required>
            {gateways.map((g) => (
              <option key={g.id} value={g.id}>{g.slug}</option>
            ))}
          </select>
        </div>
        <div className={s["form-group"]}>
          <label className={s["form-label"]}>Model *</label>
          <ModelPicker
            models={models}
            value={model}
            onChange={setModel}
            onChangeEntry={(entry) => { setModel(entry.model); setProvider(entry.provider); }}
            runnableProviders={runnableProviders}
          />
          {provider && <p className={s["form-hint"]}>Provider: <strong>{provider}</strong></p>}
        </div>
        <div className={s["form-actions"]}>
          <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
          <button type="submit" className={`${s.btn} ${s["btn--primary"]}`}>
            {isEdit ? "Save Changes" : "Add Preset"}
          </button>
        </div>
      </form>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
// Tenant detail view
// ---------------------------------------------------------------------------

function TenantDetail({ tenant: initialTenant, onBack, onDeleted, onUpdated }: {
  tenant: Tenant; onBack: () => void; onDeleted: () => void; onUpdated: (t: Tenant) => void;
}) {
  const { user: me } = useAuth();
  const [tenant, setTenant] = useState(initialTenant);
  const [gateways, setGateways] = useState<Gateway[]>([]);
  const [loadingGateways, setLoadingGateways] = useState(true);
  const [showEdit, setShowEdit] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [editingPreset, setEditingPreset] = useState<TenantPreset | null | "new">(null);
  const [savingPresets, setSavingPresets] = useState(false);
  const navigate = useNavigate();
  const canEditPresets = me?.role === "admin" || me?.role === "tenant_admin";

  function loadGateways() {
    setLoadingGateways(true);
    api.get<Gateway[]>(`/tenants/${tenant.id}/gateways`)
      .then(setGateways)
      .finally(() => setLoadingGateways(false));
  }

  useEffect(() => { loadGateways(); }, [tenant.id]);

  async function handleDelete() {
    if (!confirm(`Delete tenant "${tenant.slug}"? This will also delete all their gateways, keys, and tokens.`)) return;
    setDeleting(true);
    try {
      await api.delete(`/tenants/${tenant.id}`);
      onDeleted();
    } catch (e: any) {
      alert(e.message);
      setDeleting(false);
    }
  }

  function handleSaved() {
    api.get<Tenant[]>("/tenants").then((ts) => {
      const updated = ts.find((t) => t.id === tenant.id);
      if (updated) { setTenant(updated); onUpdated(updated); }
    });
  }

  async function savePresets(presets: TenantPreset[]) {
    setSavingPresets(true);
    try {
      await api.patch(`/tenants/${tenant.id}`, { chat_presets: presets });
      const updated = { ...tenant, chat_presets: presets };
      setTenant(updated);
      onUpdated(updated);
    } catch (e: any) {
      alert(e.message);
    } finally {
      setSavingPresets(false);
    }
  }

  function handlePresetSaved(p: TenantPreset) {
    const current = tenant.chat_presets ?? [];
    const exists = current.find((x) => x.id === p.id);
    const next = exists ? current.map((x) => x.id === p.id ? p : x) : [...current, p];
    savePresets(next);
  }

  function handlePresetDelete(id: string) {
    if (!confirm("Remove this preset?")) return;
    savePresets((tenant.chat_presets ?? []).filter((p) => p.id !== id));
  }


  return (
    <>
      {showEdit && <TenantModal tenant={tenant} onClose={() => setShowEdit(false)} onSaved={handleSaved} />}
      {editingPreset !== null && (
        <PresetModal
          preset={editingPreset === "new" ? undefined : editingPreset}
          gateways={gateways}
          onClose={() => setEditingPreset(null)}
          onSaved={handlePresetSaved}
        />
      )}

      <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={onBack} style={{ marginBottom: 16 }}>
        ← Tenants
      </button>

      {/* Config card */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Tenant: <span className={s.code}>{tenant.slug}</span></h2>
          <div style={{ display: "flex", gap: 8 }}>
            <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={() => setShowEdit(true)}>
              Edit
            </button>
            <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={handleDelete} disabled={deleting}>
              {deleting ? "Deleting…" : "Delete Tenant"}
            </button>
          </div>
        </div>

        <div className={s["stats-grid"]}>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Slug</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`}><span className={s.code}>{tenant.slug}</span></div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Plan</div>
            <div className={s["stat-value"]} style={{ marginTop: 6 }}>
              <StatusBadge value={tenant.plan} variant={planVariant(tenant.plan)} />
            </div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Budget Limit</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`}>
              {tenant.budget_usd != null
                ? <>{fmtCost(tenant.budget_usd)} <span style={{ color: "var(--text-secondary)", fontSize: "0.75rem" }}>/ {tenant.budget_period ?? "monthly"}</span></>
                : <span style={{ color: "var(--text-secondary)" }}>unlimited</span>}
            </div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Gateways</div>
            <div className={s["stat-value"]}>{gateways.length}</div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Tenant ID</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`} style={{ color: "var(--text-secondary)" }}>{tenant.id}</div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Created</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`}>{fmtDate(tenant.created_at)}</div>
          </div>
        </div>
      </div>

      {/* Gateways card */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Gateways</h2>
          <button
            className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
            onClick={() => navigate(`/tenants/${tenant.id}/gateways`)}
          >
            All Gateways →
          </button>
        </div>

        {loadingGateways ? (
          <div className={s.empty}>Loading…</div>
        ) : gateways.length === 0 ? (
          <div className={s.empty}>No gateways yet. Click "All Gateways" to create one.</div>
        ) : (
          <div className={s["table-wrapper"]}>
            <table className={s.table}>
              <thead>
                <tr>
                  <th>Slug</th>
                  <th>Auth</th>
                  <th>Budget</th>
                  <th>Cache TTL</th>
                  <th>Created</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                {gateways.map((g) => (
                  <tr key={g.id} style={{ cursor: "pointer" }} onClick={() => navigate(`/tenants/${tenant.id}/gateways/${g.id}`)}>
                    <td><span className={s.code}>{g.slug}</span></td>
                    <td>
                      <span className={`${s.badge} ${g.config.auth_required !== false ? s["badge--success"] : s["badge--neutral"]}`}>
                        {g.config.auth_required !== false ? "required" : "open"}
                      </span>
                    </td>
                    <td>{fmtCost(g.config.budget_usd)}</td>
                    <td>{g.config.cache_ttl ?? 0}s</td>
                    <td className={s.mono}>{fmtDate(g.created_at)}</td>
                    <td>
                      <button
                        className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
                        onClick={(e) => { e.stopPropagation(); navigate(`/tenants/${tenant.id}/gateways/${g.id}`); }}
                      >
                        Open →
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Chat Presets card — visible to admin and tenant_admin only */}
      {canEditPresets && (
        <div className={s.card}>
          <div className={s["card-header"]}>
            <h2 className={s["card-title"]}>Chat Presets</h2>
            <button
              className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`}
              onClick={() => setEditingPreset("new")}
              disabled={savingPresets || loadingGateways}
            >
              + Add Preset
            </button>
          </div>

          {(tenant.chat_presets ?? []).length === 0 ? (
            <div className={s.empty}>
              No presets yet. When presets are defined, member and viewer users will see only these
              gateway / model combinations in /chat instead of the full selector.
            </div>
          ) : (
            <div className={s["table-wrapper"]}>
              <table className={s.table}>
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Gateway</th>
                    <th>Provider</th>
                    <th>Model</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {(tenant.chat_presets ?? []).map((p) => {
                    const gw = gateways.find((g) => g.id === p.gateway_id);
                    return (
                      <tr key={p.id}>
                        <td><strong>{p.name}</strong></td>
                        <td><span className={s.code}>{gw?.slug ?? p.gateway_id}</span></td>
                        <td><span className={s.code}>{p.provider}</span></td>
                        <td><span className={s.code}>{p.model}</span></td>
                        <td style={{ display: "flex", gap: 6, justifyContent: "flex-end" }}>
                          <button
                            className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
                            onClick={() => setEditingPreset(p)}
                            disabled={savingPresets}
                          >
                            Edit
                          </button>
                          <button
                            className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`}
                            onClick={() => handlePresetDelete(p.id)}
                            disabled={savingPresets}
                          >
                            Delete
                          </button>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>
      )}
    </>
  );
}

// ---------------------------------------------------------------------------
// Main page
// ---------------------------------------------------------------------------

export default function Tenants() {
  useDocumentTitle("Tenants");
  const { tenantId } = useParams<{ tenantId?: string }>();
  const navigate = useNavigate();
  const { user: me } = useAuth();
  const canCreate = me?.role === "admin";
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showCreate, setShowCreate] = useState(false);

  function load() {
    setLoading(true);
    api.get<Tenant[]>("/tenants")
      .then(setTenants)
      .catch((e) => setError(e.message))
      .finally(() => setLoading(false));
  }

  useEffect(load, []);

  const selected = tenants.find((t) => t.id === tenantId) ?? null;

  if (tenantId) {
    if (loading) return <main className={s.page}><div className={s.empty}>Loading…</div></main>;
    if (!selected) return <Navigate to="/tenants" replace />;
    return (
      <main className={s.page}>
        <h1 className={s["page-title"]} style={{ marginBottom: 20 }}>{selected.slug}</h1>
        <TenantDetail
          key={tenantId}
          tenant={selected}
          onBack={() => navigate("/tenants")}
          onDeleted={() => { navigate("/tenants"); load(); }}
          onUpdated={(t) => setTenants((ts) => ts.map((x) => x.id === t.id ? t : x))}
        />
      </main>
    );
  }

  return (
    <main className={s.page}>
      {showCreate && <TenantModal onClose={() => setShowCreate(false)} onSaved={load} />}

      <div className={s["page-header"]}>
        <div>
          <h1 className={s["page-title"]}>Tenants</h1>
          <p className={s["page-subtitle"]}>{tenants.length} tenant{tenants.length !== 1 ? "s" : ""}</p>
        </div>
        {canCreate && (
          <button className={`${s.btn} ${s["btn--primary"]}`} onClick={() => setShowCreate(true)}>
            + New Tenant
          </button>
        )}
      </div>

      {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}

      {loading ? (
        <div className={s.empty}>Loading…</div>
      ) : tenants.length === 0 ? (
        <div className={s.card}>
          <div className={s.empty}>No tenants yet. Create your first tenant to get started.</div>
        </div>
      ) : (
        <div className={s["table-wrapper"]}>
          <table className={s.table}>
            <thead>
              <tr>
                <th>Slug</th>
                <th>Plan</th>
                <th>Budget</th>
                <th>Created</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {tenants.map((t) => (
                <tr key={t.id} style={{ cursor: "pointer" }} onClick={() => navigate(`/tenants/${t.id}`)}>
                  <td><span className={s.code}>{t.slug}</span></td>
                  <td><StatusBadge value={t.plan} variant={planVariant(t.plan)} /></td>
                  <td>{t.budget_usd != null ? fmtCost(t.budget_usd) : <span style={{ color: "var(--text-secondary)" }}>unlimited</span>}</td>
                  <td className={s.mono}>{fmtDate(t.created_at)}</td>
                  <td>
                    <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={(e) => { e.stopPropagation(); navigate(`/tenants/${t.id}`); }}>
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
