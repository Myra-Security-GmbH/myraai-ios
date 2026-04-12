import type { Artifact } from "./ArtifactPanel";
import s from "../pages/Chat.module.scss";

/** Pick a visual icon based on file extension */
function fileIcon(filename: string, lang: string): string {
  const ext = filename.split(".").pop()?.toLowerCase() ?? lang.toLowerCase();
  if (["html", "htm", "svg", "xml"].includes(ext)) return "🌐";
  if (["css", "scss", "sass", "less"].includes(ext)) return "🎨";
  if (["json", "yaml", "yml", "toml", "ini", "env"].includes(ext)) return "⚙️";
  if (["md", "markdown", "txt", "rst"].includes(ext)) return "📝";
  if (["csv", "tsv", "xls", "xlsx", "ods"].includes(ext)) return "📊";
  if (["sql"].includes(ext)) return "🗄️";
  if (["sh", "bash", "zsh", "ps1"].includes(ext)) return "💻";
  return "📄";
}

function DownloadIcon() {
  return (
    <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
      <polyline points="8 17 12 21 16 17" />
      <line x1="12" y1="12" x2="12" y2="21" />
      <path d="M20.88 18.09A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.36" />
    </svg>
  );
}

interface Props {
  filename: string;
  lang: string;
  code: string;
  isStreaming: boolean;
  onOpen: () => void;
}

export function ArtifactCard({ filename, lang, code, isStreaming, onOpen }: Props) {
  const icon = fileIcon(filename, lang);
  const langLabel = lang.toUpperCase() || filename.split(".").pop()?.toUpperCase() || "FILE";

  function handleDownload(e: React.MouseEvent) {
    e.stopPropagation();
    const artifact: Artifact = { lang, code, complete: true, filename };
    const ext = filename.split(".").pop()?.toLowerCase() ?? lang.toLowerCase();
    const mimeMap: Record<string, string> = {
      py: "text/x-python", js: "text/javascript", ts: "text/typescript",
      tsx: "text/typescript", jsx: "text/javascript", lua: "text/x-lua",
      sh: "text/x-sh", sql: "text/x-sql", json: "application/json",
      yaml: "text/yaml", yml: "text/yaml", xml: "text/xml",
      html: "text/html", svg: "image/svg+xml", css: "text/css",
      md: "text/markdown", txt: "text/plain", csv: "text/csv",
    };
    const mime = mimeMap[ext] ?? "text/plain";
    const blob = new Blob([artifact.code], { type: mime });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url; a.download = filename; a.click();
    URL.revokeObjectURL(url);
  }

  if (isStreaming) {
    return (
      <div className={`${s["artifact-card"]} ${s["artifact-card--generating"]}`} data-cy="artifact-card-generating">
        <span className={s["artifact-card-spinner"]} />
        <div className={s["artifact-card-info"]}>
          <div className={s["artifact-card-filename"]}>{filename}</div>
          <div className={s["artifact-card-generating-label"]}>Generating…</div>
        </div>
      </div>
    );
  }

  return (
    <div
      className={s["artifact-card"]}
      onClick={onOpen}
      role="button"
      tabIndex={0}
      onKeyDown={(e) => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); onOpen(); } }}
      data-cy="artifact-card"
    >
      <span className={s["artifact-card-icon"]}>{icon}</span>
      <div className={s["artifact-card-info"]}>
        <div className={s["artifact-card-filename"]}>{filename}</div>
        <div className={s["artifact-card-meta"]}>
          <span className={s["artifact-card-lang"]}>{langLabel}</span>
          <span className={s["artifact-card-hint"]}>Click to view ›</span>
        </div>
      </div>
      <div className={s["artifact-card-actions"]}>
        <button
          className={s["artifact-card-download-btn"]}
          onClick={handleDownload}
          title={`Download ${filename}`}
          type="button"
          data-cy="artifact-card-download"
        >
          <DownloadIcon /> Download
        </button>
      </div>
    </div>
  );
}
