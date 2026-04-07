import { useState } from "react";
import { api } from "src/api/client";
import type { ChatMemory } from "src/api/types";
import ls from "src/common/components/layout/Layout.module.scss";
import s from "../pages/Chat.module.scss";

interface Props {
  memories: ChatMemory[];
  activeConvId: string | null;
  onClose: () => void;
  onMemoriesChange: (memories: ChatMemory[]) => void;
  onConvMemoryDisabledChange: (convId: string, disabled: boolean) => void;
}

type MemType = ChatMemory["type"];

const TYPE_BADGE: Record<MemType, string> = {
  fact:        ls["badge--neutral"],
  preference:  ls["badge--neutral"],
  instruction: ls["badge--warning"],
};

export default function MemoriesPanel({ memories, activeConvId, onClose, onMemoriesChange, onConvMemoryDisabledChange }: Props) {
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editContent, setEditContent] = useState("");
  const [newContent, setNewContent] = useState("");
  const [newType, setNewType] = useState<MemType>("fact");
  const [adding, setAdding] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleDelete(id: string) {
    await api.delete(`/memories/${id}`).catch(() => {});
    onMemoriesChange(memories.filter(m => m.id !== id));
  }

  function startEdit(m: ChatMemory) {
    setEditingId(m.id);
    setEditContent(m.content);
  }

  async function saveEdit(id: string) {
    if (!editContent.trim()) return;
    await api.patch(`/memories/${id}`, { content: editContent.trim() }).catch(() => {});
    onMemoriesChange(memories.map(m => m.id === id ? { ...m, content: editContent.trim() } : m));
    setEditingId(null);
  }

  async function handleAdd() {
    if (!newContent.trim()) return;
    setAdding(true);
    setError(null);
    try {
      const m = await api.post<ChatMemory>("/memories", { content: newContent.trim(), type: newType, source: "manual" });
      onMemoriesChange([...memories, m]);
      setNewContent("");
    } catch {
      setError("Failed to save memory");
    } finally {
      setAdding(false);
    }
  }

  return (
    <div className={s["settings-overlay"]} onClick={e => e.target === e.currentTarget && onClose()}>
      <div className={s["settings-drawer"]} data-cy="memories-panel">

        {/* Header */}
        <div className={s["settings-header"]}>
          Memories {memories.length > 0 && <span style={{ fontWeight: 400, color: "var(--text-secondary)" }}>({memories.length})</span>}
          <button className={s["icon-btn"]} onClick={onClose} title="Close">×</button>
        </div>

        {/* Memory list */}
        <div className={s["settings-body"]}>
          {memories.length === 0 && (
            <p className={ls["empty"]} style={{ padding: "24px 0" }}>
              No memories yet. Add one below or start a conversation — the AI will remember things automatically.
            </p>
          )}

          {memories.map(m => (
            <div key={m.id} className={ls["card"]} style={{ padding: "10px 12px", marginBottom: 0 }}>
              <div style={{ display: "flex", alignItems: "flex-start", gap: 8 }}>
                <div style={{ flex: 1 }}>
                  {editingId === m.id ? (
                    <textarea
                      className={ls["form-input"]}
                      value={editContent}
                      onChange={e => setEditContent(e.target.value)}
                      autoFocus
                      rows={3}
                      style={{ width: "100%", resize: "vertical", fontSize: 13, boxSizing: "border-box" }}
                    />
                  ) : (
                    <p style={{ margin: 0, fontSize: 13, lineHeight: 1.5, cursor: "pointer", wordBreak: "break-word" }} onClick={() => startEdit(m)}>
                      {m.content}
                    </p>
                  )}
                  <div style={{ marginTop: 6, display: "flex", gap: 6, alignItems: "center" }}>
                    <span className={`${ls["badge"]} ${TYPE_BADGE[m.type as MemType] ?? ls["badge--neutral"]}`}>
                      {m.type}
                    </span>
                    {m.source === "auto" && (
                      <span className={`${ls["badge"]} ${ls["badge--success"]}`}>auto</span>
                    )}
                  </div>
                </div>
                <div style={{ display: "flex", flexDirection: "column", gap: 4, flexShrink: 0 }}>
                  {editingId === m.id ? (
                    <>
                      <button className={`${ls["btn"]} ${ls["btn--primary"]} ${ls["btn--sm"]}`} onClick={() => saveEdit(m.id)}>Save</button>
                      <button className={`${ls["btn"]} ${ls["btn--secondary"]} ${ls["btn--sm"]}`} onClick={() => setEditingId(null)}>Cancel</button>
                    </>
                  ) : (
                    <button
                      className={s["icon-btn"]}
                      title="Delete memory"
                      onClick={() => handleDelete(m.id)}
                      data-cy="memory-delete-btn"
                    >
                      ×
                    </button>
                  )}
                </div>
              </div>
            </div>
          ))}

          {/* Add memory */}
          <div style={{ marginTop: memories.length > 0 ? 8 : 0 }}>
            <div className={ls["form-group"]}>
              <textarea
                className={ls["form-input"]}
                value={newContent}
                onChange={e => setNewContent(e.target.value)}
                placeholder="Add a memory…"
                rows={2}
                style={{ width: "100%", resize: "none", fontSize: 13, boxSizing: "border-box" }}
                data-cy="memory-add-input"
              />
            </div>
            <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
              <select
                className={ls["form-select"]}
                value={newType}
                onChange={e => setNewType(e.target.value as MemType)}
                style={{ flex: 1, fontSize: 13 }}
              >
                <option value="fact">Fact</option>
                <option value="preference">Preference</option>
                <option value="instruction">Instruction</option>
              </select>
              <button
                className={`${ls["btn"]} ${ls["btn--primary"]} ${ls["btn--sm"]}`}
                onClick={handleAdd}
                disabled={adding || !newContent.trim()}
                data-cy="memory-add-btn"
              >
                {adding ? "Adding…" : "Add"}
              </button>
            </div>
            {error && <p className={`${ls["alert"]} ${ls["alert--error"]}`} style={{ marginTop: 8 }}>{error}</p>}
          </div>

          {/* Per-conversation toggle */}
          {activeConvId && (
            <label className={ls["form-hint"]} style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer", userSelect: "none" }}>
              <input
                type="checkbox"
                data-cy="memory-disabled-toggle"
                onChange={e => {
                  const disabled = e.target.checked;
                  api.patch(`/conversations/${activeConvId}`, { memory_disabled: disabled ? 1 : 0 }).catch(() => {});
                  onConvMemoryDisabledChange(activeConvId, disabled);
                }}
              />
              Don&apos;t use memories in this conversation
            </label>
          )}
        </div>
      </div>
    </div>
  );
}
