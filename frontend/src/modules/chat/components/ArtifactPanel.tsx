import { useState, useCallback } from "react";
import { api } from "src/api/client";
import s from "./ArtifactPanel.module.scss";

export interface Artifact {
  lang: string;       // any language — "html", "svg", "python", "typescript", etc.
  code: string;
  complete: boolean;
  filename?: string;  // the detected filename, e.g. "utils.py"
}

interface Props {
  artifact: Artifact;
  isStreaming?: boolean;
  onClose: () => void;
  /** When set, a "Save to Project" button appears in the header */
  projectId?: string;
  onSave?: (filename: string, content: string, lang: string) => void;
}

function CloseIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <line x1="18" y1="6" x2="6" y2="18" />
      <line x1="6" y1="6" x2="18" y2="18" />
    </svg>
  );
}

function PopoutIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
      <polyline points="15 3 21 3 21 9" />
      <line x1="10" y1="14" x2="21" y2="3" />
    </svg>
  );
}

function DownloadIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <polyline points="8 17 12 21 16 17" />
      <line x1="12" y1="12" x2="12" y2="21" />
      <path d="M20.88 18.09A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.36" />
    </svg>
  );
}

function SaveIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z" />
      <polyline points="17 21 17 13 7 13 7 21" />
      <polyline points="7 3 7 8 15 8" />
    </svg>
  );
}

function CopyIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  );
}

const PREVIEW_LANGS = new Set(["html", "svg"]);

function guessMimeType(lang: string, filename?: string): string {
  const ext = filename?.split(".").pop()?.toLowerCase() ?? lang.toLowerCase();
  const map: Record<string, string> = {
    py: "text/x-python", python: "text/x-python",
    js: "text/javascript", javascript: "text/javascript",
    ts: "text/typescript", typescript: "text/typescript",
    tsx: "text/typescript", jsx: "text/javascript",
    lua: "text/x-lua",
    sh: "text/x-sh", bash: "text/x-sh",
    sql: "text/x-sql",
    json: "application/json",
    yaml: "text/yaml", yml: "text/yaml",
    xml: "text/xml",
    html: "text/html", htm: "text/html",
    svg: "image/svg+xml",
    css: "text/css",
    md: "text/markdown", markdown: "text/markdown",
    txt: "text/plain",
    csv: "text/csv",
  };
  return map[ext] ?? "text/plain";
}

/** Build srcdoc for iframe — wraps SVG in minimal HTML so it renders properly */
function buildSrcdoc(artifact: Artifact): string {
  if (artifact.lang === "svg") {
    return (
      "<!DOCTYPE html><html><head><meta charset='utf-8'>" +
      "<style>html,body{margin:0;padding:0;display:flex;align-items:center;justify-content:center;" +
      "min-height:100vh;background:#fff;box-sizing:border-box;} svg{max-width:100%;height:auto;}</style>" +
      "</head><body>" +
      artifact.code +
      "</body></html>"
    );
  }
  return artifact.code;
}

function openInNewTab(srcdoc: string) {
  const blob = new Blob([srcdoc], { type: "text/html" });
  const url = URL.createObjectURL(blob);
  const win = window.open(url, "_blank");
  if (win) {
    setTimeout(() => URL.revokeObjectURL(url), 10_000);
  }
}

function downloadArtifact(artifact: Artifact) {
  const mime = guessMimeType(artifact.lang, artifact.filename);
  const blob = new Blob([artifact.code], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = artifact.filename ?? `artifact.${artifact.lang}`;
  a.click();
  URL.revokeObjectURL(url);
}

export default function ArtifactPanel({ artifact, isStreaming, onClose, projectId, onSave }: Props) {
  const generating = isStreaming && !artifact.complete;
  const canPreview = PREVIEW_LANGS.has(artifact.lang.toLowerCase());
  const [activeTab, setActiveTab] = useState<"code" | "preview">(canPreview ? "preview" : "code");
  const [codeCopied, setCodeCopied] = useState(false);
  const [saveState, setSaveState] = useState<"idle" | "saving" | "saved" | "error">("idle");

  const srcdoc = buildSrcdoc(artifact);
  const langLabel = artifact.lang.toUpperCase();
  const displayName = artifact.filename ?? langLabel;

  const handleCopy = useCallback(() => {
    navigator.clipboard.writeText(artifact.code);
    setCodeCopied(true);
    setTimeout(() => setCodeCopied(false), 1500);
  }, [artifact.code]);

  const handleSave = useCallback(async () => {
    if (!projectId || !artifact.filename) return;
    setSaveState("saving");
    try {
      const mime = guessMimeType(artifact.lang, artifact.filename);
      await api.put(`/projects/${projectId}/knowledge/${encodeURIComponent(artifact.filename)}`, {
        extracted_text: artifact.code,
        content_type: mime,
        size_bytes: new TextEncoder().encode(artifact.code).length,
      });
      setSaveState("saved");
      onSave?.(artifact.filename, artifact.code, artifact.lang);
      setTimeout(() => setSaveState("idle"), 2500);
    } catch {
      setSaveState("error");
      setTimeout(() => setSaveState("idle"), 3000);
    }
  }, [projectId, artifact, onSave]);

  return (
    <div className={s.panel}>
      <div className={s.header}>
        <span className={s.tag}>{langLabel}</span>
        <span className={s.title} title={displayName}>{displayName}</span>
        {generating && <span className={s.generating}>Generating…</span>}
        <div className={s.actions}>
          {/* Save to Project */}
          {projectId && artifact.filename && !generating && (
            <button
              className={`${s.actionBtn} ${s.saveBtn}`}
              title={saveState === "saved" ? "Saved!" : saveState === "error" ? "Save failed" : "Save to Project"}
              onClick={handleSave}
              disabled={saveState === "saving" || saveState === "saved"}
              data-cy="panel-save-btn"
            >
              {saveState === "saved" ? "✓" : saveState === "error" ? "✗" : <SaveIcon />}
            </button>
          )}
          {/* Download */}
          {!generating && (
            <button
              className={s.actionBtn}
              title="Download"
              onClick={() => downloadArtifact(artifact)}
              data-cy="panel-download-btn"
            >
              <DownloadIcon />
            </button>
          )}
          {/* Open in new tab (preview tab only) */}
          {canPreview && !generating && activeTab === "preview" && (
            <button
              className={s.actionBtn}
              title="Open in new tab"
              onClick={() => openInNewTab(srcdoc)}
            >
              <PopoutIcon />
            </button>
          )}
          <button className={s.actionBtn} title="Close preview" onClick={onClose}>
            <CloseIcon />
          </button>
        </div>
      </div>

      {/* Tab bar — only shown when a preview tab is available */}
      {canPreview && (
        <div className={s.tabs}>
          <button
            className={`${s.tab} ${activeTab === "code" ? s["tab--active"] : ""}`}
            onClick={() => setActiveTab("code")}
            type="button"
          >
            Code
          </button>
          <button
            className={`${s.tab} ${activeTab === "preview" ? s["tab--active"] : ""}`}
            onClick={() => setActiveTab("preview")}
            type="button"
          >
            Preview
          </button>
        </div>
      )}

      <div className={s.body}>
        {generating ? (
          <div className={s.generatingPlaceholder}>
            <span className={s.generatingSpinner} />
            <span>Generating…</span>
          </div>
        ) : activeTab === "preview" && canPreview ? (
          <iframe
            className={s.frame}
            sandbox="allow-scripts"
            srcDoc={srcdoc}
            title={`${langLabel} preview`}
          />
        ) : (
          <div className={s.codeBody}>
            <button
              className={s.copyBtn}
              onClick={handleCopy}
              type="button"
              title="Copy code"
              data-cy="panel-copy-btn"
            >
              {codeCopied ? "Copied!" : <><CopyIcon /> Copy</>}
            </button>
            <pre className={s.codePre}><code>{artifact.code}</code></pre>
          </div>
        )}
      </div>
    </div>
  );
}
