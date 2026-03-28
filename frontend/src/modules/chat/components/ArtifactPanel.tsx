import s from "./ArtifactPanel.module.scss";

interface Artifact {
  lang: "html" | "svg";
  code: string;
  complete: boolean;
}

interface Props {
  artifact: Artifact;
  isStreaming?: boolean;
  onClose: () => void;
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

export default function ArtifactPanel({ artifact, isStreaming, onClose }: Props) {
  const generating = isStreaming && !artifact.complete;
  const srcdoc = buildSrcdoc(artifact);
  const label = artifact.lang === "svg" ? "SVG" : "HTML";

  return (
    <div className={s.panel}>
      <div className={s.header}>
        <span className={s.tag}>{label}</span>
        <span className={s.title}>Preview</span>
        {generating && <span className={s.generating}>Generating…</span>}
        <div className={s.actions}>
          {!generating && (
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
      <div className={s.body}>
        {generating ? (
          <div className={s.generatingPlaceholder}>
            <span className={s.generatingSpinner} />
            <span>Generating…</span>
          </div>
        ) : (
          <iframe
            className={s.frame}
            sandbox="allow-scripts"
            srcDoc={srcdoc}
            title={`${label} preview`}
          />
        )}
      </div>
    </div>
  );
}

export type { Artifact };
