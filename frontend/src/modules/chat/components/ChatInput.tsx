import { useRef, useEffect, forwardRef, useImperativeHandle } from "react";
import AttachmentChip from "./AttachmentChip";
import { CommandPicker } from "./CommandPicker";
import { SlashCommand } from "src/api/types";
import s from "../pages/Chat.module.scss";

export interface ChatInputHandle {
  focus(): void;
}

function SendIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
      <line x1="22" y1="2" x2="11" y2="13" />
      <polygon points="22 2 15 22 11 13 2 9 22 2" />
    </svg>
  );
}

function StopIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
      <rect x="4" y="4" width="16" height="16" rx="2" />
    </svg>
  );
}

function AttachIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48" />
    </svg>
  );
}

export interface PendingAttachment {
  filename: string;
  mime_type: string;
  data: string; // base64
}

interface Props {
  value: string;
  onChange: (v: string) => void;
  onSend: () => void;
  onStop: () => void;
  isStreaming: boolean;
  disabled: boolean;
  pendingAttachments?: PendingAttachment[];
  onAttach?: (att: PendingAttachment) => void;
  onRemoveAttachment?: (idx: number) => void;
  commands?: SlashCommand[];
  onCommandSelect?: (cmd: SlashCommand) => void;
}

const ChatInput = forwardRef<ChatInputHandle, Props>(function ChatInput({
  value,
  onChange,
  onSend,
  onStop,
  isStreaming,
  disabled,
  pendingAttachments = [],
  onAttach,
  onRemoveAttachment,
  commands,
  onCommandSelect,
}, ref) {
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  useImperativeHandle(ref, () => ({
    focus: () => textareaRef.current?.focus(),
  }));

  // Command picker state
  const showPicker = value.startsWith("/") && !value.includes("\n") && !value.includes(" ") && (commands?.length ?? 0) > 0;
  const commandQuery = showPicker ? value.slice(1) : "";

  // Auto-resize textarea
  useEffect(() => {
    const el = textareaRef.current;
    if (!el) return;
    el.style.height = "auto";
    el.style.height = Math.min(el.scrollHeight, 200) + "px";
  }, [value]);

  function handleKeyDown(e: React.KeyboardEvent<HTMLTextAreaElement>) {
    // When the picker is open, arrow keys and Enter/Escape are handled by CommandPicker via global listener
    if (showPicker && (e.key === "ArrowDown" || e.key === "ArrowUp" || e.key === "Escape")) {
      e.preventDefault();
      return;
    }
    if (showPicker && e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      return; // CommandPicker handles Enter via global listener
    }
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      if (!isStreaming && !disabled && value.trim()) onSend();
    }
  }

  function handleFileChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0];
    if (!file || !onAttach) return;
    const reader = new FileReader();
    reader.onload = () => {
      const dataUrl = reader.result as string;
      // Strip data URL prefix to get raw base64
      const base64 = dataUrl.split(",")[1];
      onAttach({ filename: file.name, mime_type: file.type, data: base64 });
    };
    reader.readAsDataURL(file);
    // Reset so the same file can be re-selected
    e.target.value = "";
  }

  return (
    <div className={s["input-area"]}>
      <div className={s["input-inner"]} style={{ position: "relative" }}>
        {showPicker && onCommandSelect && (
          <CommandPicker
            query={commandQuery}
            commands={commands ?? []}
            onSelect={(cmd) => { onChange(""); onCommandSelect(cmd); }}
            onDismiss={() => onChange("")}
          />
        )}
        {pendingAttachments.length > 0 && (
          <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
            {pendingAttachments.map((att, idx) => (
              <AttachmentChip
                key={idx}
                attachment={att}
                onRemove={onRemoveAttachment ? () => onRemoveAttachment(idx) : undefined}
              />
            ))}
          </div>
        )}

        <div className={s["input-row"]}>
          {onAttach && (
            <>
              <button
                className={s["icon-btn"]}
                title="Attach image or PDF"
                onClick={() => fileInputRef.current?.click()}
                disabled={disabled || isStreaming}
                type="button"
              >
                <AttachIcon />
              </button>
              <input
                ref={fileInputRef}
                type="file"
                accept="image/*,.pdf,text/plain,.txt,.md,text/markdown,.docx,application/vnd.openxmlformats-officedocument.wordprocessingml.document,.csv,text/csv,.tsv,text/tab-separated-values,.xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,.xlsm,application/vnd.ms-excel.sheet.macroenabled.12,.ods,application/vnd.oasis.opendocument.spreadsheet"
                style={{ display: "none" }}
                onChange={handleFileChange}
              />
            </>
          )}

          <textarea
            ref={textareaRef}
            className={s["chat-textarea"]}
            value={value}
            onChange={(e) => onChange(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder="Message… (Enter to send)"
            disabled={disabled && !isStreaming}
            rows={1}
            aria-label="Message input"
            spellCheck={false}
            autoCorrect="off"
            autoCapitalize="off"
          />

          <button
            className={[s["send-btn"], isStreaming ? s["stop-btn"] : ""].filter(Boolean).join(" ")}
            onClick={isStreaming ? onStop : onSend}
            disabled={!isStreaming && (disabled || !value.trim())}
            title={isStreaming ? "Stop generation" : "Send message"}
            type="button"
          >
            {isStreaming ? <StopIcon /> : <SendIcon />}
          </button>
        </div>

        <div className={s["input-hint"]}>
          Enter to send · Shift+Enter for newline
        </div>
      </div>
    </div>
  );
});

export default ChatInput;
