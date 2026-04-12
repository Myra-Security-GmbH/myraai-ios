import { useEffect, useState } from "react";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { api } from "src/api/client";
import { McpConnector, McpAuthType } from "src/api/types";
import { Modal } from "src/common/components/Modal";
import s from "src/common/components/layout/Layout.module.scss";

// ---------------------------------------------------------------------------
// Add / Edit modal
// ---------------------------------------------------------------------------
function ConnectorModal({
  initial,
  onClose,
  onSaved,
}: {
  initial?: McpConnector;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [name, setName] = useState(initial?.name ?? "");
  const [serverUrl, setServerUrl] = useState(initial?.server_url ?? "");
  const [authType, setAuthType] = useState<McpAuthType>(initial?.auth_type ?? "none");
  const [authValue, setAuthValue] = useState(initial?.auth_value ?? "");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [testing, setTesting] = useState(false);
  const [testResult, setTestResult] = useState<string | null>(null);

  // Load auth_value when editing (it's only returned on GET single)
  useEffect(() => {
    if (initial) {
      api.get<McpConnector>(`/mcp/${initial.id}`)
        .then((c) => setAuthValue(c.auth_value ?? ""))
        .catch(() => {});
    }
  }, [initial?.id]);

  async function handleTest() {
    if (!serverUrl.trim()) return;
    setTesting(true);
    setTestResult(null);
    try {
      // Use a saved connector if editing, otherwise POST a temporary call via a helper
      // For unsaved connectors, we skip the proxy and just attempt a direct JSON-RPC initialize
      const headers: Record<string, string> = { "Content-Type": "application/json" };
      if (authType === "bearer" && authValue.trim()) {
        headers["Authorization"] = `Bearer ${authValue.trim()}`;
      } else if (authType === "header" && authValue.trim()) {
        const [hn, ...hv] = authValue.split(":");
        if (hn && hv.length) headers[hn.trim()] = hv.join(":").trim();
      }
      const res = await fetch(serverUrl.trim(), {
        method: "POST",
        headers,
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "initialize", params: {} }),
        signal: AbortSignal.timeout(8000),
      });
      const text = await res.text();
      if (res.ok) {
        setTestResult("Connected ✓");
      } else {
        setTestResult(`HTTP ${res.status}: ${text.slice(0, 120)}`);
      }
    } catch (e: any) {
      setTestResult(`Error: ${e.message}`);
    } finally {
      setTesting(false);
    }
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!name.trim()) return setError("Name is required");
    if (!serverUrl.trim()) return setError("Server URL is required");
    setLoading(true);
    setError(null);
    const payload: Record<string, unknown> = {
      name: name.trim(),
      server_url: serverUrl.trim(),
      auth_type: authType,
      auth_value: authType !== "none" ? authValue.trim() || null : null,
    };
    try {
      if (initial) {
        await api.patch(`/mcp/${initial.id}`, payload);
      } else {
        await api.post("/mcp", payload);
      }
      onSaved();
    } catch (err: any) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }

  return (
    <Modal title={initial ? "Edit MCP Connector" : "New MCP Connector"} onClose={onClose} error={error}>
      <form onSubmit={handleSubmit}>
        <div className={s["form-group"]}>
          <label htmlFor="mcp-name" className={s["form-label"]}>Name *</label>
          <input
            id="mcp-name"
            className={s["form-input"]}
            value={name}
            onChange={(e) => setName(e.target.value)}
            placeholder="My Tools Server"
            required
            data-cy="mcp-name-input"
          />
        </div>
        <div className={s["form-group"]}>
          <label htmlFor="mcp-server-url" className={s["form-label"]}>Server URL *</label>
          <input
            id="mcp-server-url"
            className={s["form-input"]}
            value={serverUrl}
            onChange={(e) => setServerUrl(e.target.value)}
            placeholder="https://my-mcp-server.example.com/mcp"
            required
            type="url"
            data-cy="mcp-server-url-input"
          />
          <div className={s["form-hint"]}>JSON-RPC 2.0 endpoint of the MCP server.</div>
        </div>
        <div className={s["form-group"]}>
          <label className={s["form-label"]}>Authentication</label>
          <div className={s["picker-options"]} style={{ display: "flex", gap: 8, marginBottom: 8 }}>
            {(["none", "bearer", "header"] as McpAuthType[]).map((t) => (
              <button
                key={t}
                type="button"
                className={`${s["picker-btn"]} ${authType === t ? s["picker-btn--selected"] : ""}`}
                onClick={() => setAuthType(t)}
              >
                {t === "none" ? "None" : t === "bearer" ? "Bearer token" : "Custom header"}
              </button>
            ))}
          </div>
          {authType === "bearer" && (
            <input
              className={s["form-input"]}
              value={authValue}
              onChange={(e) => setAuthValue(e.target.value)}
              placeholder="Enter bearer token"
              type="password"
              autoComplete="off"
            />
          )}
          {authType === "header" && (
            <>
              <input
                className={s["form-input"]}
                value={authValue}
                onChange={(e) => setAuthValue(e.target.value)}
                placeholder="X-Api-Key: your-secret-value"
                autoComplete="off"
              />
              <div className={s["form-hint"]}>Format: <code>Header-Name: header-value</code></div>
            </>
          )}
        </div>
        <div className={s["form-group"]}>
          <button
            type="button"
            className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
            disabled={testing || !serverUrl.trim()}
            onClick={handleTest}
            data-cy="test-connection-btn"
          >
            {testing ? "Testing…" : "Test connection"}
          </button>
          {testResult && (
            <span
              style={{ marginLeft: 10, fontSize: 13, color: testResult.startsWith("Connected") ? "var(--color-success)" : "var(--color-error)" }}
              data-cy="test-result"
            >
              {testResult}
            </span>
          )}
        </div>
        <div className={s["form-actions"]}>
          <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
          <button type="submit" className={`${s.btn} ${s["btn--primary"]}`} disabled={loading} data-cy="save-connector-btn">
            {loading ? "Saving…" : initial ? "Save" : "Create"}
          </button>
        </div>
      </form>
    </Modal>
  );
}

// ---------------------------------------------------------------------------
// Main page
// ---------------------------------------------------------------------------
export default function MCPConnectors() {
  useDocumentTitle("MCP Connectors");
  const [connectors, setConnectors] = useState<McpConnector[]>([]);
  const [loading, setLoading] = useState(true);
  const [editing, setEditing] = useState<McpConnector | undefined>(undefined);
  const [showNew, setShowNew] = useState(false);

  async function load() {
    try {
      const rows = await api.get<McpConnector[]>("/mcp");
      setConnectors(rows);
    } catch {
      // ignore
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { load(); }, []);

  async function handleDelete(id: string) {
    if (!confirm("Delete this MCP connector? The model will no longer have access to its tools.")) return;
    await api.delete(`/mcp/${id}`);
    setConnectors((prev) => prev.filter((c) => c.id !== id));
  }

  function handleSaved() {
    setEditing(undefined);
    setShowNew(false);
    load();
  }

  const authBadge = (type: McpAuthType) => {
    if (type === "bearer") return <span className={`${s.badge} ${s["badge--success"]}`}>Bearer</span>;
    if (type === "header") return <span className={`${s.badge} ${s["badge--warning"]}`}>Header</span>;
    return <span className={`${s.badge} ${s["badge--neutral"]}`}>None</span>;
  };

  return (
    <div className={s.page}>
      <div className={s["page-header"]}>
        <div>
          <h1 className={s["page-title"]}>MCP Connectors</h1>
          <p className={s["page-subtitle"]}>
            Connect to Model Context Protocol servers so the AI can call external tools during chat.
          </p>
        </div>
        <button
          className={`${s.btn} ${s["btn--primary"]}`}
          onClick={() => setShowNew(true)}
          data-cy="new-connector-btn"
        >
          + New connector
        </button>
      </div>

      {loading ? (
        <div className={s.empty}>Loading…</div>
      ) : connectors.length === 0 ? (
        <div className={s.empty}>
          <p>No MCP connectors yet. Add one to give the AI access to external tools.</p>
        </div>
      ) : (
        <div className={s["table-wrapper"]}>
          <table className={s.table} data-cy="connectors-table">
            <thead>
              <tr>
                <th>Name</th>
                <th>Server URL</th>
                <th>Auth</th>
                <th>Created</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {connectors.map((c) => (
                <tr key={c.id} data-cy="connector-row">
                  <td data-cy="connector-name">{c.name}</td>
                  <td style={{ color: "var(--text-secondary)", fontFamily: "monospace", fontSize: 12 }}>
                    {c.server_url}
                  </td>
                  <td>{authBadge(c.auth_type)}</td>
                  <td style={{ color: "var(--text-secondary)", whiteSpace: "nowrap" }}>
                    {new Date(c.created_at).toLocaleDateString()}
                  </td>
                  <td style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                    <button
                      className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
                      style={{ marginRight: 6 }}
                      onClick={() => setEditing(c)}
                      data-cy="edit-connector-btn"
                    >
                      Edit
                    </button>
                    <button
                      className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`}
                      onClick={() => handleDelete(c.id)}
                      data-cy="delete-connector-btn"
                    >
                      Delete
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {showNew && <ConnectorModal onClose={() => setShowNew(false)} onSaved={handleSaved} />}
      {editing && <ConnectorModal initial={editing} onClose={() => setEditing(undefined)} onSaved={handleSaved} />}
    </div>
  );
}
