import { useState } from "react";
import { api } from "src/api/client";
import type { ProjectKnowledge } from "src/api/types";
import s from "src/common/components/layout/Layout.module.scss";

interface Props {
  filename: string;
  content: string;
  projectId: string;
  onSaved?: () => void;
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

export function SaveToProjectCard({ filename, content, projectId, onSaved }: Props) {
  const [state, setState] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const [errMsg, setErrMsg] = useState("");

  async function handleSave() {
    setState("saving");
    try {
      await api.put<ProjectKnowledge>(
        `/projects/${projectId}/knowledge/${encodeURIComponent(filename)}`,
        {
          extracted_text: content,
          content_type: guessMimeType(filename),
          size_bytes: new Blob([content]).size,
        }
      );
      setState("saved");
      onSaved?.();
    } catch (e) {
      setErrMsg(e instanceof Error ? e.message : "Save failed");
      setState("error");
    }
  }

  return (
    <div className={s["save-to-project-card"]}>
      <span className={s["save-filename"]}>📄 {filename}</span>
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
