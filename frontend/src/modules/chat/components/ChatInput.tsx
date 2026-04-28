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

// Single source of truth for supported attachment types.
// Adding a new format here automatically updates both the file picker filter
// and the tooltip — no other changes needed.
const SUPPORTED_ATTACHMENT_TYPES = [
  { label: "Images",      accept: "image/*" },
  { label: "PDF",         accept: ".pdf,application/pdf" },
  { label: "Word",        accept: ".docx,application/vnd.openxmlformats-officedocument.wordprocessingml.document" },
  { label: "Excel",       accept: ".xlsx,.xlsm,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,application/vnd.ms-excel.sheet.macroenabled.12" },
  { label: "PowerPoint",  accept: ".pptx,application/vnd.openxmlformats-officedocument.presentationml.presentation" },
  { label: "ODS",         accept: ".ods,application/vnd.oasis.opendocument.spreadsheet" },
  { label: "CSV/TSV",     accept: ".csv,.tsv,text/csv,text/tab-separated-values" },
  { label: "Text/Markdown", accept: "text/plain,.txt,.md,text/markdown" },
] as const;

const ATTACH_ACCEPT = SUPPORTED_ATTACHMENT_TYPES.map(t => t.accept).join(",");
const ATTACH_TITLE  = "Attach file — " + SUPPORTED_ATTACHMENT_TYPES.map(t => t.label).join(", ");

interface ProjectContext {
  icon: string;
  name: string;
  color: string;
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
  projectContext?: ProjectContext;
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
  projectContext,
}, ref) {
  const textareaRef = useRef<HTMLTextAreaElement>(null);
  const fileInputRef = useRef<HTMLInputElement>(null);

  useImperativeHandle(ref, () => ({
    focus: () => textareaRef.current?.focus(),
  }));

  // Command picker state
  const showPicker = value.startsWith("/") && !value.includes("\n") && !value.includes(" ") && (commands?.length ?? 0) > 0;
  const commandQuery = showPicker ? value.slice(1) : "";

  // Auto-resize textarea.
  // When value is empty (e.g. immediately after submission), we clear the inline
  // height and let CSS min-height:44px take over — no intermediate height:"auto"
  // that could trigger the browser's focus-scroll on the focused element.  The
  // focus-scroll with html.style.zoom applied (Vanadium desktop mode) scrolls the
  // visual viewport rather than the .thread container, lifting the layout.
  useEffect(() => {
    const el = textareaRef.current;
    if (!el) return;
    if (!value) {
      el.style.height = "";   // CSS min-height:44px handles the empty state
      return;
    }
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
      if (!isStreaming && !disabled && (value.trim() || pendingAttachments.length > 0)) onSend();
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

  function handlePaste(e: React.ClipboardEvent<HTMLTextAreaElement>) {
    if (!onAttach) return;
    // Try clipboardData.items first (Chrome, Edge, modern Safari)
    const items = e.clipboardData.items;
    for (let i = 0; i < items.length; i++) {
      if (items[i].type.startsWith("image/")) {
        e.preventDefault();
        const file = items[i].getAsFile();
        if (!file) continue;
        readAndAttach(file);
        return;
      }
    }
    // Fallback: clipboardData.files (Firefox, older browsers)
    const files = e.clipboardData.files;
    for (let i = 0; i < files.length; i++) {
      if (files[i].type.startsWith("image/")) {
        e.preventDefault();
        readAndAttach(files[i]);
        return;
      }
    }
  }

  function readAndAttach(file: File) {
    if (!onAttach) return;
    const reader = new FileReader();
    reader.onload = () => {
      const base64 = (reader.result as string).split(",")[1];
      const ext = file.type === "image/jpeg" ? "jpg" : file.type.replace("image/", "") || "png";
      const name = file.name && file.name !== "image.png"
        ? file.name
        : `screenshot-${new Date().toISOString().replace(/[:.]/g, "-").slice(0, 19)}.${ext}`;
      onAttach({ filename: name, mime_type: file.type, data: base64 });
    };
    reader.readAsDataURL(file);
  }

  return (
    <div className={s["input-area"]}>
      <div className={s["input-inner"]} style={{ position: "relative" }}>
        {projectContext && (
          <div style={{ marginBottom: 4 }}>
            <span
              className={s["project-pill"]}
              style={{ borderColor: projectContext.color ? `color-mix(in srgb, ${projectContext.color} 40%, transparent)` : undefined }}
            >
              {projectContext.icon} {projectContext.name}
            </span>
          </div>
        )}
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
                title={ATTACH_TITLE}
                onClick={() => fileInputRef.current?.click()}
                disabled={disabled || isStreaming}
                type="button"
              >
                <AttachIcon />
              </button>
              <input
                ref={fileInputRef}
                type="file"
                accept={ATTACH_ACCEPT}
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
            onPaste={handlePaste}
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
            onClick={isStreaming ? onStop : () => { if (!disabled && (value.trim() || pendingAttachments.length > 0)) onSend(); }}
            disabled={!isStreaming && (disabled || (!value.trim() && pendingAttachments.length === 0))}
            title={isStreaming ? "Stop generation" : "Send message"}
            data-cy={isStreaming ? "stop-button" : "send-button"}
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
