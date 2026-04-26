import { useState, useCallback, useEffect, useRef } from "react";
import { onEnterKey } from "@myraui/utils";
import { api } from "src/api/client";
import s from "./ArtifactPanel.module.scss";

export interface Artifact {
  lang: string;
  code: string;
  complete: boolean;
  filename?: string;
  /** Stable key for versioning — derived from filename or lang+code prefix */
  key?: string;
}

export interface ArtifactTab {
  key: string;
  label: string;        // filename or LANG — shown in the tab
  versions: Artifact[]; // index 0 = oldest, last = newest
  versionIndex: number; // which version is currently shown
}

interface Props {
  tabs: ArtifactTab[];
  activeKey: string | null;
  onTabSelect: (key: string) => void;
  onTabClose: (key: string) => void;
  onVersionNav: (key: string, index: number) => void;
  isStreaming?: boolean;
  onClose: () => void;
  projectId?: string;
  onSave?: (filename: string, content: string, lang: string) => void;
  onUpdateArtifact?: (artifact: Artifact) => void;
  onSendRevision?: (filename: string, code: string, instruction: string) => void;
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

function BackIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <polyline points="15 18 9 12 15 6" />
    </svg>
  );
}

const PREVIEW_LANGS = new Set(["html", "svg", "md", "markdown"]);

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

function buildSrcdoc(code: string, lang: string): string {
  if (lang === "svg") {
    return (
      "<!DOCTYPE html><html><head><meta charset='utf-8'>" +
      "<style>html,body{margin:0;padding:0;display:flex;align-items:center;justify-content:center;" +
      "min-height:100vh;background:#fff;box-sizing:border-box;} svg{max-width:100%;height:auto;}</style>" +
      "</head><body>" + code + "</body></html>"
    );
  }
  if (lang === "md" || lang === "markdown") {
    const escaped = code
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    const html = escaped
      .replace(/^### (.+)$/gm, "<h3>$1</h3>")
      .replace(/^## (.+)$/gm, "<h2>$1</h2>")
      .replace(/^# (.+)$/gm, "<h1>$1</h1>")
      .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
      .replace(/\*(.+?)\*/g, "<em>$1</em>")
      .replace(/`(.+?)`/g, "<code>$1</code>")
      .replace(/^\- (.+)$/gm, "<li>$1</li>")
      .replace(/^\d+\. (.+)$/gm, "<li>$1</li>")
      .replace(/\[(.+?)\]\((.+?)\)/g, '<a href="$2">$1</a>')
      .replace(/\n\n/g, "</p><p>")
      .replace(/\n/g, "<br>");
    return (
      "<!DOCTYPE html><html><head><meta charset='utf-8'>" +
      "<style>body{font-family:system-ui,sans-serif;padding:16px;line-height:1.6;color:#1a1a1a;max-width:100%}" +
      "h1,h2,h3{margin:0.8em 0 0.4em}code{background:#f0f0f0;padding:1px 4px;border-radius:3px;font-size:0.9em}" +
      "li{margin:2px 0}a{color:#0052cc}</style></head><body><p>" + html + "</p></body></html>"
    );
  }
  return code;
}

function openInNewTab(srcdoc: string) {
  const blob = new Blob([srcdoc], { type: "text/html" });
  const url = URL.createObjectURL(blob);
  const win = window.open(url, "_blank");
  if (win) setTimeout(() => URL.revokeObjectURL(url), 10_000);
}

function downloadArtifact(code: string, lang: string, filename?: string) {
  const mime = guessMimeType(lang, filename);
  const blob = new Blob([code], { type: mime });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename ?? `artifact.${lang}`;
  a.click();
  URL.revokeObjectURL(url);
}

export default function ArtifactPanel({
  tabs, activeKey, onTabSelect, onTabClose, onVersionNav,
  isStreaming, onClose, projectId, onSave, onUpdateArtifact, onSendRevision,
}: Props) {
  const activeTab  = tabs.find(t => t.key === activeKey) ?? tabs[0] ?? null;
  const versions   = activeTab?.versions ?? [];
  const versionIdx = activeTab ? Math.max(0, Math.min(activeTab.versionIndex, versions.length - 1)) : 0;
  const artifact   = versions[versionIdx] ?? null;

  const generating = !!(isStreaming && artifact && !artifact.complete);
  const canPreview = artifact ? PREVIEW_LANGS.has(artifact.lang.toLowerCase()) : false;

  const [editedCode, setEditedCode]             = useState<string | null>(null);
  const [viewMode, setViewMode]                 = useState<"code" | "split" | "preview">("split");
  const [showReviseInput, setShowReviseInput]   = useState(false);
  const [revisePrompt, setRevisePrompt]         = useState("");
  const [showDiscardConfirm, setShowDiscardConfirm] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const isDirty     = editedCode !== null && artifact != null && editedCode !== artifact.code;
  const displayCode = editedCode ?? artifact?.code ?? "";

  const [codeCopied, setCodeCopied] = useState(false);
  const [saveState, setSaveState]   = useState<"idle" | "saving" | "saved" | "error">("idle");

  const langLabel   = artifact?.lang.toUpperCase() ?? "";
  const displayName = artifact?.filename ?? langLabel;

  // Reset edit state when active artifact or version changes
  useEffect(() => {
    setEditedCode(null);
    setShowReviseInput(false);
    setRevisePrompt("");
    setShowDiscardConfirm(false);
    setViewMode(canPreview ? "split" : "code");
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [artifact?.code, artifact?.filename, activeKey, versionIdx]);

  useEffect(() => {
    if (!isDirty) return;
    const handler = (e: BeforeUnloadEvent) => { e.preventDefault(); };
    window.addEventListener("beforeunload", handler);
    return () => window.removeEventListener("beforeunload", handler);
  }, [isDirty]);

  const handleCopy = useCallback(() => {
    navigator.clipboard.writeText(displayCode);
    setCodeCopied(true);
    setTimeout(() => setCodeCopied(false), 1500);
  }, [displayCode]);

  const handleSaveToProject = useCallback(async () => {
    if (!projectId || !artifact?.filename) return;
    setSaveState("saving");
    try {
      const mime = guessMimeType(artifact.lang, artifact.filename);
      await api.put(`/projects/${projectId}/knowledge/${encodeURIComponent(artifact.filename)}`, {
        extracted_text: displayCode,
        content_type: mime,
        size_bytes: new TextEncoder().encode(displayCode).length,
      });
      setSaveState("saved");
      onSave?.(artifact.filename, displayCode, artifact.lang);
      setTimeout(() => setSaveState("idle"), 2500);
    } catch {
      setSaveState("error");
      setTimeout(() => setSaveState("idle"), 3000);
    }
  }, [projectId, artifact, displayCode, onSave]);

  function handleTabKeyPress(e: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === "Tab") {
      e.preventDefault();
      const ta = e.currentTarget;
      const start = ta.selectionStart;
      const end   = ta.selectionEnd;
      const newVal = ta.value.substring(0, start) + "  " + ta.value.substring(end);
      setEditedCode(newVal);
      requestAnimationFrame(() => { ta.selectionStart = ta.selectionEnd = start + 2; });
    }
  }

  function handleUpdate() {
    if (!isDirty || !onUpdateArtifact || !artifact) return;
    onUpdateArtifact({ ...artifact, code: displayCode });
    setEditedCode(null);
  }

  function handleRevert() {
    setEditedCode(null);
    setShowReviseInput(false);
    setRevisePrompt("");
  }

  function handleSendRevision() {
    if (!onSendRevision || !revisePrompt.trim() || !artifact) return;
    onSendRevision(artifact.filename ?? langLabel, displayCode, revisePrompt.trim());
    setShowReviseInput(false);
    setRevisePrompt("");
  }

  function handleClose() {
    if (isDirty) { setShowDiscardConfirm(true); return; }
    onClose();
  }

  function confirmDiscard() {
    setEditedCode(null);
    setShowDiscardConfirm(false);
    onClose();
  }

  const [debouncedCode, setDebouncedCode] = useState(displayCode);
  useEffect(() => {
    const t = setTimeout(() => setDebouncedCode(displayCode), 300);
    return () => clearTimeout(t);
  }, [displayCode]);

  if (!artifact) return null;

  const srcdoc = buildSrcdoc(debouncedCode, artifact.lang.toLowerCase());

  const codeView = (
    <div className={s.codeBody}>
      <button className={s.copyBtn} onClick={handleCopy} type="button" title="Copy code" data-cy="panel-copy-btn">
        {codeCopied ? "Copied!" : <><CopyIcon /> Copy</>}
      </button>
      <textarea
        ref={textareaRef}
        className={s.editArea}
        value={displayCode}
        onChange={(e) => setEditedCode(e.target.value)}
        onKeyDown={handleTabKeyPress}
        spellCheck={false}
        autoComplete="off"
        readOnly={generating}
        data-cy="panel-editor"
      />
    </div>
  );

  const previewView = (
    <iframe
      className={s.frame}
      sandbox="allow-scripts"
      srcDoc={srcdoc}
      title={`${langLabel} preview`}
    />
  );

  return (
    <div className={s.panel} data-cy="artifact-panel">

      {/* ── Multi-artifact tab bar ───────────────────────────────────────── */}
      {tabs.length > 1 && (
        <div className={s.tabBar} role="tablist" aria-label="Open artifacts" data-cy="artifact-tab-bar">
          {tabs.map(tab => (
            <div
              key={tab.key}
              role="tab"
              aria-selected={tab.key === activeKey}
              className={`${s.artifactTab} ${tab.key === activeKey ? s["artifactTab--active"] : ""}`}
              onClick={() => onTabSelect(tab.key)}
              data-cy={`artifact-tab`}
              title={tab.label}
            >
              <span className={s.artifactTabLabel}>{tab.label}</span>
              {tab.versions.length > 1 && (
                <span className={s.artifactTabBadge} title={`${tab.versions.length} versions`}>
                  {tab.versions.length}
                </span>
              )}
              <button
                className={s.artifactTabClose}
                onClick={(e) => { e.stopPropagation(); onTabClose(tab.key); }}
                title={`Close ${tab.label}`}
                type="button"
              >
                ×
              </button>
            </div>
          ))}
        </div>
      )}

      {/* ── Header ──────────────────────────────────────────────────────── */}
      <div className={s.header}>
        <button className={s.mobileBack} onClick={handleClose} title="Back">
          <BackIcon />
        </button>
        <span className={s.tag}>{langLabel}</span>
        <span className={s.title} title={displayName}>
          {displayName}
          {isDirty && <span className={s.dirtyDot} />}
        </span>
        {generating && <span className={s.generating}>Generating...</span>}

        {/* Version navigation */}
        {versions.length > 1 && (
          <div className={s.versionNav} data-cy="version-nav">
            <button
              className={s.versionBtn}
              onClick={() => activeKey && onVersionNav(activeKey, versionIdx - 1)}
              disabled={versionIdx === 0}
              title="Previous version"
              type="button"
              data-cy="version-prev"
            >
              ‹
            </button>
            <span className={s.versionLabel} data-cy="version-label">
              v{versionIdx + 1}/{versions.length}
            </span>
            <button
              className={s.versionBtn}
              onClick={() => activeKey && onVersionNav(activeKey, versionIdx + 1)}
              disabled={versionIdx === versions.length - 1}
              title="Next version"
              type="button"
              data-cy="version-next"
            >
              ›
            </button>
          </div>
        )}

        <div className={s.actions}>
          {projectId && artifact.filename && !generating && (
            <button
              className={`${s.actionBtn} ${s.saveBtn}`}
              title={saveState === "saved" ? "Saved!" : saveState === "error" ? "Save failed" : "Save to Project"}
              onClick={handleSaveToProject}
              disabled={saveState === "saving" || saveState === "saved"}
              data-cy="panel-save-btn"
            >
              {saveState === "saved" ? "✓" : saveState === "error" ? "✗" : <SaveIcon />}
            </button>
          )}
          {!generating && (
            <button className={s.actionBtn} title="Download" onClick={() => downloadArtifact(displayCode, artifact.lang, artifact.filename)} data-cy="panel-download-btn">
              <DownloadIcon />
            </button>
          )}
          {canPreview && !generating && viewMode !== "code" && (
            <button className={s.actionBtn} title="Open in new tab" onClick={() => openInNewTab(srcdoc)}>
              <PopoutIcon />
            </button>
          )}
          <button
            className={`${s.actionBtn} ${s.desktopOnly}`}
            title={tabs.length > 1 ? `Close ${displayName}` : "Close"}
            onClick={() => tabs.length > 1 && activeKey ? onTabClose(activeKey) : handleClose()}
            data-cy="panel-close-btn"
          >
            <CloseIcon />
          </button>
        </div>
      </div>

      {/* ── Code / Split / Preview mode tabs ────────────────────────────── */}
      {canPreview && (
        <div className={s.tabs}>
          <button className={`${s.tab} ${viewMode === "code"    ? s["tab--active"] : ""}`} onClick={() => setViewMode("code")}    type="button">Code</button>
          <button className={`${s.tab} ${viewMode === "split"   ? s["tab--active"] : ""}`} onClick={() => setViewMode("split")}   type="button">Split</button>
          <button className={`${s.tab} ${viewMode === "preview" ? s["tab--active"] : ""}`} onClick={() => setViewMode("preview")} type="button">Preview</button>
        </div>
      )}

      {/* ── Body ────────────────────────────────────────────────────────── */}
      <div className={s.body}>
        {generating ? (
          <div className={s.generatingPlaceholder}>
            <span className={s.generatingSpinner} />
            <span>Generating...</span>
          </div>
        ) : viewMode === "split" && canPreview ? (
          <div className={s.splitBody}>
            <div className={s.splitCode}>{codeView}</div>
            <div className={s.splitPreview}>{previewView}</div>
          </div>
        ) : viewMode === "preview" && canPreview ? (
          previewView
        ) : (
          codeView
        )}
      </div>

      {/* ── Footer — edit actions ────────────────────────────────────────── */}
      {isDirty && !showReviseInput && !generating && (
        <div className={s.footer}>
          <button className={s.revertBtn} onClick={handleRevert} type="button">Revert</button>
          <div className={s.footerRight}>
            {onSendRevision && (
              <button className={s.reviseBtn} onClick={() => setShowReviseInput(true)} type="button">
                Ask Claude to Revise
              </button>
            )}
            {onUpdateArtifact && (
              <button className={s.updateBtn} onClick={handleUpdate} type="button">
                Update Artifact
              </button>
            )}
          </div>
        </div>
      )}

      {showReviseInput && (
        <div className={s.footer}>
          <input
            className={s.reviseInput}
            placeholder="Tell Claude what to change..."
            value={revisePrompt}
            onChange={(e) => setRevisePrompt(e.target.value)}
            onKeyDown={(e) => {
              onEnterKey(e, () => { if (revisePrompt.trim()) handleSendRevision(); });
              if (e.key === "Escape") setShowReviseInput(false);
            }}
            autoFocus
          />
          <button className={s.updateBtn} onClick={handleSendRevision} disabled={!revisePrompt.trim()} type="button">Send</button>
          <button className={s.revertBtn} onClick={() => setShowReviseInput(false)} type="button">Cancel</button>
        </div>
      )}

      {showDiscardConfirm && (
        <div className={s.discardOverlay} onClick={() => setShowDiscardConfirm(false)}>
          <div className={s.discardPopover} onClick={(e) => e.stopPropagation()}>
            <p style={{ margin: "0 0 10px", fontSize: "13px" }}>Discard unsaved edits?</p>
            <div style={{ display: "flex", gap: "8px", justifyContent: "flex-end" }}>
              <button className={s.revertBtn} onClick={() => setShowDiscardConfirm(false)} type="button">Cancel</button>
              <button className={s.discardBtn} onClick={confirmDiscard} type="button">Discard</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
