import { useEffect, useRef } from "react";
import type { ChatMessage } from "src/api/types";
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
  onCopy: (text: string) => void;
  onEdit?: (id: string, content: string) => void;
  onRegenerate?: () => void;
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
  onCopy,
  onEdit,
  onRegenerate,
}: Props) {
  const bottomRef = useRef<HTMLDivElement>(null);
  const threadRef = useRef<HTMLDivElement>(null);
  const isUserScrolled = useRef(false);
  const scrollRafRef = useRef<number | null>(null);
  // Track programmatic scrolls so the scroll listener ignores them
  const isProgrammaticScroll = useRef(false);

  // Auto-scroll when new content arrives, unless user has scrolled up.
  // During streaming: instant scroll, throttled to one rAF per frame to avoid
  // queuing competing smooth-scroll animations (which causes the bouncing effect).
  // After streaming: single smooth scroll on message commit.
  useEffect(() => {
    if (isUserScrolled.current) return;

    if (isStreaming) {
      // Throttle to one scroll per animation frame during streaming
      if (scrollRafRef.current !== null) return;
      scrollRafRef.current = requestAnimationFrame(() => {
        scrollRafRef.current = null;
        if (!isUserScrolled.current) {
          isProgrammaticScroll.current = true;
          bottomRef.current?.scrollIntoView({ behavior: "instant" as ScrollBehavior });
        }
      });
    } else {
      // Message just committed — one smooth scroll is safe here
      isProgrammaticScroll.current = true;
      bottomRef.current?.scrollIntoView({ behavior: "smooth" });
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
        created_at: new Date().toISOString(),
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
