import { memo, useState, useCallback, useContext, createContext, isValidElement } from "react";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import remarkBreaks from "remark-breaks";
import remarkEmoji from "remark-emoji";
import rehypeKatex from "rehype-katex";
import rehypeHighlight from "rehype-highlight";
import "katex/dist/katex.min.css";
import "highlight.js/styles/github-dark-dimmed.css";
import type { Components } from "react-markdown";
import type { ChatMessage } from "src/api/types";
import AttachmentChip from "./AttachmentChip";
import ThinkingBlock from "./ThinkingBlock";
import { SaveAllCard, type FileEntry } from "./SaveToProjectCard";
import { ArtifactCard } from "./ArtifactCard";
import type { Artifact } from "./ArtifactPanel";
import s from "../pages/Chat.module.scss";

function fmtCost(usd: number | null) {
  if (usd == null || usd === 0) return null;
  if (usd < 0.0001) return `<$0.0001`;
  return `$${usd.toFixed(4)}`;
}

function fmtMs(ms: number | null) {
  if (ms == null) return null;
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

function CopyIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  );
}

function EditIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7" />
      <path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z" />
    </svg>
  );
}

function RegenerateIcon() {
  return (
    <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <polyline points="1 4 1 10 7 10" />
      <path d="M3.51 15a9 9 0 1 0 .49-3" />
    </svg>
  );
}

function SparkIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor">
      <path d="M12 2 L13.5 9 L20 10 L13.5 11 L12 18 L10.5 11 L4 10 L10.5 9 Z" />
    </svg>
  );
}

function extractText(node: React.ReactNode): string {
  if (typeof node === "string") return node;
  if (Array.isArray(node)) return node.map(extractText).join("");
  if (isValidElement(node)) return extractText((node.props as { children?: React.ReactNode }).children);
  return "";
}

// Matches first-line filename comments across common languages:
// # filename.py  // index.ts  -- schema.sql  % script.m  ; config.asm  <!-- index.html -->
const FILENAME_COMMENT_RE = /^(?:#|\/\/|--|%|;|<!--)\s*([\w\-./ ]+\.\w+)\s*(?:-->)?\s*$/;

// Transform <write_file filename="x">content</write_file> tags into fenced code blocks
// so they get picked up by the existing ArtifactCard / scanFilenameBlocks pipeline.
function transformWriteFileTags(text: string): string {
  return text.replace(
    /<write_file\s+filename="([^"]+)">([\s\S]*?)<\/write_file>/g,
    (_, filename: string, content: string) => {
      const ext = filename.split(".").pop()?.toLowerCase() ?? "";
      const langMap: Record<string, string> = {
        html: "html", htm: "html", css: "css", js: "javascript",
        ts: "typescript", tsx: "typescript", jsx: "javascript",
        py: "python", sh: "bash", sql: "sql", lua: "lua",
        json: "json", yaml: "yaml", yml: "yaml", xml: "xml", md: "markdown",
      };
      const lang = langMap[ext] ?? "";
      const commentMap: Record<string, string> = {
        html: `<!-- ${filename} -->`, xml: `<!-- ${filename} -->`,
        sql: `-- ${filename}`, lua: `-- ${filename}`,
        python: `# ${filename}`, bash: `# ${filename}`,
        yaml: `# ${filename}`, yml: `# ${filename}`,
      };
      const comment = commentMap[lang] ?? `// ${filename}`;
      return `\`\`\`${lang}\n${comment}\n${content.trim()}\n\`\`\``;
    }
  );
}

/** Context passed into CodeBlock without prop-drilling through ReactMarkdown */
interface ProjectCtx {
  projectId: string | null;
  onFileSaved: ((filename: string, content: string, lang: string) => void) | null;
  /** True when a SaveAllCard is handling the batch — individual cards are suppressed */
  hideSaveCard: boolean;
  /** Fingerprint → filename for heading-before-block detection (Qwen3 / non-compliant models) */
  codeToFilename: Map<string, string>;
  /** Called when the user clicks an artifact card to open the side panel */
  onOpenArtifact: ((a: Artifact) => void) | null;
  /** True while this message bubble is actively streaming */
  isStreaming: boolean;
}
const ProjectIdContext = createContext<ProjectCtx>({ projectId: null, onFileSaved: null, hideSaveCard: false, codeToFilename: new Map(), onOpenArtifact: null, isStreaming: false });

/**
 * Scan markdown text for fenced code blocks that carry a filename, via two patterns:
 *   1. First line inside the fence is a comment: ```bash\n# script.sh\n...```
 *   2. A markdown heading immediately before the fence: ## script.sh\n```bash\n...```
 * Returns an array of FileEntry and a map from code fingerprint → filename (for CodeBlock lookup).
 */
function scanFilenameBlocks(text: string): { entries: FileEntry[]; codeToFilename: Map<string, string> } {
  const entries: FileEntry[] = [];
  const codeToFilename = new Map<string, string>();

  // Pattern 1: filename comment as first line inside the fence
  for (const m of text.matchAll(/```(\w*)\n([\s\S]*?)\n```/g)) {
    const lang = m[1] ?? "";
    const body = m[2] ?? "";
    const firstLine = body.split("\n")[0] ?? "";
    const match = FILENAME_COMMENT_RE.exec(firstLine);
    if (match) {
      const filename = match[1].trim();
      const content = body.split("\n").slice(1).join("\n");
      entries.push({ filename, content, lang });
    }
  }

  // Pattern 2: markdown heading (# / ## / ###) immediately before the fence
  // Handles models that put "# filename.sh" as a heading outside the block
  for (const m of text.matchAll(/^#{1,3}\s+([\w\-./ ]+\.\w+)\s*\n+```(\w*)\n([\s\S]*?)\n```/gm)) {
    const filename = m[1].trim();
    const lang = m[2] ?? "";
    const body = m[3] ?? "";
    // Skip if already captured via pattern 1 (first-line comment)
    const firstLine = body.split("\n")[0] ?? "";
    if (FILENAME_COMMENT_RE.exec(firstLine)) continue;
    const content = body;
    entries.push({ filename, content, lang });
    // Store fingerprint so CodeBlock can find the filename
    codeToFilename.set(body.trim().slice(0, 120), filename);
  }

  return { entries, codeToFilename };
}

function CodeBlock({ className, children }: { inline?: boolean; className?: string; children?: React.ReactNode }) {
  const { codeToFilename, onOpenArtifact, isStreaming } = useContext(ProjectIdContext);
  const lang = /language-(\w+)/.exec(className ?? "")?.[1] ?? "";
  const rawCode = extractText(children).replace(/\n$/, "");
  const [codeCopied, setCodeCopied] = useState(false);

  // Render as inline code when:
  //   • no language tag (backtick spans never have one), AND
  //   • no newline in content (single-line fenced blocks with no lang tag also qualify)
  // This also fixes react-markdown v10 dropping the `inline` prop entirely.
  const isInline = !lang && !rawCode.includes("\n");

  // Detect filename: first try comment on first line, then heading-before-block map
  const firstLine = rawCode.split("\n")[0] ?? "";
  const filenameMatch = !isInline ? FILENAME_COMMENT_RE.exec(firstLine) : null;
  const detectedFilename = filenameMatch?.[1]?.trim()
    ?? codeToFilename.get(rawCode.trim().slice(0, 120))
    ?? null;
  // Strip the filename comment line from displayed/copied code (pattern 1 only)
  const code = filenameMatch ? rawCode.split("\n").slice(1).join("\n") : rawCode;

  const handleCopy = useCallback(() => {
    navigator.clipboard.writeText(code);
    setCodeCopied(true);
    setTimeout(() => setCodeCopied(false), 1500);
  }, [code]);

  if (isInline) {
    return <code className={className}>{children}</code>;
  }

  // Named file → compact artifact card (replaces inline block + individual save card)
  if (detectedFilename) {
    return (
      <ArtifactCard
        filename={detectedFilename}
        lang={lang}
        code={code}
        isStreaming={isStreaming}
        onOpen={() => onOpenArtifact?.({ lang, code, filename: detectedFilename, complete: !isStreaming })}
      />
    );
  }

  // Anonymous code block — render inline as before
  return (
    <>
      <div style={{ borderRadius: 8, overflow: "hidden", margin: "0.75em 0", border: "1px solid var(--card-border)" }}>
        <div style={{
          display: "flex", justifyContent: "space-between", alignItems: "center",
          padding: "4px 12px", background: "var(--table-row-hover)", fontSize: 11,
          color: "var(--text-secondary)", borderBottom: "1px solid var(--card-border)",
        }}>
          <span>{lang || "code"}</span>
          <button
            onClick={handleCopy}
            style={{ background: "none", border: "none", cursor: "pointer", fontSize: 11, color: "var(--text-secondary)", padding: "2px 6px" }}
          >
            {codeCopied ? "Copied!" : "Copy"}
          </button>
        </div>
        <pre style={{ margin: 0, padding: "12px 16px", overflowX: "auto", background: "#22272e", color: "#adbac7" }}>
          <code className={className}>{children}</code>
        </pre>
      </div>
    </>
  );
}

const MD_COMPONENTS_DEFAULT: Components = {
  code: CodeBlock as Components["code"],
};

/** Split a plain-text assistant message into its thinking block and visible text. */
function parseThinking(text: string): {
  thinking: string | null;
  visible: string;
  isThinking: boolean; // true while </think> hasn't been seen yet
} {
  const openIdx = text.indexOf("<think>");
  if (openIdx === -1) return { thinking: null, visible: text, isThinking: false };
  const closeIdx = text.indexOf("</think>", openIdx + 7);
  if (closeIdx === -1) {
    // Streaming: block opened but not yet closed
    return {
      thinking: text.slice(openIdx + 7),
      visible: text.slice(0, openIdx).trimEnd(),
      isThinking: true,
    };
  }
  return {
    thinking: text.slice(openIdx + 7, closeIdx).trim(),
    visible: (text.slice(0, openIdx) + text.slice(closeIdx + 8)).trim(),
    isThinking: false,
  };
}

type ContentBlock =
  | { type: "text"; text?: string }
  | { type: "image_url"; image_url?: { url: string } }
  | { type: "docx"; filename: string; text?: string }
  | { type: string; [k: string]: unknown };

/** Try to parse content as JSON content-block array; fall back to plain string */
function parseContent(content: string): ContentBlock[] {
  try {
    const parsed = JSON.parse(content);
    if (Array.isArray(parsed)) return parsed as ContentBlock[];
  } catch { /* not JSON */ }
  return [{ type: "text", text: content }];
}

interface Props {
  message: ChatMessage;
  isLast: boolean;
  isStreaming?: boolean;
  /** Duration of the <think> phase in ms — only provided for the live streaming bubble */
  thinkingDurationMs?: number | null;
  /** If set, code blocks with a filename comment get a "Save to Project" card */
  projectId?: string | null;
  /** Called after a file is saved so Chat.tsx can inject a context-refresh message */
  onFileSaved?: ((filename: string, content: string, lang: string) => void) | null;
  /** Called when the user clicks an artifact card to open the side panel */
  onOpenArtifact?: ((artifact: Artifact) => void) | null;
  onCopy: (text: string) => void;
  onEdit?: (id: string, content: string) => void;
  onRegenerate?: () => void;
}

const MessageBubble = memo(function MessageBubble({
  message,
  isLast,
  isStreaming,
  thinkingDurationMs,
  projectId,
  onFileSaved,
  onOpenArtifact,
  onCopy,
  onEdit,
  onRegenerate,
}: Props) {
  const isUser = message.role === "user";
  const [editing, setEditing] = useState(false);
  const [editValue, setEditValue] = useState("");
  const [copied, setCopied] = useState(false);
  const [useIndividual, setUseIndividual] = useState(false);

  const blocks = parseContent(message.content);
  const docxBlocks = blocks.filter(
    (b): b is { type: "docx" | "md"; filename: string; text?: string } =>
      b.type === "docx" || b.type === "md"
  );
  const rawTextContent = blocks
    .filter((b) => b.type === "text")
    .map((b) => (b as { type: "text"; text?: string }).text ?? "")
    .join("\n");

  // Parse out any <think>...</think> block from assistant messages
  const { thinking, visible: textContent, isThinking } = isUser
    ? { thinking: null, visible: rawTextContent, isThinking: false }
    : parseThinking(rawTextContent);

  function handleCopy() {
    onCopy(rawTextContent);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  }

  function startEdit() {
    setEditValue(rawTextContent);
    setEditing(true);
  }

  function commitEdit() {
    if (onEdit && editValue.trim()) {
      onEdit(message.id, editValue.trim());
    }
    setEditing(false);
  }

  return (
    <div className={[s["bubble-row"], isUser ? s["user-row"] : ""].filter(Boolean).join(" ")}>
      <div className={s["bubble-avatar"]}>
        {isUser ? "U" : <SparkIcon />}
      </div>
      <div className={s["bubble-content"]}>
        {editing ? (
          <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            <textarea
              autoFocus
              value={editValue}
              onChange={(e) => setEditValue(e.target.value)}
              style={{
                width: "100%",
                minHeight: 80,
                padding: "8px 10px",
                fontSize: 14,
                fontFamily: "inherit",
                lineHeight: 1.5,
                border: "1px solid var(--accent, #0052cc)",
                borderRadius: 6,
                background: "var(--input-bg)",
                color: "var(--text-primary)",
                resize: "vertical",
                outline: "none",
                boxSizing: "border-box",
              }}
              onKeyDown={(e) => {
                if (e.key === "Escape") setEditing(false);
                if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) commitEdit();
              }}
            />
            <div style={{ display: "flex", gap: 6 }}>
              <button
                onClick={commitEdit}
                style={{
                  padding: "4px 12px",
                  fontSize: 12,
                  borderRadius: 5,
                  border: "none",
                  background: "var(--accent, #0052cc)",
                  color: "#fff",
                  cursor: "pointer",
                }}
              >
                Save
              </button>
              <button
                onClick={() => setEditing(false)}
                style={{
                  padding: "4px 12px",
                  fontSize: 12,
                  borderRadius: 5,
                  border: "1px solid var(--card-border)",
                  background: "transparent",
                  color: "var(--text-secondary)",
                  cursor: "pointer",
                }}
              >
                Cancel
              </button>
            </div>
          </div>
        ) : (
          <>
            {/* Render attachments above text for user messages */}
            {isUser && message.attachments && message.attachments.length > 0 && (
              <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginBottom: 6 }}>
                {message.attachments.map((att) => (
                  <AttachmentChip key={att.id} attachment={att} />
                ))}
              </div>
            )}

            {/* Docx attachment chips — show filename only, not extracted text */}
            {docxBlocks.length > 0 && (
              <div style={{ display: "flex", flexWrap: "wrap", gap: 6, marginBottom: 6 }}>
                {docxBlocks.map((b, i) => (
                  <span
                    key={i}
                    style={{
                      display: "inline-flex",
                      alignItems: "center",
                      gap: 4,
                      padding: "3px 8px",
                      borderRadius: 6,
                      fontSize: 12,
                      background: "var(--card-bg, #f0f0f0)",
                      border: "1px solid var(--card-border, #ccc)",
                      color: "var(--text-secondary)",
                    }}
                  >
                    📄 {b.filename}
                  </span>
                ))}
              </div>
            )}

            <div className={s["bubble-text"]}>
              {isUser ? (
                <span style={{ whiteSpace: "pre-wrap" }}>{textContent}</span>
              ) : (
                <>
                  {thinking != null && (
                    <ThinkingBlock
                      content={thinking}
                      isThinking={isThinking}
                      durationMs={thinkingDurationMs}
                    />
                  )}
                  {(() => {
                    // Transform <write_file> tags into fenced code blocks for rendering
                    const displayText = transformWriteFileTags(textContent);
                    const { entries: fileBlocks, codeToFilename } = !isUser
                      ? scanFilenameBlocks(displayText)
                      : { entries: [], codeToFilename: new Map<string, string>() };
                    // SaveAllCard: only when projectId set, multiple files, not streaming
                    const useConsolidated = !!projectId && fileBlocks.length > 1 && !useIndividual && !isStreaming;
                    return (
                      <>
                        <ProjectIdContext.Provider value={{
                          projectId: projectId ?? null,
                          onFileSaved: onFileSaved ?? null,
                          hideSaveCard: useConsolidated,
                          codeToFilename,
                          onOpenArtifact: onOpenArtifact ?? null,
                          isStreaming: isStreaming ?? false,
                        }}>
                          <ReactMarkdown
                            remarkPlugins={[remarkGfm, [remarkMath, { singleDollarTextMath: false }], remarkBreaks, remarkEmoji]}
                            rehypePlugins={[rehypeKatex, rehypeHighlight]}
                            components={MD_COMPONENTS_DEFAULT}
                          >
                            {displayText}
                          </ReactMarkdown>
                        </ProjectIdContext.Provider>
                        {useConsolidated && projectId && (
                          <SaveAllCard
                            files={fileBlocks}
                            projectId={projectId}
                            onFileSaved={onFileSaved}
                            onSwitchToIndividual={() => setUseIndividual(true)}
                          />
                        )}
                      </>
                    );
                  })()}
                </>
              )}
              {isStreaming && isLast && <span className={s["streaming-cursor"]} />}
            </div>

            {/* Assistant metrics */}
            {!isUser && (message.input_tokens || message.output_tokens || message.cost_usd || message.latency_ms) && (
              <div className={s["bubble-meta"]}>
                {message.input_tokens != null && <span>{message.input_tokens}↑</span>}
                {message.output_tokens != null && <span>{message.output_tokens}↓</span>}
                {fmtCost(message.cost_usd) && <span>{fmtCost(message.cost_usd)}</span>}
                {fmtMs(message.latency_ms) && <span>{fmtMs(message.latency_ms)}</span>}
              </div>
            )}

            {/* Action buttons */}
            <div className={s["bubble-actions"]}>
              <button className={s["bubble-action-btn"]} onClick={handleCopy}>
                <CopyIcon />
                {copied ? "Copied!" : "Copy"}
              </button>
              {isUser && onEdit && (
                <button className={s["bubble-action-btn"]} onClick={startEdit}>
                  <EditIcon />
                  Edit
                </button>
              )}
              {!isUser && isLast && onRegenerate && !isStreaming && (
                <button className={s["bubble-action-btn"]} onClick={onRegenerate}>
                  <RegenerateIcon />
                  Regenerate
                </button>
              )}
            </div>
          </>
        )}
      </div>
    </div>
  );
});

export default MessageBubble;
