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

function fmtSize(bytes: number): string {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
  return (bytes / (1024 * 1024)).toFixed(1) + " MB";
}

interface Props {
  projectId: string;
  canEdit: boolean;
}

const MAX_UPLOAD_BYTES = 5 * 1024 * 1024;

export default function KnowledgePanel({ projectId, canEdit }: Props) {
  const [files, setFiles] = useState<ProjectKnowledge[]>([]);
  const [loading, setLoading] = useState(true);
  const [uploading, setUploading] = useState(false);
  const [uploadError, setUploadError] = useState<string | null>(null);
  const [dragOver, setDragOver] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    api.get<ProjectKnowledge[]>(`/projects/${projectId}/knowledge`)
      .then(setFiles)
      .catch(() => {})
      .finally(() => setLoading(false));
  }, [projectId]);

  async function uploadFile(file: File) {
    if (file.size > MAX_UPLOAD_BYTES) {
      setUploadError(`${file.name} exceeds 5 MB limit`); return;
    }
    setUploadError(null);
    setUploading(true);
    try {
      const text = await file.text();
      const item = await api.post<ProjectKnowledge>(`/projects/${projectId}/knowledge`, {
        filename: file.name,
        content_type: file.type || "text/plain",
        size_bytes: file.size,
        extracted_text: text,
      });
      setFiles((prev) => [...prev, item]);
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

  if (loading) return <div className={s.empty}>Loading…</div>;

  return (
    <div style={{ maxWidth: 720 }}>
      <div className={s["section-header"]}>
        <div>
          <h3 className={s["section-title"]}>Knowledge Files</h3>
          <p className={s["page-subtitle"]} style={{ marginTop: 2 }}>
            Text files injected into the system prompt for every conversation in this project. Max 5 MB, plain text or markdown.
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
            <UploadIcon /> {uploading ? "Uploading…" : "Upload File"}
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
        accept=".txt,.md,.csv,.json,.yaml,.yml,.xml,.html,.htm,.rst,.log"
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
                {canEdit && <th />}
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
                  {canEdit && (
                    <td>
                      <button
                        type="button"
                        className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`}
                        onClick={() => handleDelete(f.id, f.filename)}
                        title="Remove file"
                        data-cy={`delete-knowledge-${f.id}`}
                      >
                        <TrashIcon />
                      </button>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
