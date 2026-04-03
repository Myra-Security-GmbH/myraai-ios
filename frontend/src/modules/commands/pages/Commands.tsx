import { useEffect, useState } from "react";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { api } from "src/api/client";
import { SlashCommand } from "src/api/types";
import { Modal } from "src/common/components/Modal";
import s from "src/common/components/layout/Layout.module.scss";

// ---------------------------------------------------------------------------
// Detect {{variable}} placeholders in a template string
// ---------------------------------------------------------------------------
function extractVars(template: string): string[] {
  const found: string[] = [];
  const re = /\{\{(\w+)\}\}/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(template)) !== null) {
    if (!found.includes(m[1])) found.push(m[1]);
  }
  return found;
}

// ---------------------------------------------------------------------------
// Add / Edit modal
// ---------------------------------------------------------------------------
function CommandModal({
  initial,
  onClose,
  onSaved,
}: {
  initial?: SlashCommand;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [name, setName] = useState(initial?.name ?? "");
  const [description, setDescription] = useState(initial?.description ?? "");
  const [template, setTemplate] = useState(initial?.template ?? "");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const vars = extractVars(template);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!name.trim()) return setError("Name is required");
    if (!template.trim()) return setError("Template is required");
    setLoading(true);
    setError(null);
    try {
      if (initial) {
        await api.patch(`/chat-commands/${initial.id}`, { name: name.trim(), description, template });
      } else {
        await api.post("/chat-commands", { name: name.trim(), description, template });
      }
      onSaved();
    } catch (err: any) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }

  return (
    <Modal title={initial ? "Edit Command" : "New Command"} onClose={onClose} error={error}>
      <form onSubmit={handleSubmit}>
        <div className={s["form-group"]}>
          <label className={s["form-label"]}>Name *</label>
          <div style={{ display: "flex", alignItems: "center", gap: 4 }}>
            <span style={{ opacity: 0.5, fontFamily: "monospace" }}>/</span>
            <input
              className={s["form-input"]}
              value={name}
              onChange={(e) => setName(e.target.value.replace(/\s/g, "-").replace(/^\//, ""))}
              placeholder="command-name"
              required
              style={{ fontFamily: "monospace" }}
            />
          </div>
        </div>
        <div className={s["form-group"]}>
          <label className={s["form-label"]}>Description</label>
          <input
            className={s["form-input"]}
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            placeholder="Short description shown in picker"
          />
        </div>
        <div className={s["form-group"]}>
          <label className={s["form-label"]}>Template *</label>
          <textarea
            className={s["form-input"]}
            value={template}
            onChange={(e) => setTemplate(e.target.value)}
            rows={5}
            placeholder={"Use {{variable}} for placeholders.\nExample: Translate to {{language}}: {{text}}"}
            required
            style={{ resize: "vertical", fontFamily: "monospace", fontSize: 13 }}
          />
          {vars.length > 0 && (
            <div className={s["form-hint"]}>
              Variables detected: {vars.map((v) => <code key={v} style={{ marginRight: 6, background: "var(--surface-2)", padding: "1px 4px", borderRadius: 3 }}>{`{{${v}}}`}</code>)}
            </div>
          )}
        </div>
        <div className={s["form-actions"]}>
          <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Cancel</button>
          <button type="submit" className={`${s.btn} ${s["btn--primary"]}`} disabled={loading}>
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
export default function Commands() {
  useDocumentTitle("My Commands");
  const [commands, setCommands] = useState<SlashCommand[]>([]);
  const [loading, setLoading] = useState(true);
  const [editing, setEditing] = useState<SlashCommand | undefined>(undefined);
  const [showNew, setShowNew] = useState(false);

  async function load() {
    try {
      const rows = await api.get<SlashCommand[]>("/chat-commands");
      setCommands(rows);
    } catch {
      // ignore
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { load(); }, []);

  async function handleDelete(id: string) {
    if (!confirm("Delete this command?")) return;
    await api.delete(`/chat-commands/${id}`);
    setCommands((prev) => prev.filter((c) => c.id !== id));
  }

  function handleSaved() {
    setEditing(undefined);
    setShowNew(false);
    load();
  }

  return (
    <div className={s.page}>
      <div className={s["page-header"]}>
        <h1 className={s["page-title"]}>My Commands</h1>
        <button className={`${s.btn} ${s["btn--primary"]}`} onClick={() => setShowNew(true)}>+ New command</button>
      </div>

      {loading ? (
        <div className={s.empty}>Loading…</div>
      ) : commands.length === 0 ? (
        <div className={s.empty}>
          <p>No commands yet. Create one to use <code>/commandname</code> shortcuts in chat.</p>
        </div>
      ) : (
        <div className={s["table-wrapper"]}>
          <table className={s.table}>
            <thead>
              <tr>
                <th>Command</th>
                <th>Description</th>
                <th>Template</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {commands.map((cmd) => (
                <tr key={cmd.id}>
                  <td><code style={{ fontFamily: "monospace" }}>/{cmd.name}</code></td>
                  <td style={{ color: "var(--text-secondary)" }}>{cmd.description || "—"}</td>
                  <td style={{ maxWidth: 320, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", color: "var(--text-secondary)", fontFamily: "monospace", fontSize: 12 }}>
                    {cmd.template}
                  </td>
                  <td style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                    <button className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} style={{ marginRight: 6 }} onClick={() => setEditing(cmd)}>Edit</button>
                    <button className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={() => handleDelete(cmd.id)}>Delete</button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {showNew && <CommandModal onClose={() => setShowNew(false)} onSaved={handleSaved} />}
      {editing && <CommandModal initial={editing} onClose={() => setEditing(undefined)} onSaved={handleSaved} />}
    </div>
  );
}
