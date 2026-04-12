import type { ChatPreset } from "src/api/types";
import s from "../pages/Chat.module.scss";

function XIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <line x1="18" y1="6" x2="6" y2="18" />
      <line x1="6" y1="6" x2="18" y2="18" />
    </svg>
  );
}

export interface DrawerSettings {
  systemPrompt: string;
  temperature: number;
  maxTokens: number;
  webSearch: boolean;
  /** null = off; number = thinking budget in tokens (1000–32000) */
  thinkingBudget: number | null;
}

interface Props {
  settings: DrawerSettings;
  onChange: (s: DrawerSettings) => void;
  onSave: () => void;
  onClose: () => void;
  presets: ChatPreset[];
  onApplyPreset: (preset: ChatPreset) => void;
  onSavePreset: (name: string) => void;
  onDeletePreset: (id: string) => void;
  /** Whether the currently selected model supports extended thinking */
  supportsThinking: boolean;
}

export default function SettingsDrawer({
  settings,
  onChange,
  onSave,
  onClose,
  presets,
  onApplyPreset,
  onSavePreset,
  onDeletePreset,
  supportsThinking,
}: Props) {
  function upd(partial: Partial<DrawerSettings>) {
    onChange({ ...settings, ...partial });
  }

  function handleSavePreset() {
    const name = window.prompt("Preset name:");
    if (name?.trim()) onSavePreset(name.trim());
  }

  return (
    <div className={s["settings-overlay"]} onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className={s["settings-drawer"]}>
        <div className={s["settings-header"]}>
          Settings
          <button className={s["icon-btn"]} onClick={onClose} title="Close">
            <XIcon />
          </button>
        </div>

        <div className={s["settings-body"]}>
          <div className={s["settings-field"]}>
            <label className={s["settings-label"]}>System prompt</label>
            <textarea
              className={s["settings-textarea"]}
              value={settings.systemPrompt}
              onChange={(e) => upd({ systemPrompt: e.target.value })}
              placeholder="Optional system instructions…"
            />
          </div>

          <div className={s["settings-field"]}>
            <label className={s["settings-label"]}>
              Temperature — {settings.temperature.toFixed(2)}
            </label>
            <input
              type="range"
              min="0"
              max="2"
              step="0.05"
              value={settings.temperature}
              onChange={(e) => upd({ temperature: parseFloat(e.target.value) })}
              style={{ width: "100%" }}
            />
          </div>

          <div className={s["settings-field"]}>
            <label className={s["settings-label"]}>Max tokens</label>
            <input
              type="number"
              className={s["settings-input"]}
              value={settings.maxTokens}
              min={1}
              max={200000}
              onChange={(e) => upd({ maxTokens: parseInt(e.target.value, 10) || 2048 })}
            />
          </div>

          <div className={s["settings-field"]}>
            <label className={s["settings-label"]} style={{ display: "flex", alignItems: "center", gap: 8 }}>
              <input
                type="checkbox"
                checked={settings.webSearch}
                onChange={(e) => upd({ webSearch: e.target.checked })}
              />
              Web search (Anthropic models only)
            </label>
          </div>

          {supportsThinking && (
            <div className={s["settings-field"]}>
              <label className={s["settings-label"]} style={{ display: "flex", alignItems: "center", gap: 8 }}>
                <input
                  type="checkbox"
                  checked={settings.thinkingBudget !== null}
                  onChange={(e) => upd({ thinkingBudget: e.target.checked ? 10000 : null })}
                  data-cy="thinking-toggle"
                />
                Extended thinking
              </label>
              {settings.thinkingBudget !== null && (
                <>
                  <div style={{ fontSize: 11, color: "var(--text-secondary)", marginTop: 4 }}>
                    Thinking tokens: {settings.thinkingBudget.toLocaleString()}
                    {" — "}
                    <span style={{ color: "var(--text-secondary)", fontStyle: "italic" }}>
                      Temperature is disabled while thinking is on
                    </span>
                  </div>
                  <input
                    type="range"
                    min="1000"
                    max="32000"
                    step="1000"
                    value={settings.thinkingBudget}
                    onChange={(e) => upd({ thinkingBudget: parseInt(e.target.value, 10) })}
                    style={{ width: "100%", marginTop: 6 }}
                    data-cy="thinking-budget-slider"
                  />
                  <div style={{ display: "flex", justifyContent: "space-between", fontSize: 10, color: "var(--text-secondary)" }}>
                    <span>1k</span><span>32k</span>
                  </div>
                </>
              )}
            </div>
          )}

          {/* Presets section */}
          <div className={s["settings-field"]}>
            <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between" }}>
              <label className={s["settings-label"]}>Presets</label>
              <button
                onClick={handleSavePreset}
                style={{
                  fontSize: 11,
                  padding: "2px 8px",
                  border: "1px solid var(--card-border)",
                  borderRadius: 4,
                  background: "transparent",
                  color: "var(--text-secondary)",
                  cursor: "pointer",
                }}
              >
                Save current
              </button>
            </div>

            {presets.length === 0 ? (
              <div style={{ fontSize: 12, color: "var(--text-secondary)", padding: "8px 0" }}>
                No presets yet. Save current settings to create one.
              </div>
            ) : (
              <div className={s["preset-list"]}>
                {presets.map((p) => (
                  <div key={p.id} className={s["preset-item"]} onClick={() => onApplyPreset(p)}>
                    <div className={s["preset-name"]}>{p.name}</div>
                    <div className={s["preset-model"]}>{p.model}</div>
                    <button
                      onClick={(e) => { e.stopPropagation(); onDeletePreset(p.id); }}
                      style={{
                        background: "none",
                        border: "none",
                        cursor: "pointer",
                        color: "var(--text-secondary)",
                        padding: 2,
                        fontSize: 11,
                        flexShrink: 0,
                      }}
                      title="Delete preset"
                    >
                      ✕
                    </button>
                  </div>
                ))}
              </div>
            )}
          </div>
        </div>

        <div className={s["settings-footer"]}>
          <button
            onClick={onClose}
            style={{
              padding: "6px 14px",
              fontSize: 13,
              border: "1px solid var(--card-border)",
              borderRadius: 6,
              background: "transparent",
              color: "var(--text-secondary)",
              cursor: "pointer",
            }}
          >
            Cancel
          </button>
          <button
            onClick={() => { onSave(); onClose(); }}
            style={{
              padding: "6px 14px",
              fontSize: 13,
              border: "none",
              borderRadius: 6,
              background: "var(--accent, #0052cc)",
              color: "#fff",
              cursor: "pointer",
            }}
          >
            Save
          </button>
        </div>
      </div>
    </div>
  );
}
