import { useEffect, useState } from "react";
import { useParams, useNavigate, Link, Navigate } from "react-router-dom";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { api } from "src/api/client";
import { Gateway, Tenant, ProviderConfig, ProviderMeta, RoutingRule, DetectorConfig, GatewayGuardrailStats, GuardrailEvent, CircuitBreakerStatus, CircuitBreakerConfig, LoadBalanceConfig, WebhookConfig, WebhookEvent, BudgetPeriod, SiemType, SiemEvent } from "src/api/types";
import { GuardrailBuilder } from "src/modules/guardrails/GuardrailBuilder";
import { fmtDate, fmtDateTime } from "src/common/utils/date";
import { fmtNumber, fmtCost, fmtMs, fmtSec } from "src/common/utils/format";
import { DocLink, docsUrl } from "src/common/components/DocLink";
import { Modal } from "src/common/components/Modal";
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
  const [guardrails, setGuardrails] = useState<DetectorConfig[]>([]);
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
          guardrails,
        },
      });
      onCreated(); onClose();
    } catch (err: any) { setError(err.message); }
    finally { setLoading(false); }
  }

  return (
    <Modal title="New Gateway" onClose={onClose} error={error}>
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
          <hr className={s.divider} />
          <GuardrailBuilder value={guardrails} onChange={setGuardrails} />
          <div className={s["form-actions"]}>
            <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
            <button type="submit" className={`${s.btn} ${s["btn--primary"]}`} disabled={loading}>
              {loading ? "Creating…" : "Create Gateway"}
            </button>
          </div>
        </form>
    </Modal>
  );
}

function EditGatewayModal({ gw, onClose, onSaved }: { gw: Gateway; onClose: () => void; onSaved: (updated: Gateway) => void }) {
  const cfg = gw.config;
  const [budgetUsd, setBudgetUsd] = useState(cfg.budget_usd != null ? String(cfg.budget_usd) : "");
  const [budgetPeriod, setBudgetPeriod] = useState<BudgetPeriod>(cfg.budget_period ?? "monthly");
  const [cacheTtl, setCacheTtl] = useState(String(cfg.cache_ttl ?? 0));
  const [retryCount, setRetryCount] = useState(String(cfg.retry_count ?? 2));
  const [timeoutMs, setTimeoutMs] = useState(String(cfg.timeout_ms ?? 120000));
  const [authRequired, setAuthRequired] = useState(cfg.auth_required !== false);
  const [logPayloads, setLogPayloads] = useState(cfg.log_payloads !== false);
  const [rateRequests, setRateRequests] = useState(String(cfg.rate_limit?.requests ?? 500));
  const [rateWindow, setRateWindow] = useState(String(cfg.rate_limit?.window_sec ?? 60));
  const [cbEnabled, setCbEnabled] = useState(cfg.circuit_breaker?.enabled ?? false);
  const [cbThreshold, setCbThreshold] = useState(String(cfg.circuit_breaker?.failure_threshold ?? 5));
  const [cbWindow, setCbWindow] = useState(String(cfg.circuit_breaker?.window_sec ?? 60));
  const [cbCooldown, setCbCooldown] = useState(String(cfg.circuit_breaker?.cooldown_ms ?? 30000));
  const [baseUrls, setBaseUrls] = useState<Array<{ provider: string; url: string }>>(
    Object.entries(cfg.provider_base_urls ?? {}).map(([provider, url]) => ({ provider, url }))
  );
  const [webhookUrl, setWebhookUrl] = useState(cfg.webhooks?.url ?? "");
  const [webhookSecret, setWebhookSecret] = useState(cfg.webhooks?.secret ?? "");
  const [webhookEvents, setWebhookEvents] = useState<WebhookEvent[]>(
    cfg.webhooks?.events ?? ["blocked", "budget_exceeded", "circuit_open"]
  );
  const [siemType, setSiemType] = useState<SiemType | "">(cfg.siem?.type ?? "");
  const [siemEvents, setSiemEvents] = useState<SiemEvent[]>(cfg.siem?.events ?? ["blocked"]);
  const [siemUrl, setSiemUrl] = useState(cfg.siem?.url ?? "");
  const [siemToken, setSiemToken] = useState(cfg.siem?.token ?? "");
  const [siemIndex, setSiemIndex] = useState(cfg.siem?.index ?? "");
  const [siemUsername, setSiemUsername] = useState(cfg.siem?.username ?? "");
  const [siemPassword, setSiemPassword] = useState(cfg.siem?.password ?? "");
  const [siemHost, setSiemHost] = useState(cfg.siem?.host ?? "");
  const [siemPort, setSiemPort] = useState(String(cfg.siem?.port ?? "514"));
  const [siemProtocol, setSiemProtocol] = useState<"udp" | "tcp">(cfg.siem?.protocol ?? "udp");
  const [siemFormat, setSiemFormat] = useState<"cef" | "rfc5424">(cfg.siem?.format ?? "cef");
  const [wsEnabled,    setWsEnabled]    = useState(cfg.web_search?.enabled ?? false);
  const [wsApiKey,     setWsApiKey]     = useState(cfg.web_search?.api_key ?? "");
  const [wsMaxResults, setWsMaxResults] = useState(cfg.web_search?.max_results ?? 5);
  const tracingCfg = (cfg as any).tracing;
  const [tracingEnabled, setTracingEnabled] = useState<boolean>(tracingCfg?.enabled ?? false);
  const [tracingBodies, setTracingBodies] = useState<boolean>(tracingCfg?.include_bodies ?? false);
  const [tracingRetention, setTracingRetention] = useState(String(tracingCfg?.retention_hours ?? 48));
  const pcCfg = (cfg as any).prompt_caching;
  const [pcEnabled, setPcEnabled] = useState<boolean>(pcCfg?.enabled ?? false);
  const [pcTtl, setPcTtl] = useState<"5m" | "1h">(pcCfg?.ttl ?? "1h");
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
      if (budgetUsd !== "") { newConfig.budget_usd = parseFloat(budgetUsd); newConfig.budget_period = budgetPeriod; }
      else { newConfig.budget_usd = null; newConfig.budget_period = undefined; }
      if (cbEnabled) {
        newConfig.circuit_breaker = {
          enabled: true,
          failure_threshold: parseInt(cbThreshold) || 5,
          window_sec: parseInt(cbWindow) || 60,
          cooldown_ms: parseInt(cbCooldown) || 30000,
        };
      } else {
        newConfig.circuit_breaker = null;
      }
      const validBaseUrls = baseUrls.filter((e) => e.provider.trim() && e.url.trim());
      if (validBaseUrls.length > 0) {
        newConfig.provider_base_urls = Object.fromEntries(validBaseUrls.map((e) => [e.provider.trim(), e.url.trim()]));
      }
      if (webhookUrl.trim()) {
        newConfig.webhooks = {
          url: webhookUrl.trim(),
          ...(webhookSecret.trim() ? { secret: webhookSecret.trim() } : {}),
          events: webhookEvents.length > 0 ? webhookEvents : undefined,
        };
      } else {
        newConfig.webhooks = null;
      }
      if (siemType) {
        const siemCfg: any = { type: siemType, events: siemEvents.length > 0 ? siemEvents : ["blocked"] };
        if (siemType === "splunk_hec") {
          siemCfg.url = siemUrl.trim();
          if (siemToken.trim()) siemCfg.token = siemToken.trim();
          if (siemIndex.trim()) siemCfg.index = siemIndex.trim();
        } else if (siemType === "elasticsearch") {
          siemCfg.url = siemUrl.trim();
          if (siemIndex.trim()) siemCfg.index = siemIndex.trim();
          if (siemUsername.trim()) { siemCfg.username = siemUsername.trim(); siemCfg.password = siemPassword.trim(); }
        } else if (siemType === "vector") {
          siemCfg.url = siemUrl.trim();
        } else if (siemType === "syslog") {
          siemCfg.host = siemHost.trim();
          siemCfg.port = parseInt(siemPort) || 514;
          siemCfg.protocol = siemProtocol;
          siemCfg.format = siemFormat;
        }
        newConfig.siem = siemCfg;
      } else {
        newConfig.siem = null;
      }
      newConfig.web_search = (wsEnabled && wsApiKey.trim())
        ? { enabled: true, api_key: wsApiKey.trim(), max_results: wsMaxResults }
        : null;
      if (tracingEnabled) {
        newConfig.tracing = {
          enabled: true,
          include_bodies: tracingBodies,
          retention_hours: parseInt(tracingRetention) || 48,
        };
      } else {
        newConfig.tracing = null;
      }
      newConfig.prompt_caching = pcEnabled
        ? { enabled: true, ttl: pcTtl }
        : null;
      await api.patch(`/gateways/${gw.id}`, { config: newConfig });
      onSaved({ ...gw, config: { ...cfg, ...newConfig } });
      onClose();
    } catch (err: any) { setError(err.message); }
    finally { setLoading(false); }
  }

  return (
    <Modal title={`Edit Gateway: ${gw.slug}`} onClose={onClose} error={error}>
      <form onSubmit={handleSubmit}>
          <div className={s["form-row"]}>
            <div className={s["form-group"]}>
              <label htmlFor="budgetusd" className={s["form-label"]} style={{ display: "flex", alignItems: "center", gap: 6 }}>Budget (USD) <DocLink path="/configuration/budgets/" label="Budget docs" /></label>
              <input id="budgetusd" className={s["form-input"]} type="number" min="0" step="0.01" value={budgetUsd} onChange={(e) => setBudgetUsd(e.target.value)} placeholder="unlimited" />
            </div>
            <div className={s["form-group"]}>
              <label htmlFor="budgetperiod" className={s["form-label"]}>Budget Period</label>
              <select id="budgetperiod" className={s["form-input"]} value={budgetPeriod} onChange={(e) => setBudgetPeriod(e.target.value as BudgetPeriod)} disabled={budgetUsd === ""}>
                <option value="monthly">Monthly</option>
                <option value="daily">Daily</option>
                <option value="total">Lifetime</option>
              </select>
            </div>
          </div>
          <div className={s["form-row"]}>
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
              <label htmlFor="raterequests" className={s["form-label"]} style={{ display: "flex", alignItems: "center", gap: 6 }}>Rate Limit (req) <DocLink path="/configuration/rate-limiting/" label="Rate limiting docs" /></label>
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
          <hr className={s.divider} />
          <div className={s["form-group"]}>
            <label className={s["form-label"]}>Provider Base URLs</label>
            <p className={s["form-hint"]} style={{ marginBottom: 8 }}>Override the upstream URL for a provider (e.g. Ollama on a custom host/port).</p>
            {baseUrls.map((entry, i) => (
              <div key={i} className={s["form-row"]} style={{ marginBottom: 6 }}>
                <input
                  className={s["form-input"]}
                  placeholder="provider (e.g. ollama)"
                  value={entry.provider}
                  onChange={(e) => setBaseUrls((prev) => prev.map((r, j) => j === i ? { ...r, provider: e.target.value } : r))}
                  style={{ flex: "0 0 140px" }}
                />
                <input
                  className={s["form-input"]}
                  placeholder="http://host:port"
                  value={entry.url}
                  onChange={(e) => setBaseUrls((prev) => prev.map((r, j) => j === i ? { ...r, url: e.target.value } : r))}
                />
                <button
                  type="button"
                  className={`${s.btn} ${s["btn--secondary"]}`}
                  style={{ flex: "none", padding: "0 10px" }}
                  onClick={() => setBaseUrls((prev) => prev.filter((_, j) => j !== i))}
                >✕</button>
              </div>
            ))}
            <button
              type="button"
              className={`${s.btn} ${s["btn--secondary"]}`}
              style={{ marginTop: 4, fontSize: 12 }}
              onClick={() => setBaseUrls((prev) => [...prev, { provider: "", url: "" }])}
            >+ Add URL override</button>
          </div>
          <hr className={s.divider} />
          <div className={s["form-group"]}>
            <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer" }}>
              <input type="checkbox" checked={cbEnabled} onChange={(e) => setCbEnabled(e.target.checked)} />
              <span className={s["form-label"]} style={{ margin: 0 }}>Circuit Breaker</span>
              <DocLink path="/routing/circuit-breaker/" label="Circuit breaker docs" />
            </label>
            <p className={s["form-hint"]} style={{ marginTop: 4 }}>
              Automatically stops routing to a provider after repeated failures, then probes after a cooldown.
            </p>
            {cbEnabled && (
              <div style={{ marginTop: 10 }}>
                <div className={s["form-row"]}>
                  <div className={s["form-group"]}>
                    <label className={s["form-label"]}>Failure threshold</label>
                    <input className={s["form-input"]} type="number" min="1" max="100" value={cbThreshold}
                      onChange={(e) => setCbThreshold(e.target.value)} />
                    <p className={s["form-hint"]}>Failures before opening (default 5)</p>
                  </div>
                  <div className={s["form-group"]}>
                    <label className={s["form-label"]}>Window (s)</label>
                    <input className={s["form-input"]} type="number" min="10" value={cbWindow}
                      onChange={(e) => setCbWindow(e.target.value)} />
                    <p className={s["form-hint"]}>Sliding window for counting failures (default 60)</p>
                  </div>
                  <div className={s["form-group"]}>
                    <label className={s["form-label"]}>Cooldown (ms)</label>
                    <input className={s["form-input"]} type="number" min="1000" step="1000" value={cbCooldown}
                      onChange={(e) => setCbCooldown(e.target.value)} />
                    <p className={s["form-hint"]}>Wait before probing after open (default 30000)</p>
                  </div>
                </div>
              </div>
            )}
          </div>
          <hr className={s.divider} />
          {/* Webhooks */}
          <div className={s["form-group"]}>
            <label className={s["form-label"]}>Webhook</label>
            <p className={s["form-hint"]} style={{ marginBottom: 8 }}>
              Receive HTTP POST notifications on gateway events. Leave URL blank to disable.
            </p>
            <input
              className={s["form-input"]}
              placeholder="https://hooks.example.com/ai-gateway"
              value={webhookUrl}
              onChange={(e) => setWebhookUrl(e.target.value)}
              style={{ marginBottom: 8 }}
            />
            {webhookUrl.trim() && (
              <>
                <input
                  className={s["form-input"]}
                  placeholder="Signing secret (optional — adds X-AIG-Signature header)"
                  value={webhookSecret}
                  onChange={(e) => setWebhookSecret(e.target.value)}
                  style={{ marginBottom: 8 }}
                />
                <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
                  {(["blocked", "budget_exceeded", "circuit_open"] as WebhookEvent[]).map((ev) => (
                    <label key={ev} style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer", fontSize: 13 }}>
                      <input
                        type="checkbox"
                        checked={webhookEvents.includes(ev)}
                        onChange={(e) => setWebhookEvents((prev) =>
                          e.target.checked ? [...prev, ev] : prev.filter((x) => x !== ev)
                        )}
                      />
                      <span>{ev}</span>
                    </label>
                  ))}
                </div>
              </>
            )}
          </div>
          <hr className={s.divider} />
          {/* SIEM */}
          <div className={s["form-group"]}>
            <label className={s["form-label"]} style={{ display: "flex", alignItems: "center", gap: 6 }}>SIEM Integration <DocLink path="/configuration/siem/" label="SIEM docs" /></label>
            <p className={s["form-hint"]} style={{ marginBottom: 8 }}>
              Stream security events to an external SIEM. Overrides any tenant-level SIEM config.
            </p>
            <select
              className={s["form-input"]}
              value={siemType}
              onChange={(e) => setSiemType(e.target.value as SiemType | "")}
              style={{ marginBottom: 8 }}
            >
              <option value="">— disabled —</option>
              <option value="splunk_hec">Splunk HEC</option>
              <option value="elasticsearch">Elasticsearch / OpenSearch</option>
              <option value="vector">Vector</option>
              <option value="syslog">Syslog / CEF</option>
            </select>
            {siemType && (
              <>
                <div style={{ display: "flex", flexDirection: "column", gap: 6, marginBottom: 8 }}>
                  <label className={s["form-label"]} style={{ fontSize: 12, marginBottom: 2 }}>Events to forward</label>
                  {(["blocked", "guardrail", "scrubbed", "all"] as SiemEvent[]).map((ev) => (
                    <label key={ev} style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer", fontSize: 13 }}>
                      <input
                        type="checkbox"
                        checked={siemEvents.includes(ev)}
                        onChange={(e) => setSiemEvents((prev) =>
                          e.target.checked ? [...prev, ev] : prev.filter((x) => x !== ev)
                        )}
                      />
                      <span>{ev === "all" ? "all (every request)" : ev}</span>
                    </label>
                  ))}
                </div>
                {(siemType === "splunk_hec" || siemType === "elasticsearch" || siemType === "vector") && (
                  <>
                    <input className={s["form-input"]} placeholder="URL" value={siemUrl}
                      onChange={(e) => setSiemUrl(e.target.value)} style={{ marginBottom: 8 }} />
                    {siemType === "splunk_hec" && (
                      <>
                        <input className={s["form-input"]} placeholder="HEC Token" value={siemToken}
                          onChange={(e) => setSiemToken(e.target.value)} style={{ marginBottom: 8 }} />
                        <input className={s["form-input"]} placeholder="Index (optional)" value={siemIndex}
                          onChange={(e) => setSiemIndex(e.target.value)} style={{ marginBottom: 8 }} />
                      </>
                    )}
                    {siemType === "elasticsearch" && (
                      <>
                        <input className={s["form-input"]} placeholder="Index (e.g. aig-logs)" value={siemIndex}
                          onChange={(e) => setSiemIndex(e.target.value)} style={{ marginBottom: 8 }} />
                        <input className={s["form-input"]} placeholder="Username (optional)" value={siemUsername}
                          onChange={(e) => setSiemUsername(e.target.value)} style={{ marginBottom: 8 }} />
                        <input className={s["form-input"]} type="password" placeholder="Password" value={siemPassword}
                          onChange={(e) => setSiemPassword(e.target.value)} style={{ marginBottom: 8 }} />
                      </>
                    )}
                  </>
                )}
                {siemType === "syslog" && (
                  <>
                    <input className={s["form-input"]} placeholder="Host" value={siemHost}
                      onChange={(e) => setSiemHost(e.target.value)} style={{ marginBottom: 8 }} />
                    <div className={s["form-row"]} style={{ marginBottom: 8 }}>
                      <div className={s["form-group"]} style={{ margin: 0 }}>
                        <label className={s["form-label"]} style={{ fontSize: 12 }}>Port</label>
                        <input className={s["form-input"]} type="number" min={1} max={65535} value={siemPort}
                          onChange={(e) => setSiemPort(e.target.value)} />
                      </div>
                      <div className={s["form-group"]} style={{ margin: 0 }}>
                        <label className={s["form-label"]} style={{ fontSize: 12 }}>Protocol</label>
                        <select className={s["form-input"]} value={siemProtocol}
                          onChange={(e) => setSiemProtocol(e.target.value as "udp" | "tcp")}>
                          <option value="udp">UDP</option>
                          <option value="tcp">TCP</option>
                        </select>
                      </div>
                      <div className={s["form-group"]} style={{ margin: 0 }}>
                        <label className={s["form-label"]} style={{ fontSize: 12 }}>Format</label>
                        <select className={s["form-input"]} value={siemFormat}
                          onChange={(e) => setSiemFormat(e.target.value as "cef" | "rfc5424")}>
                          <option value="cef">CEF</option>
                          <option value="rfc5424">RFC 5424</option>
                        </select>
                      </div>
                    </div>
                  </>
                )}
              </>
            )}
          </div>
          <hr className={s.divider} />
          {/* Web Search */}
          <div className={s["form-group"]}>
            <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer" }}>
              <input type="checkbox" checked={wsEnabled} onChange={(e) => setWsEnabled(e.target.checked)} />
              <span className={s["form-label"]} style={{ margin: 0 }}>Web Search (Brave)</span>
            </label>
            <p className={s["form-hint"]} style={{ marginTop: 4 }}>
              Enable server-side web search for all requests on this gateway via the Brave Search API.
            </p>
            {wsEnabled && (
              <div style={{ marginTop: 8, display: "flex", flexDirection: "column", gap: 8 }}>
                <input
                  className={s["form-input"]}
                  type="password"
                  placeholder="Brave Search API key"
                  value={wsApiKey}
                  onChange={(e) => setWsApiKey(e.target.value)}
                  autoComplete="off"
                />
                <div className={s["form-row"]}>
                  <div>
                    <label className={s["form-label"]}>Max results</label>
                    <input
                      className={s["form-input"]}
                      type="number"
                      min={1}
                      max={20}
                      value={wsMaxResults}
                      onChange={(e) => setWsMaxResults(parseInt(e.target.value, 10) || 5)}
                    />
                  </div>
                </div>
              </div>
            )}
          </div>
          <hr className={s.divider} />
          {/* Prompt Caching (Anthropic) */}
          <div className={s["form-group"]}>
            <label className={s["form-label"]}>Anthropic Prompt Caching</label>
            <p className={s["form-hint"]} style={{ marginBottom: 8 }}>
              Inject <code>cache_control</code> breakpoints on the system prompt and conversation history so Anthropic
              reuses cached tokens across turns. Cache reads cost 0.1× standard input price.
              The 1 h TTL costs 2× write price vs 1.25× for 5 min — worthwhile for active sessions with many turns.
            </p>
            <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer", fontSize: 13, marginBottom: 8 }}>
              <input type="checkbox" checked={pcEnabled} onChange={(e) => setPcEnabled(e.target.checked)} />
              Enable prompt caching (Anthropic models only)
            </label>
            {pcEnabled && (
              <div className={s["form-group"]} style={{ margin: 0 }}>
                <label className={s["form-label"]}>Cache TTL</label>
                <select
                  className={s["form-input"]}
                  value={pcTtl}
                  onChange={(e) => setPcTtl(e.target.value as "5m" | "1h")}
                  style={{ width: 160 }}
                >
                  <option value="5m">5 minutes (1.25× write cost)</option>
                  <option value="1h">1 hour (2× write cost)</option>
                </select>
              </div>
            )}
          </div>

          {/* Request Tracing */}
          <div className={s["form-group"]}>
            <label className={s["form-label"]} style={{ display: "flex", alignItems: "center", gap: 6 }}>Request Tracing <DocLink path="/observability/tracing/" label="Tracing docs" /></label>
            <p className={s["form-hint"]} style={{ marginBottom: 8 }}>
              Record a full step-by-step trace for every request — received, transformed, routed, upstream call, and delivery.
            </p>
            <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer", fontSize: 13, marginBottom: 8 }}>
              <input type="checkbox" checked={tracingEnabled} onChange={(e) => setTracingEnabled(e.target.checked)} />
              Enable request tracing
            </label>
            {tracingEnabled && (
              <>
                <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer", fontSize: 13, marginBottom: 8 }}>
                  <input type="checkbox" checked={tracingBodies} onChange={(e) => setTracingBodies(e.target.checked)} />
                  Include message bodies in trace (privacy-sensitive — off by default)
                </label>
                <div className={s["form-group"]} style={{ margin: 0 }}>
                  <label className={s["form-label"]}>Retention (hours)</label>
                  <input
                    className={s["form-input"]}
                    type="number"
                    min={1}
                    max={720}
                    value={tracingRetention}
                    onChange={(e) => setTracingRetention(e.target.value)}
                    style={{ width: 100 }}
                  />
                </div>
              </>
            )}
          </div>
          <div className={s["form-actions"]}>
            <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
            <button type="submit" className={`${s.btn} ${s["btn--primary"]}`} disabled={loading}>
              {loading ? "Saving…" : "Save Changes"}
            </button>
          </div>
        </form>
    </Modal>
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
  const [showKey, setShowKey] = useState(false);

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
    <Modal title="Add / Rotate Provider Key" onClose={onClose} error={error}>
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
                <div style={{ position: "relative" }}>
                  <input
                    id="apikey"
                    className={s["form-input"]}
                    type={showKey ? "text" : "password"}
                    autoComplete="off"
                    value={apiKey}
                    onChange={(e) => setApiKey(e.target.value)}
                    placeholder="Paste API key…"
                    style={{ paddingRight: "2.5rem" }}
                    required
                  />
                  <button
                    type="button"
                    onClick={() => setShowKey((v) => !v)}
                    style={{ position: "absolute", right: 8, top: "50%", transform: "translateY(-50%)", background: "none", border: "none", cursor: "pointer", color: "var(--text-secondary)", padding: 2 }}
                    title={showKey ? "Hide" : "Show"}
                  >
                    {showKey
                      ? <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94"/><path d="M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19"/><line x1="1" y1="1" x2="23" y2="23"/></svg>
                      : <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg>
                    }
                  </button>
                </div>
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
    </Modal>
  );
}

function CreateTokenModal({ gatewayId, onClose, onCreated }: {
  gatewayId: string; onClose: () => void; onCreated: () => void;
}) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [newToken, setNewToken] = useState<string | null>(null);
  const [expiresAt, setExpiresAt] = useState("");
  const [label, setLabel] = useState("");
  const [budgetUsd, setBudgetUsd] = useState("");
  const [rateRequests, setRateRequests] = useState("");
  const [rateWindow, setRateWindow] = useState("60");
  const [copied, setCopied] = useState(false);

  async function handleCreate() {
    setLoading(true); setError(null);
    try {
      const body: any = { expires_at: expiresAt || null };
      if (label.trim()) body.label = label.trim();
      if (budgetUsd !== "") body.budget_usd = parseFloat(budgetUsd);
      if (rateRequests !== "") body.rate_limit = { requests: parseInt(rateRequests), window_sec: parseInt(rateWindow) || 60 };
      const res = await api.post<{ token: string }>(`/gateways/${gatewayId}/tokens`, body);
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
    <Modal title={newToken ? "Token Created" : "Create Auth Token"} onClose={onClose} error={error} disableOverlayClose={!!newToken}>
        {newToken ? (
          <>
            <p style={{ color: "var(--text-secondary)", marginBottom: 12, fontSize: 14 }}>
              Copy this token now. It will <strong>not</strong> be shown again.
            </p>
            <div className={s["token-reveal"]} title="Click to copy" style={{ cursor: "pointer" }} onClick={copyToken}>{newToken}</div>
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
              <label htmlFor="tokenlabel" className={s["form-label"]}>Label (optional)</label>
              <input id="tokenlabel" className={s["form-input"]} value={label} onChange={(e) => setLabel(e.target.value)} placeholder="e.g. ci-pipeline" />
            </div>
            <div className={s["form-group"]}>
              <label htmlFor="expiresat" className={s["form-label"]}>Expires At (optional)</label>
              <input id="expiresat" className={s["form-input"]} type="datetime-local" value={expiresAt} onChange={(e) => setExpiresAt(e.target.value)} />
              <p className={s["form-hint"]}>Leave blank for a non-expiring token.</p>
            </div>
            <div className={s["form-group"]}>
              <label htmlFor="tokenbudget" className={s["form-label"]}>Spend cap (USD, optional)</label>
              <input id="tokenbudget" className={s["form-input"]} type="number" min="0" step="0.01" value={budgetUsd} onChange={(e) => setBudgetUsd(e.target.value)} placeholder="unlimited" />
              <p className={s["form-hint"]}>Block this token once cumulative cost exceeds this amount.</p>
            </div>
            <div className={s["form-row"]}>
              <div className={s["form-group"]}>
                <label htmlFor="tokenrateReq" className={s["form-label"]}>Rate limit (req, optional)</label>
                <input id="tokenrateReq" className={s["form-input"]} type="number" min="1" value={rateRequests} onChange={(e) => setRateRequests(e.target.value)} placeholder="unlimited" />
              </div>
              <div className={s["form-group"]}>
                <label htmlFor="tokenrateWin" className={s["form-label"]}>Window (s)</label>
                <input id="tokenrateWin" className={s["form-input"]} type="number" min="1" value={rateWindow} onChange={(e) => setRateWindow(e.target.value)} />
              </div>
            </div>
            <div className={s["form-actions"]}>
              <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
              <button className={`${s.btn} ${s["btn--primary"]}`} onClick={handleCreate} disabled={loading}>
                {loading ? "Generating…" : "Generate Token"}
              </button>
            </div>
          </>
        )}
    </Modal>
  );
}

function RuleModal({ gatewayId, rule, onClose, onSaved }: {
  gatewayId: string; rule?: RoutingRule; onClose: () => void; onSaved: () => void;
}) {
  const isEdit = !!rule;
  const isLb = !!rule?.actions?.load_balance;

  const [priority, setPriority] = useState(String(rule?.priority ?? 0));
  const [enabled, setEnabled] = useState(rule ? rule.enabled === 1 : true);
  const [actionMode, setActionMode] = useState<"direct" | "load_balance">(isLb ? "load_balance" : "direct");
  const [conditions, setConditions] = useState<Array<{ field: string; op: string; value: string }>>(
    rule?.conditions ?? []
  );
  // Direct route state
  const [provider, setProvider] = useState(rule?.actions?.provider ?? "");
  const [model, setModel] = useState(rule?.actions?.model ?? "");
  const [fallbacks, setFallbacks] = useState<Array<{ provider: string; model: string }>>(
    rule?.actions?.fallbacks ?? []
  );
  // Load balance state
  const [lbStrategy, setLbStrategy] = useState<"weighted_random" | "round_robin">(
    rule?.actions?.load_balance?.strategy ?? "weighted_random"
  );
  const [lbStickyField, setLbStickyField] = useState(rule?.actions?.load_balance?.sticky?.field ?? "");
  const [lbStickyTtl, setLbStickyTtl] = useState(String(rule?.actions?.load_balance?.sticky?.ttl ?? 3600));
  const [lbTargets, setLbTargets] = useState<Array<{ provider: string; model: string; weight: number }>>(
    rule?.actions?.load_balance?.targets ?? [{ provider: "", model: "", weight: 1 }]
  );

  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  function addCondition() { setConditions([...conditions, { field: "model", op: "eq", value: "" }]); }
  function removeCondition(i: number) { setConditions(conditions.filter((_, idx) => idx !== i)); }
  function updateCondition(i: number, key: string, val: string) {
    setConditions(conditions.map((c, idx) => idx === i ? { ...c, [key]: val } : c));
  }
  function addFallback() { setFallbacks([...fallbacks, { provider: "", model: "" }]); }
  function removeFallback(i: number) { setFallbacks(fallbacks.filter((_, idx) => idx !== i)); }
  function updateFallback(i: number, key: string, val: string) {
    setFallbacks(fallbacks.map((f, idx) => idx === i ? { ...f, [key]: val } : f));
  }
  function addLbTarget() { setLbTargets([...lbTargets, { provider: "", model: "", weight: 1 }]); }
  function removeLbTarget(i: number) { setLbTargets(lbTargets.filter((_, idx) => idx !== i)); }
  function updateLbTarget(i: number, key: string, val: string | number) {
    setLbTargets(lbTargets.map((t, idx) => idx === i ? { ...t, [key]: val } : t));
  }

  // Compute effective traffic split percentages for LB preview
  const lbTotalWeight = lbTargets.reduce((sum, t) => sum + (t.weight > 0 ? t.weight : 0), 0);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true); setError(null);
    try {
      let actions: RoutingRule["actions"];
      if (actionMode === "load_balance") {
        const lb: LoadBalanceConfig = {
          strategy: lbStrategy,
          targets: lbTargets.map((t) => ({ ...t, weight: Number(t.weight) || 0 })),
        };
        if (lbStickyField.trim()) {
          lb.sticky = { field: lbStickyField.trim(), ttl: parseInt(lbStickyTtl) || 3600 };
        }
        actions = { load_balance: lb };
      } else {
        actions = {
          provider: provider || undefined,
          model: model || undefined,
          fallbacks: fallbacks.length > 0 ? fallbacks : undefined,
        };
      }
      const payload = { priority: parseInt(priority) || 0, enabled, conditions, actions };
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
    <Modal
      title={<><span>{isEdit ? "Edit Rule" : "New Routing Rule"}</span><DocLink path="/routing/routing-rules/" label="Routing rules docs" /></>}
      onClose={onClose}
      error={error}
      modalStyle={{ maxWidth: 640 }}
    >
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

          {/* Action mode toggle */}
          <div className={s["form-group"]}>
            <label className={s["form-label"]}>Action</label>
            <div style={{ display: "flex", gap: 8, marginBottom: 12 }}>
              <button type="button"
                className={`${s.btn} ${actionMode === "direct" ? s["btn--primary"] : s["btn--secondary"]}`}
                style={{ fontSize: 12, padding: "4px 12px" }}
                onClick={() => setActionMode("direct")}>
                Direct route
              </button>
              <button type="button"
                className={`${s.btn} ${actionMode === "load_balance" ? s["btn--primary"] : s["btn--secondary"]}`}
                style={{ fontSize: 12, padding: "4px 12px" }}
                onClick={() => setActionMode("load_balance")}>
                Load balance
              </button>
            </div>

            {actionMode === "direct" && (
              <>
                <div className={s["form-row"]}>
                  <div className={s["form-group"]}>
                    <label htmlFor="provider" className={s["form-label"]}>Provider</label>
                    <input id="provider" className={s["form-input"]} value={provider} onChange={(e) => setProvider(e.target.value)} placeholder="e.g. anthropic" />
                  </div>
                  <div className={s["form-group"]}>
                    <label htmlFor="model" className={s["form-label"]}>Model</label>
                    <input id="model" className={s["form-input"]} value={model} onChange={(e) => setModel(e.target.value)} placeholder="e.g. claude-sonnet-4-6" />
                  </div>
                </div>
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
              </>
            )}

            {actionMode === "load_balance" && (
              <>
                <div className={s["form-row"]} style={{ marginBottom: 8 }}>
                  <div className={s["form-group"]}>
                    <label className={s["form-label"]}>Strategy</label>
                    <select className={s["form-select"]} value={lbStrategy} onChange={(e) => setLbStrategy(e.target.value as any)}>
                      <option value="weighted_random">Weighted random</option>
                      <option value="round_robin">Round robin</option>
                    </select>
                  </div>
                  <div className={s["form-group"]}>
                    <label className={s["form-label"]}>Sticky field (optional)</label>
                    <input className={s["form-input"]} value={lbStickyField} onChange={(e) => setLbStickyField(e.target.value)} placeholder="e.g. meta.user_id" />
                    <p className={s["form-hint"]}>Routes same value to same target for TTL seconds</p>
                  </div>
                  {lbStickyField.trim() && (
                    <div className={s["form-group"]}>
                      <label className={s["form-label"]}>Sticky TTL (s)</label>
                      <input className={s["form-input"]} type="number" min="1" value={lbStickyTtl} onChange={(e) => setLbStickyTtl(e.target.value)} />
                    </div>
                  )}
                </div>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 8 }}>
                  <label className={s["form-label"]} style={{ margin: 0 }}>Targets</label>
                  <button type="button" className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={addLbTarget}>+ Add target</button>
                </div>
                {lbTargets.map((t, i) => {
                  const pct = lbTotalWeight > 0 && t.weight > 0
                    ? Math.round((t.weight / lbTotalWeight) * 100)
                    : 0;
                  return (
                    <div key={i} style={{ display: "flex", gap: 6, marginBottom: 6, alignItems: "center" }}>
                      <input className={s["form-input"]} style={{ flex: 1 }} value={t.provider} onChange={(e) => updateLbTarget(i, "provider", e.target.value)} placeholder="provider" />
                      <input className={s["form-input"]} style={{ flex: 2 }} value={t.model} onChange={(e) => updateLbTarget(i, "model", e.target.value)} placeholder="model" />
                      <input className={s["form-input"]} style={{ width: 60 }} type="number" min="0" max="100" value={t.weight} onChange={(e) => updateLbTarget(i, "weight", parseInt(e.target.value) || 0)} title="Weight (0 = disabled)" />
                      <span style={{ fontSize: 11, color: t.weight > 0 ? "var(--text-secondary)" : "var(--text-muted, #aaa)", whiteSpace: "nowrap", minWidth: 36 }}>
                        {t.weight > 0 ? `${pct}%` : "off"}
                      </span>
                      <button type="button" className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={() => removeLbTarget(i)}>×</button>
                    </div>
                  );
                })}
                <p className={s["form-hint"]}>Weight 0 disables a target without removing it. Non-selected active targets are tried as fallbacks on failure.</p>
              </>
            )}
          </div>

          <div className={s["form-actions"]}>
            <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
            <button type="submit" className={`${s.btn} ${s["btn--primary"]}`} disabled={loading}>
              {loading ? "Saving…" : (isEdit ? "Save Rule" : "Create Rule")}
            </button>
          </div>
        </form>
    </Modal>
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
  const [guardrails, setGuardrails] = useState<DetectorConfig[]>(() => {
    const g = initialGw.config.guardrails;
    return Array.isArray(g) ? g : ((initialGw.config as any).detectors ?? []);
  });
  const [guardrailsChanged, setGuardrailsChanged] = useState(false);
  const [savingGuardrails, setSavingGuardrails] = useState(false);
  const [guardrailsError, setGuardrailsError] = useState<string | null>(null);
  const [guardrailsSaved, setGuardrailsSaved] = useState(false);
  const [guardrailStats, setGuardrailStats] = useState<GatewayGuardrailStats | null>(null);
  const [guardrailEvents, setGuardrailEvents] = useState<GuardrailEvent[]>([]);
  const [showGuardrailEvents, setShowGuardrailEvents] = useState(false);
  const [cbStatus, setCbStatus] = useState<CircuitBreakerStatus | null>(null);
  const [providerNames, setProviderNames] = useState<string[]>([]);

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

  function loadGuardrailStats() {
    api.get<GatewayGuardrailStats>(`/gateways/${gw.id}/guardrail-stats`).then(setGuardrailStats).catch(() => {});
  }
  function loadGuardrailEvents() {
    api.get<GuardrailEvent[]>(`/gateways/${gw.id}/guardrail-events`).then(setGuardrailEvents).catch(() => {});
  }
  function loadCbStatus() {
    if (gw.config.circuit_breaker?.enabled) {
      api.get<CircuitBreakerStatus>(`/gateways/${gw.id}/circuit-breaker`).then(setCbStatus).catch(() => {});
    }
  }

  useEffect(() => {
    loadTokens(); loadKeys(); loadRules(); loadGuardrailStats(); loadCbStatus();
    api.get<ProviderMeta[]>("/providers")
      .then((list) => setProviderNames(["compat", ...list.map((p) => p.name)]))
      .catch(() => {});
  }, [gw.id]);

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

  async function saveGuardrails() {
    setSavingGuardrails(true); setGuardrailsError(null); setGuardrailsSaved(false);
    try {
      const newConfig = { ...gw.config, guardrails };
      await api.patch(`/gateways/${gw.id}`, { config: newConfig });
      setGw({ ...gw, config: newConfig });
      setGuardrailsChanged(false);
      setGuardrailsSaved(true);
      setTimeout(() => setGuardrailsSaved(false), 3000);
    } catch (err: any) { setGuardrailsError(err.message); }
    finally { setSavingGuardrails(false); }
  }

  const LS_SECTIONS_KEY = `aig-gw-sections-${gw.id}`;
  const [collapsed, setCollapsed] = useState<Record<string, boolean>>(() => {
    try { return JSON.parse(localStorage.getItem(LS_SECTIONS_KEY) ?? "{}"); }
    catch { return {}; }
  });

  function toggleSection(name: string) {
    setCollapsed((prev) => {
      const next = { ...prev, [name]: !prev[name] };
      localStorage.setItem(LS_SECTIONS_KEY, JSON.stringify(next));
      return next;
    });
  }

  function SectionToggle({ name }: { name: string }) {
    return (
      <button
        onClick={() => toggleSection(name)}
        title={collapsed[name] ? "Expand" : "Collapse"}
        style={{ background: "none", border: "none", cursor: "pointer", color: "var(--text-secondary)", padding: "2px 4px", fontSize: 14, lineHeight: 1 }}
        aria-label={collapsed[name] ? "Expand section" : "Collapse section"}
      >
        {collapsed[name] ? "▶" : "▼"}
      </button>
    );
  }

  const cfg = gw.config;
  const [endpointProvider, setEndpointProvider] = useState("compat");
  const [copied, setCopied] = useState(false);
  const gatewayBase = import.meta.env.VITE_GATEWAY_URL ?? window.location.origin;
  const endpointUrl = `${gatewayBase}/v1/${tenantSlug}/${gw.slug}/${endpointProvider}/chat/completions`;

  function copyEndpoint() {
    navigator.clipboard.writeText(endpointUrl).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    });
  }

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
          <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
            <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={() => setShowEdit(true)}>Edit</button>
            <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={deleteGateway} disabled={deleting}>
              {deleting ? "Deleting…" : "Delete"}
            </button>
            <SectionToggle name="gateway" />
          </div>
        </div>
        {!collapsed["gateway"] && <><div className={s["stats-grid"]}>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Budget</div>
            <div className={s["stat-value"]}>{fmtCost(cfg.budget_usd)}</div>
            {cfg.budget_usd != null && (
              <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} style={{ marginTop: 6 }} onClick={resetBudget} disabled={budgetResetting}>
                {budgetResetting ? "…" : "Reset Spend"}
              </button>
            )}
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Cache TTL</div>
            <div className={s["stat-value"]}>{fmtSec(cfg.cache_ttl ?? 0)}</div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Retries</div>
            <div className={s["stat-value"]}>{cfg.retry_count ?? 2}</div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Timeout</div>
            <div className={s["stat-value"]}>{fmtMs(cfg.timeout_ms ?? 120000)}</div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Auth</div>
            <div className={s["stat-value"]}>{cfg.auth_required !== false ? "required" : "open"}</div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Rate Limit</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`}>
              {cfg.rate_limit ? `${fmtNumber(cfg.rate_limit.requests)}/${cfg.rate_limit.window_sec}s` : "—"}
            </div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Log Payloads</div>
            <div className={s["stat-value"]}>{cfg.log_payloads !== false ? "yes" : "no"}</div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Webhook</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`} style={{ fontSize: 11 }}>
              {cfg.webhooks?.url
                ? <span title={cfg.webhooks.url}>{cfg.webhooks.events?.join(", ") ?? "all events"}</span>
                : <span style={{ color: "var(--text-secondary)" }}>—</span>}
            </div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Tracing</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`} style={{ fontSize: 11 }}>
              {(cfg as any).tracing?.enabled
                ? <span style={{ color: "#10b981" }}>on{(cfg as any).tracing?.include_bodies ? " + bodies" : ""}</span>
                : <span style={{ color: "var(--text-secondary)" }}>off</span>}
            </div>
          </div>
          <div className={s["stat-card"]}>
            <div className={s["stat-label"]}>Web Search</div>
            <div className={`${s["stat-value"]} ${s["stat-value--text"]}`} style={{ fontSize: 11 }}>
              {cfg.web_search?.enabled
                ? <span style={{ color: "#10b981" }}>on</span>
                : <span style={{ color: "var(--text-secondary)" }}>off</span>}
            </div>
          </div>
        </div>
        <div className={s["form-group"]} style={{ marginTop: 12 }}>
          <label className={s["form-label"]}>Endpoint URL</label>
          <div style={{ display: "flex", gap: 8, alignItems: "center", marginBottom: 6 }}>
            <select
              className={s["form-input"]}
              style={{ width: "auto" }}
              value={endpointProvider}
              onChange={(e) => setEndpointProvider(e.target.value)}
            >
              {(providerNames.length > 0 ? providerNames : ["compat"]).map((p) => (
                <option key={p} value={p}>{p}</option>
              ))}
            </select>
          </div>
          <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
            <div className={s["code"]} style={{ flex: 1, padding: "8px 12px", fontSize: 12, wordBreak: "break-all" }}>{endpointUrl}</div>
            <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={copyEndpoint} style={{ whiteSpace: "nowrap" }}>
              {copied ? "Copied!" : "Copy"}
            </button>
          </div>
        </div></>}
      </div>

      {/* Provider Keys */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Provider Keys</h2>
          <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
            <button className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`} onClick={() => setShowAddKey(true)}>+ Add / Rotate</button>
            <SectionToggle name="keys" />
          </div>
        </div>
        {!collapsed["keys"] && (keys.length === 0 ? (
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
                    <td className={s.mono}>{fmtDate(k.created_at)}</td>
                    <td>
                      <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={() => deleteKey(k.provider, k.alias)}>Delete</button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ))}
      </div>

      {/* Auth Tokens */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Auth Tokens</h2>
          <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
            <button className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`} onClick={() => setShowCreateToken(true)}>+ Generate</button>
            <SectionToggle name="tokens" />
          </div>
        </div>
        {!collapsed["tokens"] && (loadingTokens ? (
          <div className={s.empty}>Loading…</div>
        ) : tokens.length === 0 ? (
          <div className={s.empty}>No tokens yet. Generate one to allow access to this gateway. <a href={docsUrl("/api-reference/users-tokens/")} target="_blank" rel="noopener noreferrer" style={{ color: "var(--text-secondary)" }}>Learn more</a></div>
        ) : (
          <div className={s["table-wrapper"]}>
            <table className={s.table}>
              <thead>
                <tr><th>Label</th><th>Hash (first 16)</th><th>Rate Limit</th><th>Spend Cap</th><th>Expires</th><th>Created</th><th></th></tr>
              </thead>
              <tbody>
                {tokens.map((t) => (
                  <tr key={t.id}>
                    <td><span className={s.code}>{t.label ?? <span style={{ color: "var(--text-secondary)" }}>—</span>}</span></td>
                    <td className={s.mono} style={{ fontSize: 11 }}>{t.token_hash.slice(0, 16)}…</td>
                    <td style={{ fontSize: 12 }}>
                      {t.rate_limit ? `${fmtNumber(t.rate_limit.requests)}/${t.rate_limit.window_sec}s` : <span style={{ color: "var(--text-secondary)" }}>—</span>}
                    </td>
                    <td style={{ fontSize: 12 }}>
                      {t.budget_usd != null ? fmtCost(t.budget_usd) : <span style={{ color: "var(--text-secondary)" }}>—</span>}
                    </td>
                    <td>{t.expires_at ? fmtDateTime(t.expires_at) : <span style={{ color: "var(--text-secondary)" }}>never</span>}</td>
                    <td className={s.mono}>{fmtDate(t.created_at)}</td>
                    <td><button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={() => deleteToken(t.id)}>Revoke</button></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ))}
      </div>

      {/* Guardrails */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
            <h2 className={s["card-title"]}>Guardrails</h2>
            <DocLink path="/security/guardrails/" label="Guardrails docs" />
          </div>
          <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
            {guardrailsSaved && <span style={{ fontSize: 12, color: "var(--badge-success-text)" }}>Saved</span>}
            <button
              className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`}
              onClick={saveGuardrails}
              disabled={savingGuardrails || !guardrailsChanged}
            >
              {savingGuardrails ? "Saving…" : "Save Guardrails"}
            </button>
            <SectionToggle name="guardrails" />
          </div>
        </div>
        {!collapsed["guardrails"] && <>{guardrailStats && (guardrailStats.blocked > 0 || guardrailStats.scrubbed > 0 || guardrailStats.flagged > 0 || guardrailStats.avg_guardrail_ms > 0) && (
          <div style={{ display: "flex", gap: 16, padding: "8px 0 12px", fontSize: 13, color: "var(--text-secondary)" }}>
            {guardrailStats.blocked > 0 && (
              <span><span className={`${s.badge} ${s["badge--error"]}`}>{fmtNumber(guardrailStats.blocked)} blocked</span></span>
            )}
            {guardrailStats.scrubbed > 0 && (
              <span><span className={`${s.badge} ${s["badge--warning"]}`}>{fmtNumber(guardrailStats.scrubbed)} scrubbed</span></span>
            )}
            {guardrailStats.flagged > 0 && (
              <span><span className={`${s.badge} ${s["badge--neutral"]}`}>{fmtNumber(guardrailStats.flagged)} flagged</span></span>
            )}
            {guardrailStats.avg_guardrail_ms > 0 && (
              <span style={{ marginLeft: "auto" }}>avg {guardrailStats.avg_guardrail_ms} ms guardrail latency · last 24h</span>
            )}
          </div>
        )}
        {guardrailsError && <div className={`${s.alert} ${s["alert--error"]}`}>{guardrailsError}</div>}
        <GuardrailBuilder
          value={guardrails}
          onChange={(d) => { setGuardrails(d); setGuardrailsChanged(true); }}
        />
        {/* Recent activity */}
        <div style={{ marginTop: 16 }}>
          <button
            className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
            onClick={() => {
              if (!showGuardrailEvents) loadGuardrailEvents();
              setShowGuardrailEvents((v) => !v);
            }}
          >
            {showGuardrailEvents ? "Hide" : "Show"} recent activity
          </button>
          {showGuardrailEvents && (
            guardrailEvents.length === 0 ? (
              <p style={{ fontSize: 13, color: "var(--text-muted, #888)", marginTop: 12 }}>
                No guardrail events recorded for this gateway yet.
              </p>
            ) : (
              <div className={s["table-wrapper"]} style={{ marginTop: 12 }}>
                <table className={s.table}>
                  <thead>
                    <tr>
                      <th>Time</th>
                      <th>Outcome</th>
                      <th>Detectors</th>
                      <th>Reason</th>
                      <th>Guardrail ms</th>
                      <th>Total ms</th>
                    </tr>
                  </thead>
                  <tbody>
                    {guardrailEvents.map((ev, i) => {
                      const outcome = ev.blocked ? "blocked" : ev.scrub_applied ? "scrubbed" : "flagged";
                      const variant = outcome === "blocked" ? s["badge--error"] : outcome === "scrubbed" ? s["badge--warning"] : s["badge--neutral"];
                      return (
                        <tr key={i} className={outcome === "blocked" ? s.blocked : ""}>
                          <td className={s.mono} style={{ fontSize: 11 }}>{fmtDateTime(ev.ts)}</td>
                          <td><span className={`${s.badge} ${variant}`}>{outcome}</span></td>
                          <td style={{ fontSize: 11 }}>
                            {ev.detectors_fired.length > 0 ? ev.detectors_fired.join(", ") : (ev.blocked_by ?? "—")}
                          </td>
                          <td style={{ fontSize: 11, maxWidth: 220 }}>{ev.block_reason ?? "—"}</td>
                          <td>{ev.guardrail_latency_ms != null ? `${ev.guardrail_latency_ms} ms` : "—"}</td>
                          <td>{ev.latency_ms} ms</td>
                        </tr>
                      );
                    })}
                  </tbody>
                </table>
              </div>
            )
          )}
        </div>
        </>}
      </div>

      {/* Routing Rules */}
      <div className={s.card}>
        <div className={s["card-header"]}>
          <h2 className={s["card-title"]}>Routing Rules</h2>
          <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
            <button className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`} onClick={() => setShowNewRule(true)}>+ New Rule</button>
            <SectionToggle name="rules" />
          </div>
        </div>
        {!collapsed["rules"] && (rules.length === 0 ? (
          <div className={s.empty}>No routing rules. Add rules to override default provider routing. <a href={docsUrl("/routing/routing-rules/")} target="_blank" rel="noopener noreferrer" style={{ color: "var(--text-secondary)" }}>Learn more</a></div>
        ) : (
          <div className={s["table-wrapper"]}>
            <table className={s.table}>
              <thead>
                <tr><th>Priority</th><th>Conditions</th><th>Action</th><th>Status</th><th></th></tr>
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
                      {r.actions.load_balance ? (
                        <div>
                          <span className={`${s.badge} ${s["badge--info"]}`} style={{ marginBottom: 4, display: "inline-block" }}>
                            load balance · {r.actions.load_balance.strategy ?? "weighted_random"}
                          </span>
                          {(() => {
                            const targets = r.actions.load_balance.targets ?? [];
                            const total = targets.reduce((s, t) => s + (t.weight > 0 ? t.weight : 0), 0);
                            return targets.map((t, i) => (
                              <div key={i} style={{ display: "flex", alignItems: "center", gap: 4 }}>
                                <span className={s.code}>{t.provider}/{t.model}</span>
                                <span style={{ color: "var(--text-secondary)", fontSize: 11 }}>
                                  {t.weight > 0 ? `${Math.round(t.weight / total * 100)}%` : <em>off</em>}
                                </span>
                              </div>
                            ));
                          })()}
                        </div>
                      ) : (
                        <div>
                          {r.actions.provider && <span className={s.code}>{r.actions.provider}</span>}
                          {r.actions.model && <> / <span className={s.code}>{r.actions.model}</span></>}
                          {(r.actions.fallbacks ?? []).map((f, i) => (
                            <div key={i} style={{ color: "var(--text-secondary)", fontSize: 11 }}>↳ {f.provider}/{f.model}</div>
                          ))}
                        </div>
                      )}
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
        ))}
      </div>

      {/* Circuit Breaker Status */}
      {gw.config.circuit_breaker?.enabled && (
        <div className={s.card}>
          <div className={s["card-header"]}>
            <h2 className={s["card-title"]}>Circuit Breaker</h2>
            <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
              <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={loadCbStatus}>Refresh</button>
              <SectionToggle name="cb" />
            </div>
          </div>
          {!collapsed["cb"] && <>
            {!cbStatus || Object.keys(cbStatus).length === 0 ? (
              <div className={s.empty}>All providers are healthy (no open breakers).</div>
            ) : (
              <div className={s["table-wrapper"]}>
                <table className={s.table}>
                  <thead>
                    <tr><th>Provider</th><th>State</th><th>Failures</th><th>Opened at</th></tr>
                  </thead>
                  <tbody>
                    {Object.entries(cbStatus).map(([prov, info]) => (
                      <tr key={prov}>
                        <td><span className={s.code}>{prov}</span></td>
                        <td>
                          <span className={`${s.badge} ${
                            info.state === "closed" ? s["badge--success"] :
                            info.state === "open"   ? s["badge--error"] :
                            s["badge--warning"]
                          }`}>
                            {info.state}
                          </span>
                        </td>
                        <td>{fmtNumber(info.failures)}</td>
                        <td style={{ fontSize: 12, color: "var(--text-secondary)" }}>
                          {info.opened_at
                            ? new Date(info.opened_at * 1000).toLocaleTimeString()
                            : "—"}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            <p className={s["form-hint"]} style={{ padding: "8px 16px" }}>
              Threshold: {fmtNumber(gw.config.circuit_breaker.failure_threshold ?? 5)} failures in {gw.config.circuit_breaker.window_sec ?? 60}s ·
              Cooldown: {fmtMs(gw.config.circuit_breaker.cooldown_ms ?? 30000)}
            </p>
          </>}
        </div>
      )}
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
    api.get<Tenant[]>("/tenants").then((ts) => {
      setTenants(ts);
      // Auto-select the only tenant so the user doesn't have to click it manually
      if (!tenantId && ts.length === 1) {
        navigate(`/tenants/${ts[0].id}/gateways`, { replace: true });
      }
    });
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
            <div className={s.empty}>No gateways for <strong>{selectedTenant.slug}</strong> yet. <a href={docsUrl("/getting-started/quick-start/")} target="_blank" rel="noopener noreferrer" style={{ color: "var(--text-secondary)" }}>Quick start guide</a></div>
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
                    <td>{fmtCost(g.config.budget_usd)}</td>
                    <td>{fmtSec(g.config.cache_ttl ?? 0)}</td>
                    <td style={{ fontSize: 12 }}>
                      {g.config.rate_limit ? `${fmtNumber(g.config.rate_limit.requests)}/${g.config.rate_limit.window_sec}s` : "—"}
                    </td>
                    <td>
                      {(Array.isArray(g.config.guardrails) ? g.config.guardrails : ((g.config as any).detectors ?? [])).length > 0 ? (
                        <span className={`${s.badge} ${s["badge--warning"]}`}>
                          {(Array.isArray(g.config.guardrails) ? g.config.guardrails : ((g.config as any).detectors ?? [])).length}
                        </span>
                      ) : (
                        <span className={`${s.badge} ${s["badge--neutral"]}`}>—</span>
                      )}
                    </td>
                    <td className={s.mono}>{fmtDate(g.created_at)}</td>
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
