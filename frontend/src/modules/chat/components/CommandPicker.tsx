import { useEffect, useRef, useState } from "react";
import { SlashCommand } from "src/api/types";
import s from "./CommandPicker.module.scss";

interface Props {
  query: string;
  commands: SlashCommand[];
  onSelect: (cmd: SlashCommand) => void;
  onDismiss: () => void;
}

export function CommandPicker({ query, commands, onSelect, onDismiss }: Props) {
  const lower = query.toLowerCase();
  const filtered = commands.filter((c) => c.name.startsWith(lower));
  const [idx, setIdx] = useState(0);
  const listRef = useRef<HTMLDivElement>(null);

  // Reset selection when query changes
  useEffect(() => { setIdx(0); }, [query]);

  // Clamp idx
  const safeIdx = Math.min(idx, Math.max(filtered.length - 1, 0));

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (!filtered.length) return;
      if (e.key === "ArrowDown") {
        e.preventDefault();
        setIdx((i) => Math.min(i + 1, filtered.length - 1));
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        setIdx((i) => Math.max(i - 1, 0));
      } else if (e.key === "Enter") {
        e.preventDefault();
        onSelect(filtered[safeIdx]);
      } else if (e.key === "Escape") {
        e.preventDefault();
        onDismiss();
      }
    }
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [filtered, safeIdx, onSelect, onDismiss]);

  if (filtered.length === 0) return null;

  return (
    <div className={s["picker"]} ref={listRef}>
      {filtered.map((cmd, i) => (
        <div
          key={cmd.id}
          className={[s["item"], i === safeIdx ? s["item--active"] : ""].filter(Boolean).join(" ")}
          onMouseDown={(e) => { e.preventDefault(); onSelect(cmd); }}
          onMouseEnter={() => setIdx(i)}
        >
          <span className={s["item-name"]}>/{cmd.name}</span>
          {cmd.description && <span className={s["item-desc"]}>{cmd.description}</span>}
        </div>
      ))}
    </div>
  );
}
