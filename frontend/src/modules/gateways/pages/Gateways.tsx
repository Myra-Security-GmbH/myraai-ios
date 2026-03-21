import { useEffect, useState } from "react";
import { useParams, useNavigate, Link, Navigate } from "react-router-dom";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { api } from "src/api/client";
import { Gateway, Tenant, ProviderConfig, ProviderMeta, RoutingRule, DetectorConfig } from "src/api/types";
import { DetectorBuilder } from "src/modules/detectors/DetectorBuilder";
import s from "src/common/components/layout/Layout.module.scss";

// ---------------------------------------------------------------------------
// Modals
// ---------------------------------------------------------------------------

function CreateGatewayModal({ tenantId, onClose, onCreated }: {
  tenantId: string; onClose: () => void; onCreated: () => void;
}) {
  const [slug, setSlug] = useState("");
  const [budgetUsd, setBudgetUsd] = useState("");
  const [authRequired, setAuthRequired] = useState(true);
  const [cacheTtl, setCacheTtl] = useState("300");
  const [retryCount, setRetryCount] = useState("2");
  const [timeoutMs, setTimeoutMs] = useState("120000");
  const [detectors, setDetectors] = useState<DetectorConfig[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true); setError(null);
    try {
      await api.post(`/tenants/${tenantId}/gateways`, {
        slug,
        config: {
          auth_required: authRequired,
          budget_usd: budgetUsd !== "" ? parseFloat(budgetUsd) : undefined,
          cache_ttl: parseInt(cacheTtl) || 0,
          retry_count: parseInt(retryCount) || 2,
          timeout_ms: parseInt(timeoutMs) || 120000,
          log_payloads: true,
          detectors,
        },
      });
      onCreated(); onClose();
    } catch (err: any) { setError(err.message); }
    finally { setLoading(false); }
  }

  return (
    <div className={s["modal-overlay"]} onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className={s.modal}>
        <div className={s["modal-header"]}>
          <h2 className={s["modal-title"]}>New Gateway</h2>
          <button className={s["modal-close"]} onClick={onClose}>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
          </button>
        </div>
        {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}
        <form onSubmit={handleSubmit}>
          <div className={s["form-group"]}>
            <label htmlFor="slug" className={s["form-label"]}>Slug *</label>
            <input id="slug" className={s["form-input"]} value={slug} onChange={(e) => setSlug(e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ""))} placeholder="prod" required />
          </div>
          <div className={s["form-row"]}>
            <div className={s["form-group"]}>
              <label htmlFor="budget" className={s["form-label"]}>Budget (USD)</label>
              <input id="budget" className={s["form-input"]} type="number" min="0" step="0.01" value={budgetUsd} onChange={(e) => setBudgetUsd(e.target.value)} placeholder="unlimited" />
            </div>
            <div className={s["form-group"]}>
              <label htmlFor="cachettl" className={s["form-label"]}>Cache TTL (s)</label>
              <input id="cachettl" className={s["form-input"]} type="number" min="0" value={cacheTtl} onChange={(e) => setCacheTtl(e.target.value)} />
              <p className={s["form-hint"]}>0 = disabled</p>
            </div>
          </div>
          <div className={s["form-row"]}>
            <div className={s["form-group"]}>
              <label htmlFor="retrycount" className={s["form-label"]}>Retry Count</label>
              <input id="retrycount" className={s["form-input"]} type="number" min="0" max="5" value={retryCount} onChange={(e) => setRetryCount(e.target.value)} />
            </div>
            <div className={s["form-group"]}>
              <label htmlFor="timeoutms" className={s["form-label"]}>Timeout (ms)</label>
              <input id="timeoutms" className={s["form-input"]} type="number" min="1000" step="1000" value={timeoutMs} onChange={(e) => setTimeoutMs(e.target.value)} />
            </div>
          </div>
          <div className={s["form-group"]}>
            <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer" }}>
              <input type="checkbox" checked={authRequired} onChange={(e) => setAuthRequired(e.target.checked)} />
              <span className={s["form-label"]} style={{ margin: 0 }}>Require auth token</span>
            </label>
          </div>
          <hr style={{ border: "none", borderTop: "1px solid var(--border, #e4e4e7)", margin: "16px 0" }} />
          <DetectorBuilder value={detectors} onChange={setDetectors} />
          <div className={s["form-actions"]}>
            <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
            <button type="submit" className={`${s.btn} ${s["btn--primary"]}`} disabled={loading}>
              {loading ? "Creating…" : "Create Gateway"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

// If an existing gateway has guardrails.enabled=true but no detectors, synthesize
// a legacy llm_guard detector from the old config so the user sees it immediately.
function migrateDetectors(cfg: Gateway["config"]): DetectorConfig[] {
  if ((cfg.detectors ?? []).length > 0) return cfg.detectors!;
  if (cfg.guardrails?.enabled) {
    return [{
      type: "llm_guard",
      name: "llm-guard",
      action: "block",
      target: "request",
      url: cfg.guardrails.llama_guard_url ?? "http://127.0.0.1:8083",
      timeout_ms: cfg.guardrails.timeout_ms ?? 3000,
      fail_open: cfg.guardrails.fail_open ?? true,
    }];
  }
  return [];
}

function EditGatewayModal({ gw, onClose, onSaved }: { gw: Gateway; onClose: () => void; onSaved: (updated: Gateway) => void }) {
  const cfg = gw.config;
  const [budgetUsd, setBudgetUsd] = useState(cfg.budget_usd != null ? String(cfg.budget_usd) : "");
  const [cacheTtl, setCacheTtl] = useState(String(cfg.cache_ttl ?? 0));
  const [retryCount, setRetryCount] = useState(String(cfg.retry_count ?? 2));
  const [timeoutMs, setTimeoutMs] = useState(String(cfg.timeout_ms ?? 120000));
  const [authRequired, setAuthRequired] = useState(cfg.auth_required !== false);
  const [logPayloads, setLogPayloads] = useState(cfg.log_payloads !== false);
  const [rateRequests, setRateRequests] = useState(String(cfg.rate_limit?.requests ?? 500));
  const [rateWindow, setRateWindow] = useState(String(cfg.rate_limit?.window_sec ?? 60));
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true); setError(null);
    try {
      const newConfig: any = {
        auth_required: authRequired,
        log_payloads: logPayloads,
        cache_ttl: parseInt(cacheTtl) || 0,
        retry_count: parseInt(retryCount) || 2,
        timeout_ms: parseInt(timeoutMs) || 120000,
        rate_limit: { requests: parseInt(rateRequests) || 500, window_sec: parseInt(rateWindow) || 60 },
      };
      if (budgetUsd !== "") newConfig.budget_usd = parseFloat(budgetUsd);
      else newConfig.budget_usd = null;
      await api.patch(`/gateways/${gw.id}`, { config: newConfig });
      onSaved({ ...gw, config: { ...cfg, ...newConfig } });
      onClose();
    } catch (err: any) { setError(err.message); }
    finally { setLoading(false); }
  }

  return (
    <div className={s["modal-overlay"]} onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className={s.modal}>
        <div className={s["modal-header"]}>
          <h2 className={s["modal-title"]}>Edit Gateway: {gw.slug}</h2>
          <button className={s["modal-close"]} onClick={onClose}>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
          </button>
        </div>
        {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}
        <form onSubmit={handleSubmit}>
          <div className={s["form-row"]}>
            <div className={s["form-group"]}>
              <label htmlFor="budgetusd" className={s["form-label"]}>Budget (USD)</label>
              <input id="budgetusd" className={s["form-input"]} type="number" min="0" step="0.01" value={budgetUsd} onChange={(e) => setBudgetUsd(e.target.value)} placeholder="unlimited" />
            </div>
            <div className={s["form-group"]}>
              <label htmlFor="cachettl" className={s["form-label"]}>Cache TTL (s)</label>
              <input id="cachettl" className={s["form-input"]} type="number" min="0" value={cacheTtl} onChange={(e) => setCacheTtl(e.target.value)} />
            </div>
          </div>
          <div className={s["form-row"]}>
            <div className={s["form-group"]}>
              <label htmlFor="retrycount" className={s["form-label"]}>Retry Count</label>
              <input id="retrycount" className={s["form-input"]} type="number" min="0" max="5" value={retryCount} onChange={(e) => setRetryCount(e.target.value)} />
            </div>
            <div className={s["form-group"]}>
              <label htmlFor="timeoutms" className={s["form-label"]}>Timeout (ms)</label>
              <input id="timeoutms" className={s["form-input"]} type="number" min="1000" step="1000" value={timeoutMs} onChange={(e) => setTimeoutMs(e.target.value)} />
            </div>
          </div>
          <div className={s["form-row"]}>
            <div className={s["form-group"]}>
              <label htmlFor="raterequests" className={s["form-label"]}>Rate Limit (req)</label>
              <input id="raterequests" className={s["form-input"]} type="number" min="1" value={rateRequests} onChange={(e) => setRateRequests(e.target.value)} />
            </div>
            <div className={s["form-group"]}>
              <label htmlFor="ratewindow" className={s["form-label"]}>Rate Window (s)</label>
              <input id="ratewindow" className={s["form-input"]} type="number" min="1" value={rateWindow} onChange={(e) => setRateWindow(e.target.value)} />
            </div>
          </div>
          <div className={s["form-group"]}>
            <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer" }}>
              <input type="checkbox" checked={authRequired} onChange={(e) => setAuthRequired(e.target.checked)} />
              <span className={s["form-label"]} style={{ margin: 0 }}>Require auth token</span>
            </label>
          </div>
          <div className={s["form-group"]}>
            <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer" }}>
              <input type="checkbox" checked={logPayloads} onChange={(e) => setLogPayloads(e.target.checked)} />
              <span className={s["form-label"]} style={{ margin: 0 }}>Log request/response payloads</span>
            </label>
          </div>
          <div className={s["form-actions"]}>
            <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
            <button type="submit" className={`${s.btn} ${s["btn--primary"]}`} disabled={loading}>
              {loading ? "Saving…" : "Save Changes"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

function AddKeyModal({ gatewayId, onClose, onAdded }: { gatewayId: string; onClose: () => void; onAdded: () => void }) {
  const [provider, setProvider] = useState("anthropic");
  const [apiKey, setApiKey] = useState("");
  const [alias, setAlias] = useState("default");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);
  const [providerList, setProviderList] = useState<ProviderMeta[]>([]);

  useEffect(() => {
    api.get<ProviderMeta[]>("/providers").then(setProviderList).catch(() => {});
  }, []);

  const selectedMeta = providerList.find((p) => p.name === provider);
  const needsKey = selectedMeta?.requires_key ?? true;

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true); setError(null);
    try {
      await api.post(`/gateways/${gatewayId}/keys`, { provider, key: needsKey ? apiKey : "", alias });
      setSuccess(true);
      onAdded();
    } catch (err: any) { setError(err.message); }
    finally { setLoading(false); }
  }

  return (
    <div className={s["modal-overlay"]} onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className={s.modal}>
        <div className={s["modal-header"]}>
          <h2 className={s["modal-title"]}>Add / Rotate Provider Key</h2>
          <button className={s["modal-close"]} onClick={onClose}>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
          </button>
        </div>
        {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}
        {success ? (
          <div className={`${s.alert} ${s["alert--success"]}`}>Key stored and encrypted successfully.</div>
        ) : (
          <form onSubmit={handleSubmit}>
            <div className={s["form-row"]}>
              <div className={s["form-group"]}>
                <label htmlFor="provider" className={s["form-label"]}>Provider</label>
                <select id="provider" className={s["form-select"]} value={provider} onChange={(e) => setProvider(e.target.value)}>
                  {(providerList.length > 0 ? providerList.map((p) => p.name) : ["anthropic"]).map((p) => (
                    <option key={p} value={p}>{p}</option>
                  ))}
                </select>
              </div>
              <div className={s["form-group"]}>
                <label htmlFor="alias" className={s["form-label"]}>Alias</label>
                <input id="alias" className={s["form-input"]} value={alias} onChange={(e) => setAlias(e.target.value)} placeholder="default" />
              </div>
            </div>
            <div className={s["form-group"]}>
              <label htmlFor="apikey" className={s["form-label"]}>API Key{needsKey ? " *" : ""}</label>
              {needsKey ? (
                <input id="apikey" className={s["form-input"]} type="password" value={apiKey} onChange={(e) => setApiKey(e.target.value)} placeholder="sk-…" required />
              ) : (
                <p className={s["form-hint"]} style={{ marginTop: 4 }}>
                  This provider does not require an API key.
                </p>
              )}
              {needsKey && <p className={s["form-hint"]}>Stored encrypted. Replaces existing key for this provider/alias.</p>}
            </div>
            <div className={s["form-actions"]}>
              <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
              <button type="submit" className={`${s.btn} ${s["btn--primary"]}`} disabled={loading || (needsKey && !apiKey.trim())}>
                {loading ? "Storing…" : "Store Key"}
              </button>
            </div>
          </form>
        )}
      </div>
    </div>
  );
}

function CreateTokenModal({ gatewayId, onClose, onCreated }: {
  gatewayId: string; onClose: () => void; onCreated: () => void;
}) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [newToken, setNewToken] = useState<string | null>(null);
  const [expiresAt, setExpiresAt] = useState("");
  const [copied, setCopied] = useState(false);

  async function handleCreate() {
    setLoading(true); setError(null);
    try {
      const res = await api.post<{ token: string }>(`/gateways/${gatewayId}/tokens`, {
        expires_at: expiresAt || null,
      });
      setNewToken(res.token);
      onCreated();
    } catch (err: any) { setError(err.message); }
    finally { setLoading(false); }
  }

  function copyToken() {
    if (!newToken) return;
    navigator.clipboard.writeText(newToken);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }

  return (
    <div className={s["modal-overlay"]} onClick={(e) => e.target === e.currentTarget && !newToken && onClose()}>
      <div className={s.modal}>
        <div className={s["modal-header"]}>
          <h2 className={s["modal-title"]}>{newToken ? "Token Created" : "Create Auth Token"}</h2>
          <button className={s["modal-close"]} onClick={onClose}>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
          </button>
        </div>
        {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}
        {newToken ? (
          <>
            <p style={{ color: "var(--text-secondary)", marginBottom: 12, fontSize: 14 }}>
              Copy this token now. It will <strong>not</strong> be shown again.
            </p>
            <div className={s["token-reveal"]}>{newToken}</div>
            <div className={s["form-actions"]}>
              <button className={`${s.btn} ${s["btn--primary"]}`} onClick={copyToken}>
                {copied ? "Copied!" : "Copy"}
              </button>
              <button className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Done</button>
            </div>
          </>
        ) : (
          <>
            <div className={s["form-group"]}>
              <label htmlFor="expiresat" className={s["form-label"]}>Expires At (optional)</label>
              <input id="expiresat" className={s["form-input"]} type="datetime-local" value={expiresAt} onChange={(e) => setExpiresAt(e.target.value)} />
              <p className={s["form-hint"]}>Leave blank for a non-expiring token.</p>
            </div>
            <div className={s["form-actions"]}>
              <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
              <button className={`${s.btn} ${s["btn--primary"]}`} onClick={handleCreate} disabled={loading}>
                {loading ? "Generating…" : "Generate Token"}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

function RuleModal({ gatewayId, rule, onClose, onSaved }: {
  gatewayId: string; rule?: RoutingRule; onClose: () => void; onSaved: () => void;
}) {
  const isEdit = !!rule;
  const [priority, setPriority] = useState(String(rule?.priority ?? 0));
  const [enabled, setEnabled] = useState(rule ? rule.enabled === 1 : true);
  const [provider, setProvider] = useState(rule?.actions?.provider ?? "");
  const [model, setModel] = useState(rule?.actions?.model ?? "");
  const [conditions, setConditions] = useState<Array<{ field: string; op: string; value: string }>>(
    rule?.conditions ?? []
  );
  const [fallbacks, setFallbacks] = useState<Array<{ provider: string; model: string }>>(
    rule?.actions?.fallbacks ?? []
  );
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function addCondition() {
    setConditions([...conditions, { field: "model", op: "eq", value: "" }]);
  }
  function removeCondition(i: number) {
    setConditions(conditions.filter((_, idx) => idx !== i));
  }
  function updateCondition(i: number, key: string, val: string) {
    setConditions(conditions.map((c, idx) => idx === i ? { ...c, [key]: val } : c));
  }
  function addFallback() {
    setFallbacks([...fallbacks, { provider: "", model: "" }]);
  }
  function removeFallback(i: number) {
    setFallbacks(fallbacks.filter((_, idx) => idx !== i));
  }
  function updateFallback(i: number, key: string, val: string) {
    setFallbacks(fallbacks.map((f, idx) => idx === i ? { ...f, [key]: val } : f));
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true); setError(null);
    try {
      const payload = {
        priority: parseInt(priority) || 0,
        enabled,
        conditions,
        actions: { provider: provider || undefined, model: model || undefined, fallbacks: fallbacks.length > 0 ? fallbacks : undefined },
      };
      if (isEdit) {
        await api.patch(`/gateways/${gatewayId}/rules/${rule!.id}`, payload);
      } else {
        await api.post(`/gateways/${gatewayId}/rules`, payload);
      }
      onSaved(); onClose();
    } catch (err: any) { setError(err.message); }
    finally { setLoading(false); }
  }

  return (
    <div className={s["modal-overlay"]} onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className={s.modal} style={{ maxWidth: 600 }}>
        <div className={s["modal-header"]}>
          <h2 className={s["modal-title"]}>{isEdit ? "Edit Rule" : "New Routing Rule"}</h2>
          <button className={s["modal-close"]} onClick={onClose}>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
          </button>
        </div>
        {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}
        <form onSubmit={handleSubmit}>
          <div className={s["form-row"]}>
            <div className={s["form-group"]}>
              <label htmlFor="priority" className={s["form-label"]}>Priority (higher = first)</label>
              <input id="priority" className={s["form-input"]} type="number" value={priority} onChange={(e) => setPriority(e.target.value)} />
            </div>
            <div className={s["form-group"]}>
              <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer", marginTop: 24 }}>
                <input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />
                <span className={s["form-label"]} style={{ margin: 0 }}>Enabled</span>
              </label>
            </div>
          </div>

          <div className={s["form-group"]}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
              <label className={s["form-label"]} style={{ margin: 0 }}>Conditions (all must match)</label>
              <button type="button" className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={addCondition}>+ Add</button>
            </div>
            {conditions.length === 0 && <p className={s["form-hint"]}>No conditions = matches all requests.</p>}
            {conditions.map((c, i) => (
              <div key={i} style={{ display: "flex", gap: 6, marginBottom: 6 }}>
                <select className={s["form-select"]} style={{ flex: 1 }} value={c.field} onChange={(e) => updateCondition(i, "field", e.target.value)}>
                  <option value="model">model</option>
                  <option value="provider">provider</option>
                  <option value="tenant_id">tenant_id</option>
                </select>
                <select className={s["form-select"]} style={{ width: 80 }} value={c.op} onChange={(e) => updateCondition(i, "op", e.target.value)}>
                  <option value="eq">eq</option>
                  <option value="neq">neq</option>
                  <option value="prefix">prefix</option>
                </select>
                <input className={s["form-input"]} style={{ flex: 2 }} value={c.value} onChange={(e) => updateCondition(i, "value", e.target.value)} placeholder="value" />
                <button type="button" className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={() => removeCondition(i)}>×</button>
              </div>
            ))}
          </div>

          <div className={s["form-group"]}>
            <label className={s["form-label"]}>Action: Route to</label>
            <div className={s["form-row"]}>
              <div className={s["form-group"]}>
                <label htmlFor="provider" className={s["form-label"]}>Provider</label>
                <input id="provider" className={s["form-input"]} value={provider} onChange={(e) => setProvider(e.target.value)} placeholder="provider (e.g. anthropic)" />
              </div>
              <div className={s["form-group"]}>
                <label htmlFor="model" className={s["form-label"]}>Model</label>
                <input id="model" className={s["form-input"]} value={model} onChange={(e) => setModel(e.target.value)} placeholder="model (e.g. claude-sonnet-4-6)" />
              </div>
            </div>
          </div>

          <div className={s["form-group"]}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
              <label className={s["form-label"]} style={{ margin: 0 }}>Fallbacks (tried in order)</label>
              <button type="button" className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={addFallback}>+ Add</button>
            </div>
            {fallbacks.map((f, i) => (
              <div key={i} style={{ display: "flex", gap: 6, marginBottom: 6 }}>
                <input className={s["form-input"]} style={{ flex: 1 }} value={f.provider} onChange={(e) => updateFallback(i, "provider", e.target.value)} placeholder="provider" />
                <input className={s["form-input"]} style={{ flex: 2 }} value={f.model} onChange={(e) => updateFallback(i, "model", e.target.value)} placeholder="model" />
                <button type="button" className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={() => removeFallback(i)}>×</button>
              </div>
            ))}
          </div>

          <div className={s["form-actions"]}>
            <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
            <button type="submit" className={`${s.btn} ${s["btn--primary"]}`} disabled={loading}>
              {loading ? "Saving…" : (isEdit ? "Save Rule" : "Create Rule")}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Gateway detail
// ---------------------------------------------------------------------------

function GatewayDetail({ gw: initialGw, tenantSlug, onBack, onDeleted }: {
  gw: Gateway; tenantSlug: string; onBack: () => void; onDeleted: () => void;
}) {
  const [gw, setGw] = useState(initialGw);
  const [tokens, setTokens] = useState<any[]>([]);
  const [loadingTokens, setLoadingTokens] = useState(true);
  const [keys, setKeys] = useState<ProviderConfig[]>([]);
  const [rules, setRules] = useState<RoutingRule[]>([]);
  const [showAddKey, setShowAddKey] = useState(false);
  const [showCreateToken, setShowCreateToken] = useState(false);
  const [showEdit, setShowEdit] = useState(false);
  const [showNewRule, setShowNewRule] = useState(false);
  const [editingRule, setEditingRule] = useState<RoutingRule | null>(null);
  const [budgetResetting, setBudgetResetting] = useState(false);
  const [deleting, setDeleting] = useState(false);
  const [detectors, setDetectors] = useState<DetectorConfig[]>(() => migrateDetectors(initialGw.config));
  const [detectorsChanged, setDetectorsChanged] = useState(false);
  const [detectorsMigrated] = useState(() => (initialGw.config.detectors ?? []).length === 0 && !!initialGw.config.guardrails?.enabled);
  const [savingDetectors, setSavingDetectors] = useState(false);
  const [detectorsError, setDetectorsError] = useState<string | null>(null);
  const [detectorsSaved, setDetectorsSaved] = useState(false);

  function loadTokens() {
    setLoadingTokens(true);
    api.get<any[]>(`/gateways/${gw.id}/tokens`).then(setTokens).finally(() => setLoadingTokens(false));
  }
  function loadKeys() {
    api.get<ProviderConfig[]>(`/gateways/${gw.id}/keys`).then(setKeys);
  }
  function loadRules() {
    api.get<RoutingRule[]>(`/gateways/${gw.id}/rules`).then(setRules);
  }

  useEffect(() => { loadTokens(); loadKeys(); loadRules(); }, [gw.id]);

  async function deleteToken(tokenId: string) {
    if (!confirm("Delete this token? Requests using it will fail.")) return;
    await api.delete(`/gateways/${gw.id}/tokens/${tokenId}`);
    loadTokens();
  }
  async function deleteKey(provider: string, alias: string) {
    if (!confirm(`Delete key for ${provider}/${alias}? Routing to this provider will fail.`)) return;
    await api.delete(`/gateways/${gw.id}/keys/${provider}/${alias}`);
    loadKeys();
  }
  async function deleteRule(ruleId: string) {
    if (!confirm("Delete this routing rule?")) return;
    await api.delete(`/gateways/${gw.id}/rules/${ruleId}`);
    loadRules();
  }
  async function resetBudget() {
    if (!confirm("Reset the budget spend counter to $0?")) return;
    setBudgetResetting(true);
    await api.delete(`/gateways/${gw.id}/budget`);
    setBudgetResetting(false);
  }
  async function deleteGateway() {
    if (!confirm(`Delete gateway "${gw.slug}"? This cannot be undone.`)) return;
    setDeleting(true);
    await api.delete(`/gateways/${gw.id}`);
    onDeleted();
  }

  async function saveDetectors() {
    setSavingDetectors(true); setDetectorsError(null); setDetectorsSaved(false);
    try {
      const newConfig = { ...gw.config, detectors, guardrails: { enabled: false } };
      await api.patch(`/gateways/${gw.id}`, { config: newConfig });
      setGw({ ...gw, config: newConfig });
      setDetectorsChanged(false);
      setDetectorsSaved(true);
      setTimeout(() => setDetectorsSaved(false), 3000);
    } catch (err: any) { setDetectorsError(err.message); }
    finally { setSavingDetectors(false); }
  }

  const cfg = gw.config;
  const baseUrl = `http://127.0.0.1:8081/v1/${tenantSlug}/${gw.slug}/<provider>/v1`;

  return (
    <>
      {showAddKey && <AddKeyModal gatewayId={gw.id} onClose={() => setShowAddKey(false)} onAdded={loadKeys} />}
      {showCreateToken && <CreateTokenModal gatewayId={gw.id} onClose={() => setShowCreateToken(false)} onCreated={loadTokens} />}
      {showEdit && <EditGatewayModal gw={gw} onClose={() => setShowEdit(false)} onSaved={setGw} />}
      {showNewRule && <RuleModal gatewayId={gw.id} onClose={() => setShowNewRule(false)} onSaved={loadRules} />}
      {editingRule && <RuleModal gatewayId={gw.id} rule={editingRule} onClose={() => setEditingRule(null)} onSaved={loadRules} />}

      <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={onBack} style={{ marginBottom: 16 }}>
        ← Gateways
      </button>

      {/* Config card */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Gateway: <span className={s.code}>{gw.slug}</span></h2>
          <div style={{ display: "flex", gap: 8 }}>
            <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={() => setShowEdit(true)}>Edit</button>
            <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={deleteGateway} disabled={deleting}>
              {deleting ? "Deleting…" : "Delete"}
            </button>
          </div>
        </div>
        <div className={s["stats-grid"]}>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Budget</div>
            <div className={s["stat-value"]}>{cfg.budget_usd != null ? `$${cfg.budget_usd}` : "—"}</div>
            {cfg.budget_usd != null && (
              <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} style={{ marginTop: 6 }} onClick={resetBudget} disabled={budgetResetting}>
                {budgetResetting ? "…" : "Reset Spend"}
              </button>
            )}
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Cache TTL</div>
            <div className={s["stat-value"]}>{cfg.cache_ttl ?? 0}s</div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Retries</div>
            <div className={s["stat-value"]}>{cfg.retry_count ?? 2}</div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Timeout</div>
            <div className={s["stat-value"]}>{cfg.timeout_ms ?? 120000}ms</div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Auth</div>
            <div className={s["stat-value"]}>{cfg.auth_required !== false ? "required" : "open"}</div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Rate Limit</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`}>
              {cfg.rate_limit ? `${cfg.rate_limit.requests}/${cfg.rate_limit.window_sec}s` : "—"}
            </div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Log Payloads</div>
            <div className={s["stat-value"]}>{cfg.log_payloads !== false ? "yes" : "no"}</div>
          </div>
        </div>
        <div className={s["form-group"]} style={{ marginTop: 12 }}>
          <label className={s["form-label"]}>Base URL</label>
          <div className={s["code"]} style={{ padding: "8px 12px", fontSize: 12, wordBreak: "break-all" }}>{baseUrl}</div>
        </div>
      </div>

      {/* Provider Keys */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Provider Keys</h2>
          <button className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`} onClick={() => setShowAddKey(true)}>+ Add / Rotate</button>
        </div>
        {keys.length === 0 ? (
          <div className={s.empty}>No keys stored. Add one to enable provider routing.</div>
        ) : (
          <div className={s["table-wrapper"]}>
            <table className={s.table}>
              <thead><tr><th>Provider</th><th>Alias</th><th>Added</th><th></th></tr></thead>
              <tbody>
                {keys.map((k) => (
                  <tr key={k.id}>
                    <td><span className={s.code}>{k.provider}</span></td>
                    <td>{k.alias}</td>
                    <td className={s.mono}>{k.created_at.slice(0, 10)}</td>
                    <td>
                      <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={() => deleteKey(k.provider, k.alias)}>Delete</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Auth Tokens */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Auth Tokens</h2>
          <button className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`} onClick={() => setShowCreateToken(true)}>+ Generate</button>
        </div>
        {loadingTokens ? (
          <div className={s.empty}>Loading…</div>
        ) : tokens.length === 0 ? (
          <div className={s.empty}>No tokens yet. Generate one to allow access to this gateway.</div>
        ) : (
          <div className={s["table-wrapper"]}>
            <table className={s.table}>
              <thead>
                <tr><th>ID</th><th>Hash (first 16)</th><th>Expires</th><th>Created</th><th></th></tr>
              </thead>
              <tbody>
                {tokens.map((t) => (
                  <tr key={t.id}>
                    <td className={s.mono} style={{ fontSize: 11 }}>{t.id.slice(0, 8)}…</td>
                    <td className={s.mono} style={{ fontSize: 11 }}>{t.token_hash.slice(0, 16)}…</td>
                    <td>{t.expires_at ?? <span style={{ color: "var(--text-secondary)" }}>never</span>}</td>
                    <td className={s.mono}>{t.created_at.slice(0, 10)}</td>
                    <td><button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={() => deleteToken(t.id)}>Revoke</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {/* Detectors */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Detectors</h2>
          <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
            {detectorsSaved && <span style={{ fontSize: 12, color: "var(--badge-success-text)" }}>Saved</span>}
            <button
              className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`}
              onClick={saveDetectors}
              disabled={savingDetectors || !detectorsChanged}
            >
              {savingDetectors ? "Saving…" : "Save Detectors"}
            </button>
          </div>
        </div>
        {detectorsMigrated && (
          <div className={`${s.alert} ${s["alert--warning"]}`} style={{ marginBottom: 16 }}>
            Legacy guardrail converted to a Llama Guard detector. Save to apply.
          </div>
        )}
        {detectorsError && <div className={`${s.alert} ${s["alert--error"]}`}>{detectorsError}</div>}
        <DetectorBuilder
          value={detectors}
          onChange={(d) => { setDetectors(d); setDetectorsChanged(true); }}
        />
      </div>

      {/* Routing Rules */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Routing Rules</h2>
          <button className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`} onClick={() => setShowNewRule(true)}>+ New Rule</button>
        </div>
        {rules.length === 0 ? (
          <div className={s.empty}>No routing rules. Add rules to override default provider routing.</div>
        ) : (
          <div className={s["table-wrapper"]}>
            <table className={s.table}>
              <thead>
                <tr><th>Priority</th><th>Conditions</th><th>Route To</th><th>Fallbacks</th><th>Status</th><th></th></tr>
              </thead>
              <tbody>
                {rules.map((r) => (
                  <tr key={r.id}>
                    <td>{r.priority}</td>
                    <td style={{ fontSize: 12 }}>
                      {r.conditions.length === 0 ? (
                        <span style={{ color: "var(--text-secondary)" }}>any</span>
                      ) : (
                        r.conditions.map((c, i) => (
                          <div key={i}>{c.field} {c.op} <span className={s.code}>{c.value}</span></div>
                        ))
                      )}
                    </td>
                    <td style={{ fontSize: 12 }}>
                      {r.actions.provider && <span className={s.code}>{r.actions.provider}</span>}
                      {r.actions.model && <> / <span className={s.code}>{r.actions.model}</span></>}
                    </td>
                    <td style={{ fontSize: 12 }}>
                      {(r.actions.fallbacks ?? []).map((f, i) => (
                        <div key={i}><span className={s.code}>{f.provider}/{f.model}</span></div>
                      ))}
                    </td>
                    <td>
                      <span className={`${s.badge} ${r.enabled ? s["badge--success"] : s["badge--neutral"]}`}>
                        {r.enabled ? "on" : "off"}
                      </span>
                    </td>
                    <td style={{ display: "flex", gap: 4 }}>
                      <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={() => setEditingRule(r)}>Edit</button>
                      <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={() => deleteRule(r.id)}>Del</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </>
  );
}

// ---------------------------------------------------------------------------
// Main page
// ---------------------------------------------------------------------------

export default function Gateways() {
  useDocumentTitle("Gateways");
  const { tenantId, gatewayId } = useParams<{ tenantId?: string; gatewayId?: string }>();
  const navigate = useNavigate();
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [gateways, setGateways] = useState<Gateway[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showCreate, setShowCreate] = useState(false);

  const selectedTenant = tenants.find((t) => t.id === tenantId) ?? null;
  const selectedGateway = gateways.find((g) => g.id === gatewayId) ?? null;

  useEffect(() => {
    api.get<Tenant[]>("/tenants").then(setTenants);
  }, []);

  useEffect(() => {
    if (!tenantId) { setLoading(false); return; }
    setLoading(true);
    api.get<Gateway[]>(`/tenants/${tenantId}/gateways`)
      .then(setGateways)
      .catch((e) => setError(e.message))
      .finally(() => setLoading(false));
  }, [tenantId]);

  function loadGateways() {
    if (!tenantId) return;
    api.get<Gateway[]>(`/tenants/${tenantId}/gateways`).then(setGateways);
  }

  async function deleteGateway(g: Gateway) {
    if (!confirm(`Delete gateway "${g.slug}"?`)) return;
    await api.delete(`/gateways/${g.id}`);
    loadGateways();
  }

  const listUrl = tenantId ? `/tenants/${tenantId}/gateways` : "/gateways";

  if (gatewayId && selectedTenant) {
    if (loading) return <main className={s.page}><div className={s.empty}>Loading…</div></main>;
    if (!selectedGateway) return <Navigate to={listUrl} replace />;
    return (
      <main className={s.page}>
        <h1 className={s["page-title"]} style={{ marginBottom: 20 }}>
          {selectedTenant.slug} / {selectedGateway.slug}
        </h1>
        <GatewayDetail
          key={gatewayId}
          gw={selectedGateway}
          tenantSlug={selectedTenant.slug}
          onBack={() => navigate(listUrl)}
          onDeleted={() => { navigate(listUrl); loadGateways(); }}
        />
      </main>
    );
  }

  return (
    <main className={s.page}>
      {showCreate && selectedTenant && (
        <CreateGatewayModal tenantId={selectedTenant.id} onClose={() => setShowCreate(false)} onCreated={loadGateways} />
      )}

      <div className={s["page-header"]}>
        <div>
          <h1 className={s["page-title"]}>Gateways</h1>
          {selectedTenant && <p className={s["page-subtitle"]}>Tenant: <span className={s.code}>{selectedTenant.slug}</span></p>}
        </div>
        {selectedTenant && (
          <button className={`${s.btn} ${s["btn--primary"]}`} onClick={() => setShowCreate(true)}>
            + New Gateway
          </button>
        )}
      </div>

      {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}

      {/* Tenant selector */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Select Tenant</h2>
        </div>
        <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
          {tenants.map((t) => (
            <button
              key={t.id}
              className={`${s.btn} ${selectedTenant?.id === t.id ? s["btn--primary"] : s["btn--secondary"]}`}
              onClick={() => navigate(`/tenants/${t.id}/gateways`)}
            >
              {t.slug}
            </button>
          ))}
        </div>
      </div>

      {selectedTenant && (
        loading ? (
          <div className={s.empty}>Loading…</div>
        ) : gateways.length === 0 ? (
          <div className={s.card}>
            <div className={s.empty}>No gateways for <strong>{selectedTenant.slug}</strong> yet.</div>
          </div>
        ) : (
          <div className={s["table-wrapper"]}>
            <table className={s.table}>
              <thead>
                <tr>
                  <th>Slug</th><th>Auth</th><th>Budget</th><th>Cache</th><th>Rate Limit</th><th>Detectors</th><th>Created</th><th></th>
                </tr>
              </thead>
              <tbody>
                {gateways.map((g) => (
                  <tr key={g.id} style={{ cursor: "pointer" }} onClick={() => navigate(`/tenants/${tenantId}/gateways/${g.id}`)}>
                    <td><span className={s.code}>{g.slug}</span></td>
                    <td>
                      <span className={`${s.badge} ${g.config.auth_required !== false ? s["badge--success"] : s["badge--neutral"]}`}>
                        {g.config.auth_required !== false ? "required" : "open"}
                      </span>
                    </td>
                    <td>{g.config.budget_usd != null ? `$${g.config.budget_usd}` : "—"}</td>
                    <td>{g.config.cache_ttl ?? 0}s</td>
                    <td style={{ fontSize: 12 }}>
                      {g.config.rate_limit ? `${g.config.rate_limit.requests}/${g.config.rate_limit.window_sec}s` : "—"}
                    </td>
                    <td>
                      {(g.config.detectors ?? []).length > 0 ? (
                        <span className={`${s.badge} ${s["badge--warning"]}`}>
                          {g.config.detectors!.length}
                        </span>
                      ) : g.config.guardrails?.enabled ? (
                        <span className={`${s.badge} ${s["badge--neutral"]}`} title="Legacy guardrail — open Edit to migrate">legacy</span>
                      ) : (
                        <span className={`${s.badge} ${s["badge--neutral"]}`}>—</span>
                      )}
                    </td>
                    <td className={s.mono}>{g.created_at.slice(0, 10)}</td>
                    <td style={{ display: "flex", gap: 6 }}>
                      <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={(e) => { e.stopPropagation(); navigate(`/tenants/${tenantId}/gateways/${g.id}`); }}>Open →</button>
                      <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={(e) => { e.stopPropagation(); deleteGateway(g); }}>Delete</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )
      )}
    </main>
  );
}
