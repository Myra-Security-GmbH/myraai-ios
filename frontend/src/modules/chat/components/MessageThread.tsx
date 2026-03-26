import { useEffect, useRef } from "react";
import type { ChatMessage } from "src/api/types";
import MessageBubble from "./MessageBubble";
import s from "../pages/Chat.module.scss";

interface Props {
  messages: ChatMessage[];
  streamingContent: string | null;
  isStreaming: boolean;
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
  onCopy,
  onEdit,
  onRegenerate,
}: Props) {
  const bottomRef = useRef<HTMLDivElement>(null);
  const threadRef = useRef<HTMLDivElement>(null);
  const isUserScrolled = useRef(false);

  // Auto-scroll when new content arrives, unless user has scrolled up
  useEffect(() => {
    if (!isUserScrolled.current) {
      bottomRef.current?.scrollIntoView({ behavior: "smooth" });
    }
  }, [messages, streamingContent]);

  // Detect manual scroll
  useEffect(() => {
    const el = threadRef.current;
    if (!el) return;
    const onScroll = () => {
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

  if (messages.length === 0 && !isStreaming) {
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
      {allMessages.map((msg, idx) => (
        <MessageBubble
          key={msg.id}
          message={msg}
          isLast={idx === allMessages.length - 1}
          isStreaming={isStreaming && idx === allMessages.length - 1}
          onCopy={onCopy}
          onEdit={onEdit}
          onRegenerate={idx === allMessages.length - 1 && msg.role === "assistant" ? onRegenerate : undefined}
        />
      ))}
      <div ref={bottomRef} />
    </div>
  );
}
