import { useState, useEffect } from "react";
import s from "./ThinkingBlock.module.scss";

function BrainIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M9.5 2A2.5 2.5 0 0 1 12 4.5v15a2.5 2.5 0 0 1-4.96-.44 2.5 2.5 0 0 1-2.96-3.08 3 3 0 0 1-.34-5.58 2.5 2.5 0 0 1 1.32-4.24 2.5 2.5 0 0 1 1.98-3A2.5 2.5 0 0 1 9.5 2Z" />
      <path d="M14.5 2A2.5 2.5 0 0 0 12 4.5v15a2.5 2.5 0 0 0 4.96-.44 2.5 2.5 0 0 0 2.96-3.08 3 3 0 0 0 .34-5.58 2.5 2.5 0 0 0-1.32-4.24 2.5 2.5 0 0 0-1.98-3A2.5 2.5 0 0 0 14.5 2Z" />
    </svg>
  );
}

function SpinnerIcon() {
  return <span className={s.spinner} />;
}

function ChevronIcon({ open }: { open: boolean }) {
  return (
    <svg
      width="11"
      height="11"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.5"
      strokeLinecap="round"
      style={{ transition: "transform 0.2s", transform: open ? "rotate(180deg)" : "rotate(0deg)" }}
    >
      <polyline points="6 9 12 15 18 9" />
    </svg>
  );
}

function fmtDuration(ms: number): string {
  if (ms < 1000) return `${ms}ms`;
  return `${(ms / 1000).toFixed(1)}s`;
}

interface Props {
  content: string;
  /** Still accumulating — </think> not yet seen */
  isThinking?: boolean;
  /** How long the think phase took (only set once </think> is received) */
  durationMs?: number | null;
}

export default function ThinkingBlock({ content, isThinking, durationMs }: Props) {
  // Open by default while streaming; collapse when done (unless user toggled)
  const [open, setOpen] = useState(isThinking ?? false);
  const [userToggled, setUserToggled] = useState(false);

  useEffect(() => {
    if (!isThinking && !userToggled) {
      setOpen(false);
    }
  }, [isThinking, userToggled]);

  function toggle() {
    setUserToggled(true);
    setOpen((v) => !v);
  }

  return (
    <div className={s.container}>
      <button className={s.header} onClick={toggle} type="button">
        <span className={s.icon}>
          {isThinking ? <SpinnerIcon /> : <BrainIcon />}
        </span>
        <span className={s.label}>
          {isThinking ? "Thinking…" : "Thought process"}
        </span>
        {!isThinking && durationMs != null && (
          <span className={s.duration}>{fmtDuration(durationMs)}</span>
        )}
        <ChevronIcon open={open} />
      </button>
      <div className={[s.body, open ? "" : s["body-collapsed"]].filter(Boolean).join(" ")}>
        <pre className={s.text}>{content || " "}</pre>
      </div>
    </div>
  );
}
