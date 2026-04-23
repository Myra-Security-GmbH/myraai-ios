import { useEffect, useRef, useState } from "react";
import type { ChatMessage, ChatProject, ProjectKnowledgeText } from "src/api/types";
import type { Artifact } from "./ArtifactPanel";
import MessageBubble from "./MessageBubble";
import s from "../pages/Chat.module.scss";

interface Props {
  messages: ChatMessage[];
  streamingContent: string | null;
  isStreaming: boolean;
  processingStatus?: string | null;
  streamingThinkingDurationMs?: number | null;
  /** If set, code blocks with a filename comment get a "Save to Project" card */
  projectId?: string | null;
  onFileSaved?: ((filename: string, content: string, lang: string) => void) | null;
  /** Called when the user clicks an artifact card to open the side panel */
  onOpenArtifact?: ((artifact: Artifact) => void) | null;
  onCopy: (text: string) => void;
  onEdit?: (id: string, content: string) => void;
  onRegenerate?: () => void;
  /** When set and messages are empty, show a project welcome card instead of generic empty state */
  activeProject?: ChatProject | null;
  projectKnowledge?: ProjectKnowledgeText[];
}

function BotIcon() {
  return (
    <svg width="40" height="40" viewBox="0 0 24 24" fill="none" stroke="var(--text-secondary)" strokeWidth="1.5" strokeLinecap="round">
      <rect x="3" y="11" width="18" height="10" rx="2" ry="2" />
      <path d="M12 3v8M8 7h8M9 15h.01M15 15h.01" />
    </svg>
  );
}

export default function MessageThread({
  messages,
  streamingContent,
  isStreaming,
  processingStatus,
  streamingThinkingDurationMs,
  projectId,
  onFileSaved,
  onOpenArtifact,
  onCopy,
  onEdit,
  onRegenerate,
  activeProject,
  projectKnowledge = [],
}: Props) {
  const [instructionsExpanded, setInstructionsExpanded] = useState(false);
  const bottomRef = useRef<HTMLDivElement>(null);
  const threadRef = useRef<HTMLDivElement>(null);
  const isUserScrolled = useRef(false);
  const scrollRafRef = useRef<number | null>(null);
  // Track programmatic scrolls so the scroll listener ignores them
  const isProgrammaticScroll = useRef(false);
  // Detect streaming → done transition to trigger scroll-to-question behavior
  const prevIsStreaming = useRef(false);

  // Auto-scroll when new content arrives, unless user has scrolled up.
  // During streaming: instant scroll to bottom, throttled to one rAF per frame
  // to avoid queuing competing animations (bouncing effect fixed in 235bfdd).
  // After streaming completes: scroll to show the user's question at the top of
  // the viewport so the reader sees context + beginning of response, not the end.
  // On initial load / non-streaming messages: scroll to bottom as before.
  useEffect(() => {
    const justFinished = prevIsStreaming.current && !isStreaming;
    prevIsStreaming.current = isStreaming;

    if (isUserScrolled.current) return;

    if (isStreaming) {
      // Throttle to one scroll per animation frame during streaming
      if (scrollRafRef.current !== null) return;
      scrollRafRef.current = requestAnimationFrame(() => {
        scrollRafRef.current = null;
        if (!isUserScrolled.current) {
          isProgrammaticScroll.current = true;
          // Use direct scrollTop on the container instead of scrollIntoView.
          // scrollIntoView with html.style.zoom > 1 (Vanadium desktop mode) can
          // escape the .thread scroll ancestor and scroll the document/visual
          // viewport, lifting the entire layout off screen.
          const el = threadRef.current;
          if (el) el.scrollTop = el.scrollHeight;
        }
      });
    } else if (justFinished) {
      // Streaming just completed — scroll to show the last user message near the
      // top so the user sees their question and the beginning of the response.
      isProgrammaticScroll.current = true;
      const el = threadRef.current;
      if (el) {
        const userRows = el.querySelectorAll("[class*='user-row']");
        const lastUserRow = userRows.length > 0
          ? (userRows[userRows.length - 1] as HTMLElement)
          : null;
        if (lastUserRow) {
          // getBoundingClientRect gives viewport-relative coords; adjust by
          // current scrollTop to get scroll-container-relative target.
          const elRect = el.getBoundingClientRect();
          const rowRect = lastUserRow.getBoundingClientRect();
          const target = el.scrollTop + rowRect.top - elRect.top - 16;
          el.scrollTop = Math.min(
            Math.max(0, target),
            Math.max(0, el.scrollHeight - el.clientHeight),
          );
        } else {
          el.scrollTop = el.scrollHeight;
        }
      }
    } else {
      // Initial conversation load or non-streaming message — scroll to bottom.
      isProgrammaticScroll.current = true;
      const el = threadRef.current;
      if (el) el.scrollTop = el.scrollHeight;
    }
  }, [messages, streamingContent, processingStatus, isStreaming]);

  // Cancel any pending rAF on unmount
  useEffect(() => {
    return () => {
      if (scrollRafRef.current !== null) cancelAnimationFrame(scrollRafRef.current);
    };
  }, []);

  // Detect manual scroll — ignore programmatic scrolls triggered by auto-scroll
  useEffect(() => {
    const el = threadRef.current;
    if (!el) return;
    const onScroll = () => {
      if (isProgrammaticScroll.current) {
        isProgrammaticScroll.current = false;
        return;
      }
      const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
      isUserScrolled.current = !atBottom;
    };
    el.addEventListener("scroll", onScroll, { passive: true });
    return () => el.removeEventListener("scroll", onScroll);
  }, []);

  // When streaming starts, reset user scroll flag so we follow along
  useEffect(() => {
    if (isStreaming) isUserScrolled.current = false;
  }, [isStreaming]);

  if (messages.length === 0 && !isStreaming && !processingStatus) {
    if (activeProject) {
      const MAX_CHIPS = 5;
      const extraFiles = projectKnowledge.length > MAX_CHIPS ? projectKnowledge.length - MAX_CHIPS : 0;
      const visibleFiles = projectKnowledge.slice(0, MAX_CHIPS);
      return (
        <div className={s.thread}>
          <div className={s["project-welcome"]}>
            <div className={s["project-welcome-icon"]} style={{ background: activeProject.color || "var(--accent)" }}>
              {activeProject.icon}
            </div>
            <h2 className={s["project-welcome-name"]}>{activeProject.name}</h2>
            {activeProject.description && (
              <p className={s["project-welcome-desc"]}>{activeProject.description}</p>
            )}
            {activeProject.instructions && (
              <div className={s["project-welcome-instructions"]}>
                <button
                  className={s["project-welcome-instructions-toggle"]}
                  onClick={() => setInstructionsExpanded((v) => !v)}
                  type="button"
                >
                  <span>{instructionsExpanded ? "▾" : "▸"}</span>
                  <span>Instructions</span>
                </button>
                {instructionsExpanded && (
                  <pre className={s["project-welcome-instructions-body"]}>
                    {activeProject.instructions}
                  </pre>
                )}
              </div>
            )}
            {projectKnowledge.length > 0 && (
              <div className={s["project-welcome-files"]}>
                {visibleFiles.map((f) => (
                  <span key={f.id} className={s["project-welcome-file-chip"]} title={f.filename}>
                    📎 {f.filename}
                  </span>
                ))}
                {extraFiles > 0 && (
                  <span className={s["project-welcome-file-chip"]}>+{extraFiles} more</span>
                )}
              </div>
            )}
            <p className={s["project-welcome-hint"]}>Start a new chat below</p>
          </div>
        </div>
      );
    }
    return (
      <div className={s.thread}>
        <div className={s["thread-empty"]}>
          <BotIcon />
          <h3>Start a conversation</h3>
          <p>Type a message below to begin chatting with the AI model.</p>
        </div>
      </div>
    );
  }

  // Build streaming message if active
  const streamingMsg: ChatMessage | null = isStreaming
    ? {
        id: "__streaming__",
        conversation_id: "",
        parent_message_id: null,
        role: "assistant",
        content: streamingContent ?? "",
        input_tokens: null,
        output_tokens: null,
        cost_usd: null,
        latency_ms: null,
        created_at: Math.floor(Date.now() / 1000),
      }
    : null;

  const allMessages = streamingMsg ? [...messages, streamingMsg] : messages;

  return (
    <div className={s.thread} ref={threadRef}>
      {allMessages.map((msg, idx) => {
        const isThisBubbleStreaming = isStreaming && idx === allMessages.length - 1;
        return (
          <MessageBubble
            key={msg.id}
            message={msg}
            isLast={idx === allMessages.length - 1}
            isStreaming={isThisBubbleStreaming}
            thinkingDurationMs={isThisBubbleStreaming ? streamingThinkingDurationMs : null}
            projectId={projectId}
            onFileSaved={onFileSaved}
            onOpenArtifact={onOpenArtifact}
            onCopy={onCopy}
            onEdit={onEdit}
            onRegenerate={idx === allMessages.length - 1 && msg.role === "assistant" ? onRegenerate : undefined}
          />
        );
      })}
      {processingStatus && !isStreaming && (
        <div className={s["processing-row"]}>
          <span className={s["processing-spinner"]} />
          <span className={s["processing-text"]}>{processingStatus}</span>
        </div>
      )}
      <div ref={bottomRef} />
    </div>
  );
}
