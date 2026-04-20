import { useEffect, useState } from "react";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { api } from "src/api/client";
import { ModelPrice } from "src/api/types";
import { fmtDate } from "src/common/utils/date";
import { Modal } from "src/common/components/Modal";
import s from "src/common/components/layout/Layout.module.scss";

const PROVIDERS = ["anthropic", "openai", "gemini", "mistral", "groq", "deepseek", "xai"];

function PriceModal({ price, onClose, onSaved }: {
  price?: ModelPrice; onClose: () => void; onSaved: () => void;
}) {
  const isEdit = !!price;
  const [provider, setProvider] = useState(price?.provider ?? "anthropic");
  const [model, setModel] = useState(price?.model ?? "");
  const [inputPer1k, setInputPer1k] = useState(price ? String(price.input_per_1k) : "");
  const [outputPer1k, setOutputPer1k] = useState(price ? String(price.output_per_1k) : "");
  const [cacheWrite, setCacheWrite] = useState(price?.cache_write_per_1k != null ? String(price.cache_write_per_1k) : "");
  const [cacheRead, setCacheRead] = useState(price?.cache_read_per_1k != null ? String(price.cache_read_per_1k) : "");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true); setError(null);
    try {
      await api.put("/model-prices", {
        provider,
        model,
        input_per_1k: parseFloat(inputPer1k),
        output_per_1k: parseFloat(outputPer1k),
        cache_write_per_1k: cacheWrite !== "" ? parseFloat(cacheWrite) : null,
        cache_read_per_1k: cacheRead !== "" ? parseFloat(cacheRead) : null,
      });
      onSaved(); onClose();
    } catch (err: any) { setError(err.message); }
    finally { setLoading(false); }
  }

  return (
    <Modal title={isEdit ? `Edit: ${price!.provider}/${price!.model}` : "New Model Price"} onClose={onClose} error={error}>
      <form onSubmit={handleSubmit}>
          <div className={s["form-row"]}>
            <div className={s["form-group"]}>
              <label htmlFor="provider" className={s["form-label"]}>Provider</label>
              <select id="provider" className={s["form-select"]} value={provider} onChange={(e) => setProvider(e.target.value)} disabled={isEdit}>
                {PROVIDERS.map((p) => <option key={p} value={p}>{p}</option>)}
              </select>
            </div>
            <div className={s["form-group"]}>
              <label htmlFor="model" className={s["form-label"]}>Model *</label>
              <input id="model" className={s["form-input"]} value={model} onChange={(e) => setModel(e.target.value)} placeholder="claude-sonnet-4-6" required disabled={isEdit} />
            </div>
          </div>
          <div className={s["form-row"]}>
            <div className={s["form-group"]}>
              <label htmlFor="inputper1k" className={s["form-label"]}>Input $/1K tokens *</label>
              <input id="inputper1k" className={s["form-input"]} type="number" step="any" min="0" value={inputPer1k} onChange={(e) => setInputPer1k(e.target.value)} placeholder="0.003" required />
            </div>
            <div className={s["form-group"]}>
              <label htmlFor="outputper1k" className={s["form-label"]}>Output $/1K tokens *</label>
              <input id="outputper1k" className={s["form-input"]} type="number" step="any" min="0" value={outputPer1k} onChange={(e) => setOutputPer1k(e.target.value)} placeholder="0.015" required />
            </div>
          </div>
          <div className={s["form-row"]}>
            <div className={s["form-group"]}>
              <label htmlFor="cachewrite" className={s["form-label"]}>Cache Write $/1K (optional)</label>
              <input id="cachewrite" className={s["form-input"]} type="number" step="any" min="0" value={cacheWrite} onChange={(e) => setCacheWrite(e.target.value)} placeholder="—" />
            </div>
            <div className={s["form-group"]}>
              <label htmlFor="cacheread" className={s["form-label"]}>Cache Read $/1K (optional)</label>
              <input id="cacheread" className={s["form-input"]} type="number" step="any" min="0" value={cacheRead} onChange={(e) => setCacheRead(e.target.value)} placeholder="—" />
            </div>
          </div>
          <div className={s["form-actions"]}>
            <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
            <button type="submit" className={`${s.btn} ${s["btn--primary"]}`} disabled={loading}>
              {loading ? "Saving…" : (isEdit ? "Save Changes" : "Add Price")}
            </button>
          </div>
        </form>
    </Modal>
  );
}

export default function ModelPrices() {
  useDocumentTitle("Model Prices");
  const [prices, setPrices] = useState<ModelPrice[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showAdd, setShowAdd] = useState(false);
  const [editing, setEditing] = useState<ModelPrice | null>(null);
  const [filterProvider, setFilterProvider] = useState("");
  const [syncing, setSyncing] = useState(false);
  const [syncResult, setSyncResult] = useState<string | null>(null);

  function load() {
    setLoading(true);
    api.get<ModelPrice[]>("/model-prices")
      .then(setPrices)
      .catch((e) => setError(e.message))
      .finally(() => setLoading(false));
  }

  useEffect(load, []);

  async function deletePrice(p: ModelPrice) {
    if (!confirm(`Delete pricing for ${p.provider}/${p.model}?`)) return;
    await api.delete(`/model-prices/${p.provider}/${p.model}`);
    load();
  }

  async function syncModels() {
    setSyncing(true); setSyncResult(null);
    try {
      const res = await api.post<{ results: Array<{ provider: string; added: number; updated: number; skipped: number; errors: string[] }> }>("/model-prices/sync", {});
      const total = res.results.reduce((acc, r) => acc + r.added, 0);
      const summary = res.results
        .filter((r) => r.added > 0 || r.errors.length > 0)
        .map((r) => `${r.provider}: +${r.added}${r.errors.length ? ` (${r.errors.length} errors)` : ""}`)
        .join(", ");
      setSyncResult(total > 0 ? `Synced: ${summary}` : "All models up to date");
      if (total > 0) load();
    } catch (e: unknown) { setSyncResult(`Sync failed: ${e instanceof Error ? e.message : String(e)}`); }
    finally { setSyncing(false); }
  }

  const displayed = filterProvider ? prices.filter((p) => p.provider === filterProvider) : prices;

  function fmt(n: number | null | undefined) {
    if (n == null) return "—";
    return `$${n.toFixed(6)}`;
  }

  return (
    <main className={s.page}>
      {showAdd && <PriceModal onClose={() => setShowAdd(false)} onSaved={load} />}
      {editing && <PriceModal price={editing} onClose={() => setEditing(null)} onSaved={load} />}

      <div className={s["page-header"]}>
        <div>
          <h1 className={s["page-title"]}>Model Prices</h1>
          <p className={s["page-subtitle"]}>{prices.length} entries — used for cost attribution</p>
        </div>
        <div style={{ display: "flex", gap: 8 }}>
          <button className={`${s.btn} ${s["btn--secondary"]}`} onClick={syncModels} disabled={syncing}>
            {syncing ? "Syncing…" : "Sync from Providers"}
          </button>
          <button className={`${s.btn} ${s["btn--primary"]}`} onClick={() => setShowAdd(true)}>
            + New Price
          </button>
        </div>
      </div>

      {syncResult && <div className={`${s.alert} ${syncResult.startsWith("Sync failed") ? s["alert--error"] : s["alert--success"]}`}>{syncResult}</div>}
      {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}

      <div className={s.card} style={{ padding: "12px 16px" }}>
        <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
          <label className={s["form-label"]} style={{ margin: 0 }}>Filter:</label>
          <button className={`${s.btn} ${!filterProvider ? s["btn--primary"] : s["btn--secondary"]} ${s["btn--sm"]}`} onClick={() => setFilterProvider("")}>All</button>
          {PROVIDERS.map((p) => (
            <button key={p} className={`${s.btn} ${filterProvider === p ? s["btn--primary"] : s["btn--secondary"]} ${s["btn--sm"]}`} onClick={() => setFilterProvider(p)}>{p}</button>
          ))}
        </div>
      </div>

      {loading ? (
        <div className={s.empty}>Loading…</div>
      ) : (
        <div className={s["table-wrapper"]}>
          <table className={s.table}>
            <thead>
              <tr>
                <th>Provider</th>
                <th>Model</th>
                <th>Input $/1K tokens</th>
                <th>Output $/1K tokens</th>
                <th>Cache Write $/1K</th>
                <th>Cache Read $/1K</th>
                <th>Updated</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {displayed.map((p) => (
                <tr key={`${p.provider}/${p.model}`}>
                  <td><span className={s.code}>{p.provider}</span></td>
                  <td className={s.mono} style={{ fontSize: 12 }}>{p.model}</td>
                  <td>{fmt(p.input_per_1k)}</td>
                  <td>{fmt(p.output_per_1k)}</td>
                  <td>{fmt(p.cache_write_per_1k)}</td>
                  <td>{fmt(p.cache_read_per_1k)}</td>
                  <td className={s.mono} style={{ fontSize: 11 }}>{fmtDate(p.updated_at)}</td>
                  <td style={{ display: "flex", gap: 6 }}>
                    <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={() => setEditing(p)}>Edit</button>
                    <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={() => deletePrice(p)}>Delete</button>
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
