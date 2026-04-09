import { useState } from "react";
import { SlashCommand } from "src/api/types";
import { Modal } from "src/common/components/Modal";
import s from "src/common/components/layout/Layout.module.scss";

interface Props {
  command: SlashCommand;
  onInsert: (expandedText: string) => void;
  onCancel: () => void;
}

function extractVars(template: string): string[] {
  const found: string[] = [];
  const re = /\{\{(\w+)\}\}/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(template)) !== null) {
    if (!found.includes(m[1])) found.push(m[1]);
  }
  return found;
}

export function VariableFillModal({ command, onInsert, onCancel }: Props) {
  const vars = extractVars(command.template);
  const [values, setValues] = useState<Record<string, string>>(
    Object.fromEntries(vars.map((v) => [v, ""]))
  );

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    let expanded = command.template;
    for (const [k, v] of Object.entries(values)) {
      expanded = expanded.replaceAll(`{{${k}}}`, v);
    }
    onInsert(expanded);
  }

  const preview = vars.reduce(
    (t, v) => t.replaceAll(`{{${v}}}`, values[v] ? `[${values[v]}]` : `{{${v}}}`),
    command.template
  );

  return (
    <Modal title={`Fill in /${command.name}`} onClose={onCancel}>
      <form onSubmit={handleSubmit}>
        {vars.map((v) => (
          <div key={v} className={s["form-group"]}>
            <label className={s["form-label"]} htmlFor={`var-${v}`}>{v}</label>
            <input
              id={`var-${v}`}
              className={s["form-input"]}
              value={values[v]}
              onChange={(e) => setValues((prev) => ({ ...prev, [v]: e.target.value }))}
              placeholder={`Enter ${v}`}
              autoFocus={v === vars[0]}
            />
          </div>
        ))}
        <div style={{ marginBottom: 12, padding: "8px 10px", background: "var(--surface-2)", borderRadius: 6, fontSize: 12, fontFamily: "monospace", color: "var(--text-secondary)", wordBreak: "break-word" }}>
          {preview}
        </div>
        <div className={s["form-actions"]}>
          <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onCancel}>Cancel</button>
          <button type="submit" className={`${s.btn} ${s["btn--primary"]}`}>Insert →</button>
        </div>
      </form>
    </Modal>
  );
}
