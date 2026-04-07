import { useState } from "react";
import type { ChatConversation } from "src/api/types";
import s from "../pages/Chat.module.scss";

function diffDays(iso: string): number {
  const d = new Date(iso);
  const now = new Date();
  const diffMs = now.getTime() - d.getTime();
  return Math.floor(diffMs / 86400000);
}

function fmtDate(iso: string) {
  const d = new Date(iso);
  const days = diffDays(iso);
  if (days === 0) return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  if (days === 1) return "Yesterday";
  if (days < 7) return d.toLocaleDateString([], { weekday: "short" });
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

function StarIcon({ filled }: { filled: boolean }) {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill={filled ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2" />
    </svg>
  );
}

function ArchiveIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="21 8 21 21 3 21 3 8" />
      <rect x="1" y="3" width="22" height="5" />
      <line x1="10" y1="12" x2="14" y2="12" />
    </svg>
  );
}

function UnarchiveIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <polyline points="21 8 21 21 3 21 3 8" />
      <rect x="1" y="3" width="22" height="5" />
      <polyline points="10 14 12 12 14 14" />
      <line x1="12" y1="12" x2="12" y2="17" />
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
  onStar: (id: string, starred: boolean) => void;
  onArchive: (id: string) => void;
  onUnarchive: (id: string) => void;
  showArchived: boolean;
  onToggleArchived: () => void;
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
  onStar,
  onArchive,
  onUnarchive,
  showArchived,
  onToggleArchived,
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

  // Split filtered list into recency buckets (only when not in archived view)
  const buckets: { label: string; items: ChatConversation[] }[] = [];
  if (!showArchived) {
    const starred  = filtered.filter((c) => c.starred === 1);
    const today    = filtered.filter((c) => c.starred !== 1 && diffDays(c.updated_at) === 0);
    const yesterday= filtered.filter((c) => c.starred !== 1 && diffDays(c.updated_at) === 1);
    const week     = filtered.filter((c) => c.starred !== 1 && diffDays(c.updated_at) > 1 && diffDays(c.updated_at) < 7);
    const older    = filtered.filter((c) => c.starred !== 1 && diffDays(c.updated_at) >= 7);
    if (starred.length)   buckets.push({ label: "Starred",           items: starred });
    if (today.length)     buckets.push({ label: "Today",             items: today });
    if (yesterday.length) buckets.push({ label: "Yesterday",         items: yesterday });
    if (week.length)      buckets.push({ label: "Previous 7 Days",   items: week });
    if (older.length)     buckets.push({ label: "Older",             items: older });
  } else {
    buckets.push({ label: "Archived", items: filtered });
  }

  function renderItem(conv: ChatConversation) {
    const isStarred = conv.starred === 1;
    return (
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
            {!showArchived && (
              <button
                className={[s["icon-btn"], s["conv-icon-btn"], isStarred ? s["conv-icon-btn--starred"] : ""].filter(Boolean).join(" ")}
                title={isStarred ? "Unstar" : "Star conversation"}
                onClick={(e) => { e.stopPropagation(); onStar(conv.id, !isStarred); }}
              >
                <StarIcon filled={isStarred} />
              </button>
            )}
            {showArchived ? (
              <button
                className={[s["icon-btn"], s["conv-icon-btn"]].join(" ")}
                title="Unarchive conversation"
                onClick={(e) => { e.stopPropagation(); onUnarchive(conv.id); }}
              >
                <UnarchiveIcon />
              </button>
            ) : (
              <button
                className={[s["icon-btn"], s["conv-icon-btn"]].join(" ")}
                title="Archive conversation"
                onClick={(e) => { e.stopPropagation(); onArchive(conv.id); }}
              >
                <ArchiveIcon />
              </button>
            )}
            <button
              className={[s["icon-btn"], s["conv-icon-btn"]].join(" ")}
              title="Delete conversation"
              onClick={(e) => { e.stopPropagation(); onDelete(conv.id); }}
            >
              <TrashIcon />
            </button>
          </div>
        )}
      </div>
    );
  }

  return (
    <>
      <div className={s["conv-sidebar-header"]}>
        <button className={s["conv-new-btn"]} onClick={onCreate} disabled={creating}>
          <PlusIcon />
          New Chat
        </button>
      </div>

      {!showArchived && (
        <div className={s["conv-search"]}>
          <input
            type="text"
            placeholder="Search…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            aria-label="Search conversations"
          />
        </div>
      )}

      <div className={s["conv-list"]} role="listbox" aria-label="Conversations">
        {buckets.map((bucket) => (
          <div key={bucket.label}>
            <div className={s["conv-bucket-label"]}>{bucket.label}</div>
            {bucket.items.map(renderItem)}
          </div>
        ))}
        {buckets.length === 0 && (
          <div className={s["conv-empty"]}>
            {search ? "No matches" : showArchived ? "No archived conversations" : "No conversations yet"}
          </div>
        )}
      </div>

      <button
        className={s["conv-archive-toggle"]}
        onClick={onToggleArchived}
        data-cy="conv-archive-toggle"
      >
        {showArchived ? "← Back to chats" : "Archived chats"}
      </button>
    </>
  );
}
