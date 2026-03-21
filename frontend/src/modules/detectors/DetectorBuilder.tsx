// modules/detectors/DetectorBuilder.tsx
// Ordered list of detector configs for a gateway.
// Used inside the Gateways EditGatewayModal.

import { useState } from "react";
import {
  DetectorConfig,
  RegexDetector,
  KeywordDetector,
  PresidioDetector,
  LlmGuardDetector,
  DetectorAction,
  DetectorTarget,
  PatternName,
  PatternSetName,
} from "src/api/types";
import s from "src/common/components/layout/Layout.module.scss";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const PATTERN_NAMES: PatternName[] = [
  "email", "phone", "ssn", "dob", "ip_address",
  "cc", "cvv", "card_expiry", "iban", "routing_number",
  "mrn", "npi", "national_id", "passport_number",
  "api_key", "jwt",
];

const PATTERN_SETS: PatternSetName[] = [
  "pci_pan", "hipaa_structured", "gdpr_structured", "credentials", "pii_basic",
];

const PATTERN_SET_DESCRIPTIONS: Record<PatternSetName, string> = {
  pci_pan: "PCI — credit card, CVV, expiry, IBAN, routing",
  hipaa_structured: "HIPAA — SSN, MRN, NPI, DOB, phone, email, IP",
  gdpr_structured: "GDPR — email, phone, IP, IBAN, national ID, passport",
  credentials: "Credentials — API keys, JWTs",
  pii_basic: "PII basic — email, phone, SSN",
};

const DETECTOR_ACTIONS: DetectorAction[] = ["block", "scrub", "flag"];
const DETECTOR_TARGETS: DetectorTarget[] = ["request", "response", "both"];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function emptyRegex(): RegexDetector {
  return { type: "regex", name: "pii-check", action: "block", target: "request", patterns: [], custom_patterns: [] };
}

function emptyKeyword(): KeywordDetector {
  return { type: "keyword", name: "keyword-check", action: "flag", target: "request", keywords: [], case_sensitive: false };
}

function emptyPresidio(): PresidioDetector {
  return { type: "presidio", name: "presidio-pii", action: "block", target: "request", url: "http://127.0.0.1:5002", language: "en", entities: [], score_threshold: 0.7, fail_open: true };
}

function emptyLlmGuard(): LlmGuardDetector {
  return { type: "llm_guard", name: "llm-guard", action: "block", target: "request", url: "http://127.0.0.1:8083", timeout_ms: 3000, categories: [], fail_open: true };
}

// ---------------------------------------------------------------------------
// Sub-editors for each detector type
// ---------------------------------------------------------------------------

function CommonFields({ det, onChange }: { det: DetectorConfig; onChange: (d: DetectorConfig) => void }) {
  return (
    <div style={{ display: "flex", gap: 8, flexWrap: "wrap" }}>
      <div className={s["form-group"]} style={{ flex: "2 1 160px" }}>
        <label className={s["form-label"]}>Name</label>
        <input
          className={s["form-input"]}
          value={det.name}
          onChange={(e) => onChange({ ...det, name: e.target.value })}
          placeholder="detector-name"
        />
      </div>
      <div className={s["form-group"]} style={{ flex: "1 1 100px" }}>
        <label className={s["form-label"]}>Action</label>
        <select
          className={s["form-select"]}
          value={det.action}
          onChange={(e) => onChange({ ...det, action: e.target.value as DetectorAction })}
        >
          {DETECTOR_ACTIONS.map((a) => <option key={a} value={a}>{a}</option>)}
        </select>
      </div>
      <div className={s["form-group"]} style={{ flex: "1 1 100px" }}>
        <label className={s["form-label"]}>Target</label>
        <select
          className={s["form-select"]}
          value={det.target ?? "request"}
          onChange={(e) => onChange({ ...det, target: e.target.value as DetectorTarget })}
        >
          {DETECTOR_TARGETS.map((t) => <option key={t} value={t}>{t}</option>)}
        </select>
      </div>
    </div>
  );
}

function RegexEditor({ det, onChange }: { det: RegexDetector; onChange: (d: RegexDetector) => void }) {
  const [customInput, setCustomInput] = useState("");

  function togglePattern(name: PatternName | PatternSetName) {
    const current = det.patterns ?? [];
    const idx = current.indexOf(name);
    onChange({ ...det, patterns: idx === -1 ? [...current, name] : current.filter((p) => p !== name) });
  }

  function addCustom() {
    const trimmed = customInput.trim();
    if (!trimmed) return;
    onChange({ ...det, custom_patterns: [...(det.custom_patterns ?? []), trimmed] });
    setCustomInput("");
  }

  function removeCustom(i: number) {
    const cp = [...(det.custom_patterns ?? [])];
    cp.splice(i, 1);
    onChange({ ...det, custom_patterns: cp });
  }

  return (
    <>
      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Pattern sets</label>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
          {PATTERN_SETS.map((ps) => (
            <label key={ps} style={{ display: "flex", alignItems: "center", gap: 4, fontSize: 13, cursor: "pointer" }} title={PATTERN_SET_DESCRIPTIONS[ps]}>
              <input
                type="checkbox"
                checked={(det.patterns ?? []).includes(ps)}
                onChange={() => togglePattern(ps)}
              />
              {ps}
            </label>
          ))}
        </div>
      </div>
      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Individual patterns</label>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 6 }}>
          {PATTERN_NAMES.map((pn) => (
            <label key={pn} style={{ display: "flex", alignItems: "center", gap: 4, fontSize: 13, cursor: "pointer" }}>
              <input
                type="checkbox"
                checked={(det.patterns ?? []).includes(pn)}
                onChange={() => togglePattern(pn)}
              />
              {pn}
            </label>
          ))}
        </div>
      </div>
      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Custom patterns (Lua regex)</label>
        <div style={{ display: "flex", gap: 6 }}>
          <input
            className={s["form-input"]}
            value={customInput}
            onChange={(e) => setCustomInput(e.target.value)}
            placeholder="%d%d%d%d%-%d%d%d%d"
            onKeyDown={(e) => e.key === "Enter" && (e.preventDefault(), addCustom())}
          />
          <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={addCustom}>Add</button>
        </div>
        {(det.custom_patterns ?? []).length > 0 && (
          <div style={{ marginTop: 6, display: "flex", flexWrap: "wrap", gap: 4 }}>
            {(det.custom_patterns ?? []).map((cp, i) => (
              <span key={i} style={{ display: "flex", alignItems: "center", gap: 4, background: "var(--surface-2, #f4f4f5)", borderRadius: 4, padding: "2px 8px", fontSize: 12, fontFamily: "monospace" }}>
                {cp}
                <button type="button" onClick={() => removeCustom(i)} style={{ background: "none", border: "none", cursor: "pointer", padding: 0, lineHeight: 1, color: "var(--text-muted, #888)" }}>×</button>
              </span>
            ))}
          </div>
        )}
      </div>
      {det.action === "scrub" && (
        <div className={s["form-group"]}>
          <label className={s["form-label"]}>Scrub placeholder</label>
          <input
            className={s["form-input"]}
            value={det.scrub_placeholder ?? "[REDACTED]"}
            onChange={(e) => onChange({ ...det, scrub_placeholder: e.target.value })}
          />
        </div>
      )}
    </>
  );
}

function KeywordEditor({ det, onChange }: { det: KeywordDetector; onChange: (d: KeywordDetector) => void }) {
  const [kwInput, setKwInput] = useState("");

  function addKeyword() {
    const trimmed = kwInput.trim();
    if (!trimmed) return;
    onChange({ ...det, keywords: [...det.keywords, trimmed] });
    setKwInput("");
  }

  function removeKeyword(i: number) {
    const kws = [...det.keywords];
    kws.splice(i, 1);
    onChange({ ...det, keywords: kws });
  }

  return (
    <>
      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Keywords</label>
        <div style={{ display: "flex", gap: 6 }}>
          <input
            className={s["form-input"]}
            value={kwInput}
            onChange={(e) => setKwInput(e.target.value)}
            placeholder="confidential"
            onKeyDown={(e) => e.key === "Enter" && (e.preventDefault(), addKeyword())}
          />
          <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={addKeyword}>Add</button>
        </div>
        {det.keywords.length > 0 && (
          <div style={{ marginTop: 6, display: "flex", flexWrap: "wrap", gap: 4 }}>
            {det.keywords.map((kw, i) => (
              <span key={i} style={{ display: "flex", alignItems: "center", gap: 4, background: "var(--surface-2, #f4f4f5)", borderRadius: 4, padding: "2px 8px", fontSize: 12 }}>
                {kw}
                <button type="button" onClick={() => removeKeyword(i)} style={{ background: "none", border: "none", cursor: "pointer", padding: 0, lineHeight: 1, color: "var(--text-muted, #888)" }}>×</button>
              </span>
            ))}
          </div>
        )}
      </div>
      <div className={s["form-group"]}>
        <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer" }}>
          <input
            type="checkbox"
            checked={det.case_sensitive ?? false}
            onChange={(e) => onChange({ ...det, case_sensitive: e.target.checked })}
          />
          <span className={s["form-label"]} style={{ margin: 0 }}>Case sensitive</span>
        </label>
      </div>
    </>
  );
}

function PresidioEditor({ det, onChange }: { det: PresidioDetector; onChange: (d: PresidioDetector) => void }) {
  const [entityInput, setEntityInput] = useState("");

  function addEntity() {
    const trimmed = entityInput.trim().toUpperCase();
    if (!trimmed) return;
    onChange({ ...det, entities: [...(det.entities ?? []), trimmed] });
    setEntityInput("");
  }

  function removeEntity(i: number) {
    const ents = [...(det.entities ?? [])];
    ents.splice(i, 1);
    onChange({ ...det, entities: ents });
  }

  return (
    <>
      <div className={s["form-row"]}>
        <div className={s["form-group"]}>
          <label className={s["form-label"]}>Presidio URL</label>
          <input
            className={s["form-input"]}
            value={det.url ?? "http://127.0.0.1:5002"}
            onChange={(e) => onChange({ ...det, url: e.target.value })}
          />
        </div>
        <div className={s["form-group"]}>
          <label className={s["form-label"]}>Language</label>
          <select
            className={s["form-select"]}
            value={det.language ?? "en"}
            onChange={(e) => onChange({ ...det, language: e.target.value })}
          >
            <option value="en">en</option>
            <option value="de">de</option>
          </select>
        </div>
      </div>
      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Score threshold</label>
        <input
          className={s["form-input"]}
          type="number"
          min="0"
          max="1"
          step="0.05"
          value={det.score_threshold ?? 0.7}
          onChange={(e) => onChange({ ...det, score_threshold: parseFloat(e.target.value) })}
        />
        <p className={s["form-hint"]}>0 = detect everything, 1 = only high-confidence hits</p>
      </div>
      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Entity types (leave empty = all)</label>
        <div style={{ display: "flex", gap: 6 }}>
          <input
            className={s["form-input"]}
            value={entityInput}
            onChange={(e) => setEntityInput(e.target.value)}
            placeholder="PERSON, EMAIL_ADDRESS…"
            onKeyDown={(e) => e.key === "Enter" && (e.preventDefault(), addEntity())}
          />
          <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={addEntity}>Add</button>
        </div>
        {(det.entities ?? []).length > 0 && (
          <div style={{ marginTop: 6, display: "flex", flexWrap: "wrap", gap: 4 }}>
            {(det.entities ?? []).map((ent, i) => (
              <span key={i} style={{ display: "flex", alignItems: "center", gap: 4, background: "var(--surface-2, #f4f4f5)", borderRadius: 4, padding: "2px 8px", fontSize: 12 }}>
                {ent}
                <button type="button" onClick={() => removeEntity(i)} style={{ background: "none", border: "none", cursor: "pointer", padding: 0, lineHeight: 1, color: "var(--text-muted, #888)" }}>×</button>
              </span>
            ))}
          </div>
        )}
      </div>
      <div className={s["form-group"]}>
        <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer" }}>
          <input
            type="checkbox"
            checked={det.fail_open ?? true}
            onChange={(e) => onChange({ ...det, fail_open: e.target.checked })}
          />
          <span className={s["form-label"]} style={{ margin: 0 }}>Fail open (allow requests if Presidio is unreachable)</span>
        </label>
      </div>
    </>
  );
}

function LlmGuardEditor({ det, onChange }: { det: LlmGuardDetector; onChange: (d: LlmGuardDetector) => void }) {
  const [catInput, setCatInput] = useState("");

  function addCategory() {
    const trimmed = catInput.trim();
    if (!trimmed) return;
    onChange({ ...det, categories: [...(det.categories ?? []), trimmed] });
    setCatInput("");
  }

  function removeCategory(i: number) {
    const cats = [...(det.categories ?? [])];
    cats.splice(i, 1);
    onChange({ ...det, categories: cats });
  }

  return (
    <>
      <div className={s["form-row"]}>
        <div className={s["form-group"]}>
          <label className={s["form-label"]}>Llama Guard URL</label>
          <input
            className={s["form-input"]}
            value={det.url ?? "http://127.0.0.1:8083"}
            onChange={(e) => onChange({ ...det, url: e.target.value })}
          />
        </div>
        <div className={s["form-group"]}>
          <label className={s["form-label"]}>Timeout (ms)</label>
          <input
            className={s["form-input"]}
            type="number"
            min="100"
            step="500"
            value={det.timeout_ms ?? 3000}
            onChange={(e) => onChange({ ...det, timeout_ms: parseInt(e.target.value) || 3000 })}
          />
        </div>
      </div>
      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Safety categories (leave empty = all)</label>
        <div style={{ display: "flex", gap: 6 }}>
          <input
            className={s["form-input"]}
            value={catInput}
            onChange={(e) => setCatInput(e.target.value)}
            placeholder="S1, S2…"
            onKeyDown={(e) => e.key === "Enter" && (e.preventDefault(), addCategory())}
          />
          <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={addCategory}>Add</button>
        </div>
        {(det.categories ?? []).length > 0 && (
          <div style={{ marginTop: 6, display: "flex", flexWrap: "wrap", gap: 4 }}>
            {(det.categories ?? []).map((cat, i) => (
              <span key={i} style={{ display: "flex", alignItems: "center", gap: 4, background: "var(--surface-2, #f4f4f5)", borderRadius: 4, padding: "2px 8px", fontSize: 12 }}>
                {cat}
                <button type="button" onClick={() => removeCategory(i)} style={{ background: "none", border: "none", cursor: "pointer", padding: 0, lineHeight: 1, color: "var(--text-muted, #888)" }}>×</button>
              </span>
            ))}
          </div>
        )}
      </div>
      <div className={s["form-group"]}>
        <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer" }}>
          <input
            type="checkbox"
            checked={det.fail_open ?? true}
            onChange={(e) => onChange({ ...det, fail_open: e.target.checked })}
          />
          <span className={s["form-label"]} style={{ margin: 0 }}>Fail open (allow requests if Llama Guard is unreachable)</span>
        </label>
      </div>
    </>
  );
}

// ---------------------------------------------------------------------------
// Detector card (one entry in the list)
// ---------------------------------------------------------------------------

const TYPE_LABELS: Record<DetectorConfig["type"], string> = {
  regex: "Regex / Pattern",
  keyword: "Keyword",
  presidio: "Presidio (NLP)",
  llm_guard: "Llama Guard",
};

const TYPE_BADGE_COLORS: Record<DetectorConfig["type"], string> = {
  regex: "#3b82f6",
  keyword: "#8b5cf6",
  presidio: "#10b981",
  llm_guard: "#f59e0b",
};

function DetectorCard({
  det,
  index,
  total,
  onMove,
  onUpdate,
  onRemove,
}: {
  det: DetectorConfig;
  index: number;
  total: number;
  onMove: (from: number, to: number) => void;
  onUpdate: (d: DetectorConfig) => void;
  onRemove: () => void;
}) {
  const [expanded, setExpanded] = useState(false);

  function renderEditor() {
    if (det.type === "regex") return <RegexEditor det={det} onChange={onUpdate} />;
    if (det.type === "keyword") return <KeywordEditor det={det} onChange={onUpdate} />;
    if (det.type === "presidio") return <PresidioEditor det={det} onChange={onUpdate} />;
    if (det.type === "llm_guard") return <LlmGuardEditor det={det} onChange={onUpdate} />;
    return null;
  }

  return (
    <div
      data-testid="detector-card"
      style={{
        border: "1px solid var(--border, #e4e4e7)",
        borderRadius: 8,
        marginBottom: 8,
        background: "var(--surface, #fff)",
      }}
    >
      {/* Header row */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 8,
          padding: "10px 12px",
          cursor: "pointer",
          userSelect: "none",
        }}
        onClick={() => setExpanded((x) => !x)}
      >
        {/* Reorder buttons */}
        <div style={{ display: "flex", flexDirection: "column", gap: 1 }} onClick={(e) => e.stopPropagation()}>
          <button
            type="button"
            aria-label="Move up"
            disabled={index === 0}
            onClick={() => onMove(index, index - 1)}
            style={{ background: "none", border: "none", cursor: index === 0 ? "default" : "pointer", padding: "1px 4px", opacity: index === 0 ? 0.3 : 1, fontSize: 10 }}
          >▲</button>
          <button
            type="button"
            aria-label="Move down"
            disabled={index === total - 1}
            onClick={() => onMove(index, index + 1)}
            style={{ background: "none", border: "none", cursor: index === total - 1 ? "default" : "pointer", padding: "1px 4px", opacity: index === total - 1 ? 0.3 : 1, fontSize: 10 }}
          >▼</button>
        </div>

        {/* Type badge */}
        <span
          style={{
            background: TYPE_BADGE_COLORS[det.type],
            color: "#fff",
            borderRadius: 4,
            padding: "2px 7px",
            fontSize: 11,
            fontWeight: 600,
            whiteSpace: "nowrap",
          }}
        >
          {TYPE_LABELS[det.type]}
        </span>

        {/* Name + summary */}
        <span style={{ fontWeight: 500, flex: 1, fontSize: 13, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
          {det.name}
        </span>
        <span style={{ fontSize: 11, color: "var(--text-muted, #888)", whiteSpace: "nowrap" }}>
          {det.action} · {det.target ?? "request"}
        </span>

        {/* Expand toggle */}
        <span style={{ fontSize: 12, color: "var(--text-muted, #888)" }}>{expanded ? "▲" : "▼"}</span>

        {/* Remove */}
        <button
          type="button"
          aria-label="Remove detector"
          onClick={(e) => { e.stopPropagation(); onRemove(); }}
          style={{ background: "none", border: "none", cursor: "pointer", color: "var(--danger, #ef4444)", fontWeight: 700, fontSize: 16, lineHeight: 1, padding: "0 4px" }}
        >×</button>
      </div>

      {/* Expanded editor */}
      {expanded && (
        <div style={{ padding: "0 12px 12px", borderTop: "1px solid var(--border, #e4e4e7)" }}>
          <div style={{ paddingTop: 12 }}>
            <CommonFields det={det} onChange={onUpdate} />
            {renderEditor()}
          </div>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main DetectorBuilder component
// ---------------------------------------------------------------------------

interface DetectorBuilderProps {
  value: DetectorConfig[];
  onChange: (detectors: DetectorConfig[]) => void;
}

export function DetectorBuilder({ value, onChange }: DetectorBuilderProps) {
  function addDetector(type: DetectorConfig["type"]) {
    let d: DetectorConfig;
    if (type === "regex") d = emptyRegex();
    else if (type === "keyword") d = emptyKeyword();
    else if (type === "presidio") d = emptyPresidio();
    else d = emptyLlmGuard();
    onChange([...value, d]);
  }

  function updateDetector(i: number, d: DetectorConfig) {
    const next = [...value];
    next[i] = d;
    onChange(next);
  }

  function removeDetector(i: number) {
    const next = [...value];
    next.splice(i, 1);
    onChange(next);
  }

  function moveDetector(from: number, to: number) {
    if (to < 0 || to >= value.length) return;
    const next = [...value];
    const [item] = next.splice(from, 1);
    next.splice(to, 0, item);
    onChange(next);
  }

  return (
    <div>
      <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 10 }}>
        <span className={s["form-label"]} style={{ margin: 0 }}>Detectors ({value.length})</span>
        <div style={{ display: "flex", gap: 6 }}>
          {(["regex", "keyword", "presidio", "llm_guard"] as const).map((type) => (
            <button
              key={type}
              type="button"
              className={`${s.btn} ${s["btn--secondary"]}`}
              style={{ fontSize: 12, padding: "4px 10px" }}
              onClick={() => addDetector(type)}
            >
              + {TYPE_LABELS[type]}
            </button>
          ))}
        </div>
      </div>

      {value.length === 0 && (
        <p style={{ fontSize: 13, color: "var(--text-muted, #888)", margin: "12px 0" }}>
          No detectors configured. Add one above to start scanning requests or responses.
        </p>
      )}

      {value.map((det, i) => (
        <DetectorCard
          key={i}
          det={det}
          index={i}
          total={value.length}
          onMove={moveDetector}
          onUpdate={(d) => updateDetector(i, d)}
          onRemove={() => removeDetector(i)}
        />
      ))}
    </div>
  );
}
