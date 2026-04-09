import { useEffect, useRef, useState } from "react";
import { api } from "src/api/client";
import type { ProjectKnowledge } from "src/api/types";
import s from "src/common/components/layout/Layout.module.scss";

function UploadIcon() {
  return <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><polyline points="16 16 12 12 8 16"/><line x1="12" y1="12" x2="12" y2="21"/><path d="M20.39 18.39A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.3"/></svg>;
}
function TrashIcon() {
  return <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/></svg>;
}
function FileIcon() {
  return <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><polyline points="13 2 13 9 20 9"/></svg>;
}
function DownloadIcon() {
  return <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><polyline points="8 17 12 21 16 17"/><line x1="12" y1="12" x2="12" y2="21"/><path d="M20.88 18.09A5 5 0 0 0 18 9h-1.26A8 8 0 1 0 3 16.36"/></svg>;
}
function LinkIcon() {
  return <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></svg>;
}

function fmtSize(bytes: number): string {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
  return (bytes / (1024 * 1024)).toFixed(1) + " MB";
}

interface KnowledgeItem extends ProjectKnowledge {
  extracted_text?: string;
}

interface Props {
  projectId: string;
  canEdit: boolean;
}

const BINARY_TYPES = new Set([
  "application/pdf",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  "application/vnd.ms-excel",
  "application/vnd.oasis.opendocument.spreadsheet",
  "application/vnd.openxmlformats-officedocument.presentationml.presentation",
]);
const BINARY_EXTS = /\.(pdf|docx|xlsx|xls|ods|pptx)$/i;

const MAX_TEXT_BYTES = 5 * 1024 * 1024;
const MAX_BINARY_BYTES = 20 * 1024 * 1024;
const adminBase = (import.meta.env.VITE_ADMIN_URL as string | undefined) ?? "/admin/v1";

export default function KnowledgePanel({ projectId, canEdit }: Props) {
  const [files, setFiles] = useState<ProjectKnowledge[]>([]);
  const [loading, setLoading] = useState(true);
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [dragOver, setDragOver] = useState(false);
  const [copiedId, setCopiedId] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    api.get<ProjectKnowledge[]>(`/projects/${projectId}/knowledge`)
      .then(setFiles)
      .catch(() => {})
      .finally(() => setLoading(false));
  }, [projectId]);

  async function uploadFile(file: File) {
    const isBinary = BINARY_TYPES.has(file.type) || BINARY_EXTS.test(file.name);
    const limit = isBinary ? MAX_BINARY_BYTES : MAX_TEXT_BYTES;
    if (file.size > limit) {
      setUploadError(`${file.name} exceeds ${isBinary ? "20 MB" : "5 MB"} limit`);
      return;
    }
    setUploadError(null);
    setUploading(true);
    try {
      if (isBinary) {
        const buf = await file.arrayBuffer();
        const bytes = new Uint8Array(buf);
        let binary = "";
        for (let i = 0; i < bytes.length; i += 8192) {
          binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
        }
        const b64 = btoa(binary);
        const item = await api.post<ProjectKnowledge>(`/projects/${projectId}/knowledge/upload`, {
          filename: file.name,
          mime_type: file.type || "application/octet-stream",
          data: b64,
        });
        setFiles((prev) => [...prev, item]);
      } else {
        const text = await file.text();
        const item = await api.post<ProjectKnowledge>(`/projects/${projectId}/knowledge`, {
          filename: file.name,
          content_type: file.type || "text/plain",
          size_bytes: file.size,
          extracted_text: text,
        });
        setFiles((prev) => [...prev, item]);
      }
    } catch (e) {
      setUploadError("Upload failed: " + String(e));
    } finally {
      setUploading(false);
    }
  }

  function handleFiles(fileList: FileList | null) {
    if (!fileList) return;
    for (const f of Array.from(fileList)) uploadFile(f);
  }

  async function handleDelete(id: string, filename: string) {
    if (!confirm(`Remove "${filename}" from project knowledge?`)) return;
    try {
      await api.delete(`/projects/${projectId}/knowledge/${id}`);
      setFiles((prev) => prev.filter((f) => f.id !== id));
    } catch (e) {
      alert("Delete failed: " + String(e));
    }
  }

  async function handleDownload(f: ProjectKnowledge) {
    try {
      if (f.source === "upload") {
        const downloadUrl = `${adminBase}/projects/${projectId}/knowledge/${f.id}/download`;
        const a = document.createElement("a");
        a.href = downloadUrl;
        a.download = f.filename;
        a.click();
      } else {
        const item = await api.get<KnowledgeItem>(`/projects/${projectId}/knowledge/${f.id}`);
        const blob = new Blob([item.extracted_text ?? ""], { type: item.content_type || "text/plain" });
        const url = URL.createObjectURL(blob);
        const a = document.createElement("a");
        a.href = url;
        a.download = item.filename;
        a.click();
        URL.revokeObjectURL(url);
      }
    } catch (e) {
      alert("Download failed: " + String(e));
    }
  }

  function handleCopyUrl(f: ProjectKnowledge) {
    const url = `${adminBase}/projects/${projectId}/knowledge/${f.id}`;
    navigator.clipboard.writeText(url).then(() => {
      setCopiedId(f.id);
      setTimeout(() => setCopiedId((prev) => (prev === f.id ? null : prev)), 1500);
    });
  }

  if (loading) return <div className={s.empty}>Loading…</div>;

  return (
    <div style={{ maxWidth: 720 }}>
      <div className={s["section-header"]}>
        <div>
          <h3 className={s["section-title"]}>Knowledge Files</h3>
          <p className={s["page-subtitle"]} style={{ marginTop: 2 }}>
            Files available for the model to read on demand. Plain text up to 5 MB or PDF/DOCX/XLSX/PPTX up to 20 MB.
          </p>
        </div>
        {canEdit && (
          <button
            type="button"
            className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`}
            onClick={() => inputRef.current?.click()}
            disabled={uploading}
            data-cy="upload-knowledge-btn"
          >
            <UploadIcon /> {uploading ? "Processing…" : "Upload File"}
          </button>
        )}
      </div>

      {canEdit && (
        <div
          className={`${s["drop-zone"]} ${dragOver ? s["drop-zone--active"] : ""}`}
          onDragOver={(e) => { e.preventDefault(); setDragOver(true); }}
          onDragLeave={() => setDragOver(false)}
          onDrop={(e) => { e.preventDefault(); setDragOver(false); handleFiles(e.dataTransfer.files); }}
          onClick={() => inputRef.current?.click()}
          data-cy="knowledge-drop-zone"
        >
          Drop files here, or click to browse
        </div>
      )}

      <input
        ref={inputRef}
        type="file"
        multiple
        accept=".txt,.md,.csv,.json,.yaml,.yml,.xml,.html,.htm,.rst,.log,.pdf,.docx,.xlsx,.xls,.ods,.pptx"
        style={{ display: "none" }}
        onChange={(e) => handleFiles(e.target.files)}
      />

      {uploadError && (
        <div className={`${s.alert} ${s["alert--error"]}`}>{uploadError}</div>
      )}

      {files.length === 0 ? (
        <div className={s.empty}>No knowledge files yet.</div>
      ) : (
        <div className={s["table-wrapper"]}>
          <table className={s.table}>
            <thead>
              <tr>
                <th>File</th>
                <th>Size</th>
                <th>Tokens (est.)</th>
                <th>Uploaded</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {files.map((f) => (
                <tr key={f.id} data-cy={`knowledge-row-${f.id}`}>
                  <td>
                    <span style={{ display: "inline-flex", alignItems: "center", gap: 6 }}>
                      <FileIcon />
                      {f.filename}
                    </span>
                  </td>
                  <td style={{ color: "var(--text-secondary)" }}>{fmtSize(f.size_bytes)}</td>
                  <td style={{ color: "var(--text-secondary)" }}>{f.token_count.toLocaleString()}</td>
                  <td style={{ color: "var(--text-secondary)" }}>{new Date(f.created_at).toLocaleDateString()}</td>
                  <td style={{ whiteSpace: "nowrap" }}>
                    <button
                      type="button"
                      className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
                      onClick={() => handleDownload(f)}
                      title="Download file"
                      data-cy={`download-knowledge-${f.id}`}
                    >
                      <DownloadIcon />
                    </button>
                    <button
                      type="button"
                      className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
                      onClick={() => handleCopyUrl(f)}
                      title="Copy reference URL"
                      data-cy={`copy-url-knowledge-${f.id}`}
                      style={{ marginLeft: 4 }}
                    >
                      {copiedId === f.id ? "✓" : <LinkIcon />}
                    </button>
                    {canEdit && (
                      <button
                        type="button"
                        className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`}
                        onClick={() => handleDelete(f.id, f.filename)}
                        title="Remove file"
                        data-cy={`delete-knowledge-${f.id}`}
                        style={{ marginLeft: 4 }}
                      >
                        <TrashIcon />
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
