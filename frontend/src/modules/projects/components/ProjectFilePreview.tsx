import { useEffect, useState } from "react";
import { api } from "src/api/client";
import type { ProjectKnowledge } from "src/api/types";
import { Modal } from "src/common/components/Modal";
import s from "src/common/components/layout/Layout.module.scss";

const adminBase = import.meta.env.VITE_ADMIN_URL ?? "/admin/v1";

const PDF_TYPE = "application/pdf";
const XLSX_TYPES = new Set([
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "application/vnd.ms-excel",
  "application/vnd.oasis.opendocument.spreadsheet",
]);

function parseCsv(text: string): string[][] {
  return text.split("\n").filter(Boolean).map((row) => {
    const cells: string[] = [];
    let cur = "";
    let inQ = false;
    for (let i = 0; i < row.length; i++) {
      const ch = row[i];
      if (ch === '"') { inQ = !inQ; continue; }
      if (ch === "," && !inQ) { cells.push(cur); cur = ""; continue; }
      cur += ch;
    }
    cells.push(cur);
    return cells;
  });
}

function FileIcon() {
  return <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><polyline points="13 2 13 9 20 9"/></svg>;
}
function DownloadIcon() {
  return <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><polyline points="8 17 12 21 16 17"/><line x1="12" y1="12" x2="12" y2="21"/><path d="M20.88 18.09A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.36"/></svg>;
}

function fmtSize(bytes: number): string {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
  return (bytes / (1024 * 1024)).toFixed(1) + " MB";
}

interface KnowledgeItem extends ProjectKnowledge {
  extracted_text?: string;
}

export interface ProjectFilePreviewProps {
  file: ProjectKnowledge;
  projectId: string;
  onClose: () => void;
}

export function ProjectFilePreview({ file, projectId, onClose }: ProjectFilePreviewProps) {
  const [text, setText] = useState<string | null>(null);
  const [loadErr, setLoadErr] = useState<string | null>(null);
  const isPdf = file.content_type === PDF_TYPE;
  const isXlsx = XLSX_TYPES.has(file.content_type);
  const downloadUrl = `${adminBase}/projects/${projectId}/knowledge/${file.id}/download`;

  useEffect(() => {
    if (isPdf) return;
    api.get<KnowledgeItem>(`/projects/${projectId}/knowledge/${file.id}`)
      .then((item) => setText(item.extracted_text ?? ""))
      .catch((e) => setLoadErr(String(e)));
  }, [file.id, isPdf, projectId]);

  const rows = !isPdf && isXlsx && text != null ? parseCsv(text) : null;

  return (
    <Modal
      title={
        <span style={{ display: "flex", alignItems: "center", gap: 8, minWidth: 0 }}>
          <FileIcon />
          <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
            {file.filename}
          </span>
        </span>
      }
      onClose={onClose}
      modalStyle={{
        width: "min(900px, 90vw)",
        height: "85vh",
        display: "flex",
        flexDirection: "column",
        overflow: "hidden",
      }}
    >
      <div style={{
        display: "flex", alignItems: "center", gap: 16, padding: "6px 0 12px",
        borderBottom: "1px solid var(--card-border)", flexShrink: 0,
        fontSize: 13, color: "var(--text-secondary)",
      }}>
        <span>{fmtSize(file.size_bytes)}</span>
        <span>{file.token_count.toLocaleString()} tokens</span>
        {file.source === "upload" ? (
          <a
            href={downloadUrl}
            download={file.filename}
            className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
            style={{ marginLeft: "auto", display: "inline-flex", alignItems: "center", gap: 4 }}
          >
            <DownloadIcon /> Download
          </a>
        ) : (
          <button
            type="button"
            className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
            style={{ marginLeft: "auto", display: "inline-flex", alignItems: "center", gap: 4 }}
            disabled={text == null}
            onClick={() => {
              if (text == null) return;
              const blob = new Blob([text], { type: file.content_type || "text/plain" });
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url; a.download = file.filename; a.click();
              URL.revokeObjectURL(url);
            }}
          >
            <DownloadIcon /> Download
          </button>
        )}
      </div>

      <div style={{ flex: 1, overflow: "auto", marginTop: 12 }}>
        {loadErr && <div className={`${s.alert} ${s["alert--error"]}`}>{loadErr}</div>}

        {isPdf && (
          <iframe
            src={downloadUrl}
            style={{ width: "100%", height: "100%", border: "none", display: "block" }}
            title={file.filename}
          />
        )}

        {!isPdf && !loadErr && text == null && (
          <div className={s.empty}>Loading…</div>
        )}

        {!isPdf && !loadErr && text != null && rows != null && (
          <div className={s["table-wrapper"]} style={{ maxHeight: "100%", overflow: "auto" }}>
            <table className={s.table}>
              <tbody>
                {rows.map((cells, ri) => (
                  <tr key={ri}>
                    {cells.map((cell, ci) => (
                      ri === 0
                        ? <th key={ci}>{cell}</th>
                        : <td key={ci}>{cell}</td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {!isPdf && !loadErr && text != null && rows == null && (
          <pre style={{
            margin: 0, padding: 12, fontSize: 12, lineHeight: 1.55,
            whiteSpace: "pre-wrap", wordBreak: "break-word",
            background: "var(--section-bg)", borderRadius: 6,
            border: "1px solid var(--card-border)", color: "var(--text-primary)",
            overflowY: "auto", maxHeight: "100%",
          }}>
            {text || <span style={{ color: "var(--text-secondary)" }}>(empty file)</span>}
          </pre>
        )}
      </div>
    </Modal>
  );
}
