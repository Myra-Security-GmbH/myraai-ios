import { useState } from "react";
import type { ChatConversation } from "src/api/types";
import s from "../pages/Chat.module.scss";

function fmtDate(iso: string) {
  const d = new Date(iso);
  const now = new Date();
  const diffMs = now.getTime() - d.getTime();
  const diffDays = Math.floor(diffMs / 86400000);
  if (diffDays === 0) return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  if (diffDays === 1) return "Yesterday";
  if (diffDays < 7) return d.toLocaleDateString([], { weekday: "short" });
  return d.toLocaleDateString([], { month: "short", day: "numeric" });
}

function PlusIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
      <line x1="12" y1="5" x2="12" y2="19" />
      <line x1="5" y1="12" x2="19" y2="12" />
    </svg>
  );
}

function TrashIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <polyline points="3 6 5 6 21 6" />
      <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6" />
      <path d="M10 11v6M14 11v6" />
    </svg>
  );
}

interface Props {
  conversations: ChatConversation[];
  activeId: string | null;
  onSelect: (id: string) => void;
  onCreate: () => void;
  onRename: (id: string, title: string) => void;
  onDelete: (id: string) => void;
  creating: boolean;
  streamingConvId?: string | null;
}

export default function ConversationList({
  conversations,
  activeId,
  onSelect,
  onCreate,
  onRename,
  onDelete,
  creating,
  streamingConvId,
}: Props) {
  const [search, setSearch] = useState("");
  const [renamingId, setRenamingId] = useState<string | null>(null);
  const [renameValue, setRenameValue] = useState("");

  const filtered = search
    ? conversations.filter((c) => c.title.toLowerCase().includes(search.toLowerCase()))
    : conversations;

  function startRename(conv: ChatConversation) {
    setRenamingId(conv.id);
    setRenameValue(conv.title);
  }

  function commitRename(id: string) {
    if (renameValue.trim()) onRename(id, renameValue.trim());
    setRenamingId(null);
  }

  return (
    <>
      <div className={s["conv-sidebar-header"]}>
        <button className={s["conv-new-btn"]} onClick={onCreate} disabled={creating}>
          <PlusIcon />
          New Chat
        </button>
      </div>

      <div className={s["conv-search"]}>
        <input
          type="text"
          placeholder="Search…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          aria-label="Search conversations"
        />
      </div>

      <div className={s["conv-list"]} role="listbox" aria-label="Conversations">
        {filtered.map((conv) => (
          <div
            key={conv.id}
            role="option"
            aria-selected={conv.id === activeId}
            className={[s["conv-item"], conv.id === activeId ? s.active : ""].filter(Boolean).join(" ")}
            onClick={() => renamingId !== conv.id && onSelect(conv.id)}
          >
            <div className={s["conv-item-info"]}>
              {renamingId === conv.id ? (
                <input
                  className={s["conv-rename-input"]}
                  value={renameValue}
                  autoFocus
                  onChange={(e) => setRenameValue(e.target.value)}
                  onBlur={() => commitRename(conv.id)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") commitRename(conv.id);
                    if (e.key === "Escape") setRenamingId(null);
                  }}
                  onClick={(e) => e.stopPropagation()}
                />
              ) : (
                <>
                  <div className={s["conv-item-title"]} onDoubleClick={() => startRename(conv)}>
                    {conv.title}
                    {conv.id === streamingConvId && (
                      <span className={s["streaming-dot"]} title="Streaming in background" />
                    )}
                  </div>
                  <div className={s["conv-item-date"]}>{fmtDate(conv.updated_at)}</div>
                </>
              )}
            </div>
            {renamingId !== conv.id && (
              <div className={s["conv-item-menu"]}>
                <button
                  className={s["icon-btn"]}
                  title="Delete conversation"
                  onClick={(e) => { e.stopPropagation(); onDelete(conv.id); }}
                  style={{ width: 24, height: 24 }}
                >
                  <TrashIcon />
                </button>
              </div>
            )}
          </div>
        ))}
        {filtered.length === 0 && (
          <div style={{ padding: "16px 12px", fontSize: 13, color: "var(--text-secondary)", textAlign: "center" }}>
            {search ? "No matches" : "No conversations yet"}
          </div>
        )}
      </div>
    </>
  );
}
