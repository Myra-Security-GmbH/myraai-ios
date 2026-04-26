import { useState } from "react";
import { api } from "src/api/client";
import type { ProjectKnowledge } from "src/api/types";
import s from "src/common/components/layout/Layout.module.scss";

export interface FileEntry {
  filename: string;
  content: string;
  lang: string;
}

function guessMimeType(filename: string): string {
  const ext = filename.split(".").pop()?.toLowerCase() ?? "";
  const map: Record<string, string> = {
    py: "text/x-python",
    js: "text/javascript",
    ts: "text/typescript",
    tsx: "text/typescript",
    jsx: "text/javascript",
    lua: "text/x-lua",
    sh: "text/x-sh",
    bash: "text/x-sh",
    sql: "text/x-sql",
    json: "application/json",
    yaml: "text/yaml",
    yml: "text/yaml",
    xml: "text/xml",
    html: "text/html",
    htm: "text/html",
    css: "text/css",
    md: "text/markdown",
    txt: "text/plain",
    csv: "text/csv",
  };
  return map[ext] ?? "text/plain";
}

async function saveFile(projectId: string, file: FileEntry): Promise<void> {
  await api.put<ProjectKnowledge>(
    `/projects/${projectId}/knowledge/${encodeURIComponent(file.filename)}`,
    {
      extracted_text: file.content,
      content_type: guessMimeType(file.filename),
      size_bytes: new Blob([file.content]).size,
    }
  );
}

// ---------------------------------------------------------------------------
// Single-file card (unchanged behaviour)
// ---------------------------------------------------------------------------

interface SingleProps {
  filename: string;
  content: string;
  projectId: string;
  onSaved?: () => void;
}

export function SaveToProjectCard({ filename, content, projectId, onSaved }: SingleProps) {
  const [state, setState] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const [errMsg, setErrMsg] = useState("");

  async function handleSave() {
    setState("saving");
    try {
      await saveFile(projectId, { filename, content, lang: "" });
      setState("saved");
      onSaved?.();
    } catch (e) {
      setErrMsg(e instanceof Error ? e.message : "Save failed");
      setState("error");
    }
  }

  return (
    <div className={s["save-to-project-card"]}>
      <span className={s["save-filename"]}>{filename}</span>
      {state === "idle" && (
        <button
          className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`}
          onClick={handleSave}
          type="button"
        >
          Save to Project
        </button>
      )}
      {state === "saving" && (
        <span style={{ fontSize: 12, color: "var(--text-secondary)" }}>Saving…</span>
      )}
      {state === "saved" && (
        <span className={`${s.badge} ${s["badge--success"]}`}>✓ Saved</span>
      )}
      {state === "error" && (
        <span
          className={`${s.badge} ${s["badge--error"]}`}
          title={errMsg}
          style={{ cursor: "help" }}
        >
          Save failed
        </span>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Multi-file batch card
// ---------------------------------------------------------------------------

interface BatchProps {
  files: FileEntry[];
  projectId: string;
  /** Called once per file after it is saved */
  onFileSaved?: ((filename: string, content: string, lang: string) => void) | null;
  /** Called when the user switches to individual-save mode */
  onSwitchToIndividual: () => void;
}

export function SaveAllCard({ files, projectId, onFileSaved, onSwitchToIndividual }: BatchProps) {
  const [state, setState] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const [savedSet, setSavedSet] = useState<Set<string>>(new Set());
  const [errMsg, setErrMsg] = useState("");

  async function handleSaveAll() {
    setState("saving");
    try {
      for (const file of files) {
        await saveFile(projectId, file);
        onFileSaved?.(file.filename, file.content, file.lang);
        setSavedSet((prev) => new Set([...prev, file.filename]));
      }
      setState("saved");
    } catch (e) {
      setErrMsg(e instanceof Error ? e.message : "Save failed");
      setState("error");
    }
  }

  return (
    <div className={s["save-to-project-card"]} style={{ flexDirection: "column", alignItems: "flex-start", gap: 8 }}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", width: "100%" }}>
        <span style={{ fontWeight: 600, fontSize: 13 }}>
          📁 {files.length} files ready to save to project
        </span>
        <div style={{ display: "flex", gap: 6, alignItems: "center" }}>
          {state === "idle" && (
            <>
              <button
                className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
                onClick={onSwitchToIndividual}
                type="button"
                data-cy="save-individually-btn"
              >
                Save individually
              </button>
              <button
                className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`}
                onClick={handleSaveAll}
                type="button"
                data-cy="save-all-to-project-btn"
              >
                Save All to Project
              </button>
            </>
          )}
          {state === "saving" && (
            <span style={{ fontSize: 12, color: "var(--text-secondary)" }}>Saving…</span>
          )}
          {state === "saved" && (
            <span className={`${s.badge} ${s["badge--success"]}`}>✓ All saved</span>
          )}
          {state === "error" && (
            <span
              className={`${s.badge} ${s["badge--error"]}`}
              title={errMsg}
              style={{ cursor: "help" }}
            >
              Save failed
            </span>
          )}
        </div>
      </div>
      <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
        {files.map((f) => (
          <span
            key={f.filename}
            className={`${s.badge} ${savedSet.has(f.filename) ? s["badge--success"] : s["badge--neutral"]}`}
            data-cy={`save-all-file-${f.filename}`}
          >
            {savedSet.has(f.filename) ? "✓ " : ""}{f.filename}
          </span>
        ))}
      </div>
    </div>
  );
}

