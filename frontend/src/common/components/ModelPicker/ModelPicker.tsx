import { memo, useEffect, useMemo, useRef, useState } from "react";
import type { ModelPrice } from "src/api/types";
import s from "src/common/components/layout/Layout.module.scss";

export interface ModelPickerProps {
  models: ModelPrice[];
  value: string;
  onChange: (model: string) => void;
  runnableProviders: Set<string>;
  id?: string;
}

const ModelPicker = memo(function ModelPicker({
  models,
  value,
  onChange,
  runnableProviders,
  id,
}: ModelPickerProps) {
  const [search, setSearch] = useState("");
  const [open, setOpen] = useState(false);
  const [onlyRunnable, setOnlyRunnable] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  const { byProvider, providers } = useMemo(() => {
    const lower = search.toLowerCase();
    const filtered = models.filter((m) => {
      if (onlyRunnable && !runnableProviders.has(m.provider)) return false;
      if (
        search &&
        !m.model.toLowerCase().includes(lower) &&
        !m.provider.toLowerCase().includes(lower)
      )
        return false;
      const lm = m.model.toLowerCase();
      if (lm.includes("embed") || lm.includes("rerank") || lm.includes("moderation"))
        return false;
      return true;
    });
    const byProvider: Record<string, ModelPrice[]> = {};
    for (const m of filtered) {
      (byProvider[m.provider] ??= []).push(m);
    }
    return { byProvider, providers: Object.keys(byProvider).sort() };
  }, [models, search, onlyRunnable, runnableProviders]);

  useEffect(() => {
    if (!open) return;
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) {
        setOpen(false);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [open]);

  const displayLabel = value || "Select model…";

  return (
    <div ref={ref} style={{ position: "relative" }} id={id}>
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className={s["form-input"]}
        style={{
          width: "100%",
          textAlign: "left",
          cursor: "pointer",
          display: "flex",
          justifyContent: "space-between",
          alignItems: "center",
          padding: "6px 10px",
        }}
        aria-haspopup="listbox"
        aria-expanded={open}
      >
        <span style={{ overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
          {displayLabel}
        </span>
        <span style={{ marginLeft: 8, flexShrink: 0 }}>▾</span>
      </button>

      {open && (
        <div
          role="listbox"
          style={{
            position: "absolute",
            top: "calc(100% + 4px)",
            left: 0,
            right: 0,
            zIndex: 100,
            background: "var(--card-bg)",
            border: "1px solid var(--card-border)",
            borderRadius: 6,
            boxShadow: "0 4px 16px rgba(0,0,0,0.15)",
            maxHeight: 360,
            display: "flex",
            flexDirection: "column",
          }}
        >
          <div style={{ padding: "8px 8px 4px" }}>
            <input
              autoFocus
              type="text"
              placeholder="Search models…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              className={s["form-input"]}
              style={{ margin: 0 }}
              aria-label="Search models"
            />
            <label
              style={{
                display: "flex",
                alignItems: "center",
                gap: 6,
                marginTop: 6,
                fontSize: 12,
                color: "var(--text-secondary)",
                cursor: "pointer",
                userSelect: "none",
              }}
            >
              <input
                type="checkbox"
                checked={onlyRunnable}
                onChange={(e) => setOnlyRunnable(e.target.checked)}
                aria-label="Only show runnable models"
              />
              Only show runnable models
            </label>
          </div>
          <div style={{ overflowY: "auto", flex: 1 }}>
            {providers.length === 0 && (
              <div className={s.empty} style={{ padding: "16px 12px" }}>
                No models match
              </div>
            )}
            {providers.map((prov) => (
              <div key={prov}>
                <div
                  style={{
                    padding: "6px 12px 2px",
                    fontSize: 11,
                    fontWeight: 600,
                    textTransform: "uppercase",
                    letterSpacing: "0.06em",
                    color: "var(--text-secondary)",
                    position: "sticky",
                    top: 0,
                    background: "var(--card-bg)",
                    display: "flex",
                    alignItems: "center",
                    gap: 6,
                  }}
                >
                  {prov}
                  {!runnableProviders.has(prov) && (
                    <span
                      style={{
                        opacity: 0.45,
                        fontWeight: 400,
                        fontSize: 10,
                        textTransform: "none",
                        letterSpacing: 0,
                      }}
                    >
                      no key
                    </span>
                  )}
                </div>
                {byProvider[prov].map((m) => (
                  <div
                    key={m.model}
                    role="option"
                    aria-selected={m.model === value}
                    className={s["model-option"]}
                    data-selected={m.model === value ? "true" : undefined}
                    onClick={() => {
                      onChange(m.model);
                      setOpen(false);
                      setSearch("");
                    }}
                  >
                    {m.model}
                  </div>
                ))}
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
});

export default ModelPicker;
