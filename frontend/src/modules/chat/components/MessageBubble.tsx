import { memo, useState } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import type { ChatMessage } from "src/api/types";
import AttachmentChip from "./AttachmentChip";
import s from "../pages/Chat.module.scss";

function fmtCost(usd: number | null) {
  if (usd == null || usd === 0) return null;
  if (usd < 0.0001) return `<$0.0001`;
  return `$${usd.toFixed(4)}`;
}

function fmtMs(ms: number | null) {
  if (ms == null) return null;
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

function CopyIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  );
}

function EditIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" />
      <path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z" />
    </svg>
  );
}

function RegenerateIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <polyline points="1 4 1 10 7 10" />
      <path d="M3.51 15a9 9 0 1 0 .49-3" />
    </svg>
  );
}

/** Try to parse content as JSON content-block array; fall back to plain string */
function parseContent(content: string): { type: "text" | "image_url"; text?: string; url?: string }[] {
  try {
    const parsed = JSON.parse(content);
    if (Array.isArray(parsed)) return parsed;
  } catch { /* not JSON */ }
  return [{ type: "text", text: content }];
}

interface Props {
  message: ChatMessage;
  isLast: boolean;
  isStreaming?: boolean;
  onCopy: (text: string) => void;
  onEdit?: (id: string, content: string) => void;
  onRegenerate?: () => void;
}

const MessageBubble = memo(function MessageBubble({
  message,
  isLast,
  isStreaming,
  onCopy,
  onEdit,
  onRegenerate,
}: Props) {
  const isUser = message.role === "user";
  const [editing, setEditing] = useState(false);
  const [editValue, setEditValue] = useState("");
  const [copied, setCopied] = useState(false);

  const blocks = parseContent(message.content);
  const textContent = blocks
    .filter((b) => b.type === "text")
    .map((b) => b.text ?? "")
    .join("\n");

  function handleCopy() {
    onCopy(textContent);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  }

  function startEdit() {
    setEditValue(textContent);
    setEditing(true);
  }

  function commitEdit() {
    if (onEdit && editValue.trim()) {
      onEdit(message.id, editValue.trim());
    }
    setEditing(false);
  }

  return (
    <div className={[s["bubble-row"], isUser ? s["user-row"] : ""].filter(Boolean).join(" ")}>
      <div className={s["bubble-avatar"]}>
        {isUser ? "U" : "AI"}
      </div>
      <div className={s["bubble-content"]}>
        {editing ? (
          <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            <textarea
              autoFocus
              value={editValue}
              onChange={(e) => setEditValue(e.target.value)}
              style={{
                width: "100%",
                minHeight: 80,
                padding: "8px 10px",
                fontSize: 14,
                fontFamily: "inherit",
                lineHeight: 1.5,
                border: "1px solid var(--accent, #0052cc)",
                borderRadius: 6,
                background: "var(--input-bg)",
                color: "var(--text-primary)",
                resize: "vertical",
                outline: "none",
                boxSizing: "border-box",
              }}
              onKeyDown={(e) => {
                if (e.key === "Escape") setEditing(false);
                if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) commitEdit();
              }}
            />
            <div style={{ display: "flex", gap: 6 }}>
              <button
                onClick={commitEdit}
                style={{
                  padding: "4px 12px",
                  fontSize: 12,
                  borderRadius: 5,
                  border: "none",
                  background: "var(--accent, #0052cc)",
                  color: "#fff",
                  cursor: "pointer",
                }}
              >
                Save
              </button>
              <button
                onClick={() => setEditing(false)}
                style={{
                  padding: "4px 12px",
                  fontSize: 12,
                  borderRadius: 5,
                  border: "1px solid var(--card-border)",
                  background: "transparent",
                  color: "var(--text-secondary)",
                  cursor: "pointer",
                }}
              >
                Cancel
              </button>
            </div>
          </div>
        ) : (
          <>
            {/* Render attachments above text for user messages */}
            {isUser && message.attachments && message.attachments.length > 0 && (
              <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginBottom: 6 }}>
                {message.attachments.map((att) => (
                  <AttachmentChip key={att.id} attachment={att} />
                ))}
              </div>
            )}

            <div className={s["bubble-text"]}>
              {isUser ? (
                <span style={{ whiteSpace: "pre-wrap" }}>{textContent}</span>
              ) : (
                <ReactMarkdown remarkPlugins={[remarkGfm]}>
                  {textContent}
                </ReactMarkdown>
              )}
              {isStreaming && isLast && <span className={s["streaming-cursor"]} />}
            </div>

            {/* Assistant metrics */}
            {!isUser && (message.input_tokens || message.output_tokens || message.cost_usd || message.latency_ms) && (
              <div className={s["bubble-meta"]}>
                {message.input_tokens != null && <span>{message.input_tokens}↑</span>}
                {message.output_tokens != null && <span>{message.output_tokens}↓</span>}
                {fmtCost(message.cost_usd) && <span>{fmtCost(message.cost_usd)}</span>}
                {fmtMs(message.latency_ms) && <span>{fmtMs(message.latency_ms)}</span>}
              </div>
            )}

            {/* Action buttons */}
            <div className={s["bubble-actions"]}>
              <button className={s["bubble-action-btn"]} onClick={handleCopy}>
                <CopyIcon />
                {copied ? "Copied!" : "Copy"}
              </button>
              {isUser && onEdit && (
                <button className={s["bubble-action-btn"]} onClick={startEdit}>
                  <EditIcon />
                  Edit
                </button>
              )}
              {!isUser && isLast && onRegenerate && !isStreaming && (
                <button className={s["bubble-action-btn"]} onClick={onRegenerate}>
                  <RegenerateIcon />
                  Regenerate
                </button>
              )}
            </div>
          </>
        )}
      </div>
    </div>
  );
});

export default MessageBubble;
