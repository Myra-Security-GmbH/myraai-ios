import type { ChatAttachment } from "src/api/types";

function FileIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
      <polyline points="14 2 14 8 20 8" />
    </svg>
  );
}

function XIcon() {
  return (
    <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
      <line x1="18" y1="6" x2="6" y2="18" />
      <line x1="6" y1="6" x2="18" y2="18" />
    </svg>
  );
}

interface Props {
  attachment: ChatAttachment | { filename: string; mime_type: string; data?: string };
  onRemove?: () => void;
}

export default function AttachmentChip({ attachment, onRemove }: Props) {
  const isImage = attachment.mime_type.startsWith("image/");

  return (
    <div
      style={{
        display: "inline-flex",
        alignItems: "center",
        gap: 5,
        padding: "3px 8px",
        borderRadius: 5,
        border: "1px solid var(--card-border)",
        background: "var(--table-row-hover)",
        fontSize: 12,
        color: "var(--text-primary)",
        maxWidth: 180,
        userSelect: "none",
      }}
    >
      {isImage && "data" in attachment && attachment.data ? (
        <img
          src={`data:${attachment.mime_type};base64,${attachment.data}`}
          alt={attachment.filename}
          style={{ width: 18, height: 18, objectFit: "cover", borderRadius: 2 }}
        />
      ) : (
        <FileIcon />
      )}
      <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap", flex: 1 }}>
        {attachment.filename}
      </span>
      {onRemove && (
        <button
          onClick={onRemove}
          style={{ background: "none", border: "none", cursor: "pointer", padding: 0, color: "var(--text-secondary)", display: "flex" }}
          title="Remove attachment"
        >
          <XIcon />
        </button>
      )}
    </div>
  );
}
