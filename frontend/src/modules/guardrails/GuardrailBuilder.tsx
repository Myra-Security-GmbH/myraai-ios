// modules/guardrails/GuardrailBuilder.tsx
// Ordered list of guardrail configs for a gateway.
// Used inside the Gateways EditGatewayModal.

import { useState } from "react";
import {
  DetectorConfig,
  RegexDetector,
  KeywordDetector,
  JailbreakDetector,
  PresidioDetector,
  PromptGuardDetector,
  PiiProtectorDetector,
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
  pci_pan:          "PCI — credit card, CVV, expiry, IBAN, routing  ·  FP rate: <2% (Luhn-validated, format-specific)  ·  safe for action:block",
  hipaa_structured: "HIPAA — SSN, MRN, NPI, DOB, phone, email, IP  ·  FP rate: up to 26% (phone/SSN/IP appear in general text)  ·  use action:scrub",
  gdpr_structured:  "GDPR — email, phone, IP, IBAN, national ID, passport  ·  FP rate: up to 26% (phone/IP)  ·  use action:scrub",
  credentials:      "Credentials — API keys, JWTs  ·  FP rate: 0% (strict format)  ·  safe for action:block",
  pii_basic:        "PII basic — email, phone, SSN  ·  FP rate: up to 26% (phone)  ·  use action:scrub",
};

// Llama Guard 3 safety categories (S1–S14).
// fp_risk: "low" = <1% FP on OR-Bench, "medium" = 1–4%, "high" = >4%.
// Recommended block set = all low-FP categories → ~1% FP on real corpora.
// Adding S2 (Non-Violent Crimes) alone raises FP to ~6.5% due to security/education content.
const LLAMA_GUARD_CATEGORIES: Array<{
  code: string;
  label: string;
  description: string;
  fp_risk: "low" | "medium" | "high";
  in_recommended: boolean;
}> = [
  { code: "S1",  label: "Violent Crimes",          description: "Murder, terrorism, assault",                      fp_risk: "low",    in_recommended: true  },
  { code: "S2",  label: "Non-Violent Crimes",       description: "Fraud, hacking, drug synthesis — 14.5% FP without context / 7.2% with context on security/education text", fp_risk: "high",   in_recommended: false },
  { code: "S3",  label: "Sex-Related Crimes",       description: "Sexual assault, trafficking",                    fp_risk: "low",    in_recommended: true  },
  { code: "S4",  label: "Child Sexual Exploitation",description: "CSAM",                                           fp_risk: "low",    in_recommended: true  },
  { code: "S5",  label: "Defamation",               description: "False statements of fact",                       fp_risk: "medium", in_recommended: false },
  { code: "S6",  label: "Specialized Advice",       description: "Medical/legal/financial — high FP on pro contexts", fp_risk: "high", in_recommended: false },
  { code: "S7",  label: "Privacy",                  description: "Doxing, surveillance",                           fp_risk: "medium", in_recommended: false },
  { code: "S8",  label: "Intellectual Property",    description: "Verbatim reproduction, plagiarism",              fp_risk: "medium", in_recommended: false },
  { code: "S9",  label: "CBRN Weapons",             description: "Bio/chem/nuclear/radiological weapons",          fp_risk: "low",    in_recommended: true  },
  { code: "S10", label: "Hate",                     description: "Slurs, discrimination — triggers on academic/historical text", fp_risk: "medium", in_recommended: false },
  { code: "S11", label: "Suicide / Self-Harm",      description: "Self-harm instructions",                         fp_risk: "low",    in_recommended: true  },
  { code: "S12", label: "Sexual Content",           description: "Explicit adult content",                         fp_risk: "low",    in_recommended: true  },
  { code: "S13", label: "Elections",                description: "Voter suppression, electoral misinformation",    fp_risk: "medium", in_recommended: false },
  { code: "S14", label: "Code Interpreter Abuse",  description: "Exploiting code execution environments (agentic/tool-use scenarios)", fp_risk: "low", in_recommended: true  },
];

const RECOMMENDED_BLOCK_CATEGORIES = LLAMA_GUARD_CATEGORIES.filter((c) => c.fp_risk === "low").map((c) => c.code);

// Entity catalog for Presidio / PII Protector.
// fp_risk mirrors the FP benchmarks in tests/false_positives/.
// High-FP entities have their score threshold auto-raised to 0.9 by the gateway.
const PRESIDIO_ENTITY_CATALOG: Array<{
  entity: string;
  label: string;
  fp_risk: "low" | "medium" | "high";
  description: string;
}> = [
  // ── Low FP — 0% FP benchmarked (OR-Bench-hard, XSTest-safe, Dolly-15k, handcrafted) ──
  { entity: "EMAIL_ADDRESS",     label: "Email Address",                      fp_risk: "low",    description: "Email addresses" },
  { entity: "PHONE_NUMBER",      label: "Phone Number",                       fp_risk: "low",    description: "Phone numbers in various formats" },
  { entity: "US_SSN",            label: "SSN",                                fp_risk: "low",    description: "US Social Security Numbers" },
  { entity: "CREDIT_CARD",       label: "Credit Card",                        fp_risk: "low",    description: "Credit/debit card numbers (Luhn-validated)" },
  { entity: "US_BANK_NUMBER",    label: "US Bank Account",                    fp_risk: "low",    description: "US bank account numbers" },
  { entity: "IBAN_CODE",         label: "IBAN",                               fp_risk: "low",    description: "International Bank Account Numbers" },
  { entity: "US_PASSPORT",       label: "US Passport",                        fp_risk: "low",    description: "US passport numbers (regex, US format only)" },
  { entity: "PASSPORT",          label: "Passport (multilingual)",            fp_risk: "low",    description: "Passport numbers in any format — detected via NER (GLiNER)" },
  { entity: "US_DRIVER_LICENSE", label: "US Driver License",                  fp_risk: "low",    description: "US driver license numbers" },
  { entity: "US_ITIN",           label: "ITIN",                               fp_risk: "low",    description: "Individual Taxpayer Identification Numbers" },
  { entity: "CRYPTO",            label: "Crypto Address",                     fp_risk: "low",    description: "Cryptocurrency wallet addresses" },
  // ── Low FP (continued) — 0% FP benchmarked ──────────────────────────────
  { entity: "IP_ADDRESS",        label: "IP Address",                         fp_risk: "low",    description: "IPv4 and IPv6 addresses (0% FP benchmarked)" },
  { entity: "MEDICAL_LICENSE",   label: "Medical License",                    fp_risk: "low",    description: "US medical license numbers (0% FP benchmarked)" },
  { entity: "URL",               label: "URL",                                fp_risk: "low",    description: "Web URLs (0% FP benchmarked)" },
  // ── Medium FP — gateway auto-raises score threshold to 0.85 ──────────────
  { entity: "ORG",               label: "Organisation",                       fp_risk: "medium", description: "Company and organisation names — detected via NER (GLiNER); threshold auto-raised to 0.85" },
  // ── High FP — gateway auto-raises score threshold to 0.9 ─────────────────
  { entity: "PERSON",            label: "Person Name",                        fp_risk: "high",   description: "Personal names — ~20% FP on XSTest/Dolly; threshold auto-raised to 0.9" },
  { entity: "LOCATION",          label: "Location",                           fp_risk: "high",   description: "Cities, countries — ~18% FP on Dolly/XSTest; threshold auto-raised to 0.9" },
  { entity: "DATE_TIME",         label: "Date / Time",                        fp_risk: "high",   description: "Dates and times — ~7–14% FP on general text; threshold auto-raised to 0.9" },
];

// "pii_focused" = all 14 low-FP entities; achieves 0% FP on OR-Bench-hard, XSTest-safe, and Dolly-15k.
const PII_FOCUSED_ENTITIES = PRESIDIO_ENTITY_CATALOG
  .filter((e) => e.fp_risk === "low")
  .map((e) => e.entity);

// Built-in jailbreak phrases — mirrors BUILT_IN_KEYWORDS in src/guardrails/jailbreak.lua.
// Used to pre-populate emptyJailbreak() so the UI shows what the gateway will match.
const JAILBREAK_KEYWORDS = [
  "ignore previous instructions",
  "ignore all instructions",
  "ignore your instructions",
  "disregard previous instructions",
  "disregard your instructions",
  "forget your instructions",
  "DAN mode",
  "do anything now",
  "jailbreak",
  "developer mode",
  "unrestricted mode",
  "your true self",
  "bypass your guidelines",
  "bypass your restrictions",
  "override your guidelines",
  "override your restrictions",
  "prompt injection",
  "[SYSTEM]",
];

const DETECTOR_ACTIONS: DetectorAction[] = ["block", "scrub", "flag"];
const DETECTOR_TARGETS: DetectorTarget[] = ["request", "response", "both"];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function emptyRegex(): RegexDetector {
  return { type: "regex", name: "pii-check", action: "block", target: "request", patterns: [], custom_patterns: [] };
}

function emptyKeyword(): KeywordDetector {
  return { type: "keyword", name: "keyword-check", action: "flag", target: "request", keywords: [], case_sensitive: false, whole_word: true };
}

function emptyJailbreak(): JailbreakDetector {
  // Pre-populate keywords so the editor shows what will be matched.
  // When saved with the full list it behaves identically to zero-config
  // (the Lua module uses the same built-in list as its fallback).
  return { type: "jailbreak", name: "jailbreak-check", action: "flag", target: "request", keywords: [...JAILBREAK_KEYWORDS], case_sensitive: false, whole_word: false };
}

function emptyPresidio(): PresidioDetector {
  return { type: "presidio", name: "presidio-pii", action: "block", target: "request", url: "http://127.0.0.1:5002", entities: [...PII_FOCUSED_ENTITIES], score_threshold: 0.7, fail_open: true };
}

function emptyPromptGuard(): PromptGuardDetector {
  const lowFpCategories = LLAMA_GUARD_CATEGORIES.filter((c) => c.fp_risk === "low").map((c) => c.code);
  return { type: "prompt_guard", name: "prompt-guard", action: "block", target: "request", url: "http://127.0.0.1:8083", timeout_ms: 3000, categories: lowFpCategories, fail_open: true };
}

function emptyPiiProtector(): PiiProtectorDetector {
  return { type: "pii_protector", name: "pii-protect", target: "both", analyzer_url: "http://127.0.0.1:5002", entities: [...PII_FOCUSED_ENTITIES], score_threshold: 0.7, fail_open: true };
}

// Type guard: guardrails that carry an action field
type ActionableDetector = RegexDetector | KeywordDetector | PresidioDetector | PromptGuardDetector;
function hasAction(det: DetectorConfig): det is ActionableDetector {
  return det.type !== "pii_protector";
}

// ---------------------------------------------------------------------------
// Sub-editors for each detector type
// ---------------------------------------------------------------------------

function CommonFields({ det, onChange }: { det: DetectorConfig; onChange: (d: DetectorConfig) => void }) {
  const isPiiProtector = det.type === "pii_protector";
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
      {hasAction(det) && (
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
      )}
      <div className={s["form-group"]} style={{ flex: "1 1 120px" }}>
        <label className={s["form-label"]}>Target</label>
        {isPiiProtector ? (
          <div style={{ fontSize: 12, color: "var(--text-muted, #888)", padding: "6px 0", lineHeight: "22px" }}>
            request + response
            <span style={{ marginLeft: 4, fontSize: 10, opacity: 0.6 }}>(required)</span>
          </div>
        ) : (
          <select
            className={s["form-select"]}
            value={det.target ?? "request"}
            onChange={(e) => onChange({ ...det, target: e.target.value as DetectorTarget })}
          >
            {DETECTOR_TARGETS.map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
        )}
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
        <p className={s["form-hint"]}>
          Tip: anchor to word boundaries to reduce false positives —
          use <code style={{ fontSize: 11 }}>%f[%w]pattern%f[%W]</code> or wrap
          with <code style={{ fontSize: 11 }}>%b</code> guards. Example:
          &nbsp;<code style={{ fontSize: 11 }}>%f[%w]PROJ%-%d+%f[%W]</code> matches "PROJ-123" but not "MPROJ-123".
        </p>
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

  const isBlockAction = (det as KeywordDetector).action === "block";

  return (
    <>
      {isBlockAction && (
        <div style={{ background: "var(--warning-bg, #fef9c3)", border: "1px solid var(--warning-border, #fde047)", borderRadius: 6, padding: "8px 12px", marginBottom: 10, fontSize: 12, lineHeight: 1.5 }}>
          <strong>Block action:</strong> every keyword match hard-blocks the request. Use exact,
          unambiguous terms only (e.g. internal code names, product IDs). Broad words like
          "kill" or "attack" cause high false-positive rates — use <strong>flag</strong> for those.
        </div>
      )}
      <div className={s["form-group"]}>
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 4 }}>
          <label className={s["form-label"]} style={{ margin: 0 }}>Keywords</label>
          <div style={{ display: "flex", gap: 4 }}>
            <span style={{ fontSize: 11, color: "var(--text-muted, #888)", alignSelf: "center", marginRight: 4 }}>Presets:</span>
            <button
              type="button"
              className={`${s.btn} ${s["btn--secondary"]}`}
              style={{ fontSize: 11, padding: "2px 8px" }}
              title="Unambiguous internal labels safe for block action — near-zero FP rate"
              onClick={() => onChange({ ...det, action: "block", whole_word: true, keywords: ["CONFIDENTIAL", "TOP SECRET", "INTERNAL USE ONLY", "DO NOT DISTRIBUTE"] })}
            >
              Block-safe example
            </button>
            <button
              type="button"
              className={`${s.btn} ${s["btn--secondary"]}`}
              style={{ fontSize: 11, padding: "2px 8px" }}
              title="Broad sensitive terms — use flag action; too many FPs for block"
              onClick={() => onChange({ ...det, action: "flag", whole_word: true, keywords: ["password", "secret", "private key", "credentials"] })}
            >
              Flag-only example
            </button>
          </div>
        </div>
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
      <div style={{ display: "flex", gap: 16, flexWrap: "wrap" }}>
        <div className={s["form-group"]} style={{ margin: 0 }}>
          <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer" }}>
            <input
              type="checkbox"
              checked={det.whole_word ?? true}
              onChange={(e) => onChange({ ...det, whole_word: e.target.checked })}
            />
            <span className={s["form-label"]} style={{ margin: 0 }}>Whole-word matching</span>
          </label>
          <p className={s["form-hint"]} style={{ marginLeft: 24 }}>
            Recommended: prevents "kill" matching "skill". Disable only for substrings like product codes.
          </p>
        </div>
        <div className={s["form-group"]} style={{ margin: 0 }}>
          <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer" }}>
            <input
              type="checkbox"
              checked={det.case_sensitive ?? false}
              onChange={(e) => onChange({ ...det, case_sensitive: e.target.checked })}
            />
            <span className={s["form-label"]} style={{ margin: 0 }}>Case sensitive</span>
          </label>
        </div>
      </div>
    </>
  );
}

function JailbreakEditor({ det, onChange }: { det: JailbreakDetector; onChange: (d: JailbreakDetector) => void }) {
  const [kwInput, setKwInput] = useState("");
  const keywords = det.keywords ?? [];
  const usingBuiltIns = keywords.length === 0;

  function addKeyword() {
    const trimmed = kwInput.trim();
    if (!trimmed) return;
    onChange({ ...det, keywords: [...keywords, trimmed] });
    setKwInput("");
  }

  function removeKeyword(i: number) {
    const kws = [...keywords];
    kws.splice(i, 1);
    onChange({ ...det, keywords: kws });
  }

  const activeList = usingBuiltIns ? JAILBREAK_KEYWORDS : keywords;

  return (
    <>
      <div style={{ background: "var(--section-bg, #f9fafb)", border: "1px solid var(--card-border, #e4e4e7)", borderRadius: 6, padding: "8px 12px", marginBottom: 10, fontSize: 12, lineHeight: 1.6 }}>
        {usingBuiltIns
          ? <><strong>Using built-in phrases</strong> ({JAILBREAK_KEYWORDS.length} phrases). Add keywords below to override with a fully custom list.</>
          : <><strong>Custom list active</strong> ({keywords.length} phrase{keywords.length !== 1 ? "s" : ""}). Remove all keywords to revert to built-in defaults.</>
        }
      </div>
      <div className={s["form-group"]}>
        <label className={s["form-label"]}>
          {usingBuiltIns ? "Built-in phrases (read-only — add below to override)" : "Active phrases"}
        </label>
        <div style={{ display: "flex", flexWrap: "wrap", gap: 4, marginBottom: 8 }}>
          {activeList.map((kw, i) => (
            <span key={i} style={{ display: "flex", alignItems: "center", gap: 4, background: "var(--surface-2, #f4f4f5)", borderRadius: 4, padding: "2px 8px", fontSize: 12 }}>
              {kw}
              {!usingBuiltIns && (
                <button type="button" onClick={() => removeKeyword(i)} style={{ background: "none", border: "none", cursor: "pointer", padding: 0, lineHeight: 1, color: "var(--text-muted, #888)" }}>×</button>
              )}
            </span>
          ))}
        </div>
        <div style={{ display: "flex", gap: 6 }}>
          <input
            className={s["form-input"]}
            value={kwInput}
            onChange={(e) => setKwInput(e.target.value)}
            placeholder="add a phrase…"
            onKeyDown={(e) => e.key === "Enter" && (e.preventDefault(), addKeyword())}
          />
          <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={addKeyword}>Add</button>
        </div>
      </div>
      <div style={{ display: "flex", gap: 16, flexWrap: "wrap" }}>
        <div className={s["form-group"]} style={{ margin: 0 }}>
          <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer" }}>
            <input
              type="checkbox"
              checked={det.whole_word ?? false}
              onChange={(e) => onChange({ ...det, whole_word: e.target.checked })}
            />
            <span className={s["form-label"]} style={{ margin: 0 }}>Whole-word matching</span>
          </label>
          <p className={s["form-hint"]} style={{ marginLeft: 24 }}>
            Off by default: catches inflected forms like "bypassing your restrictions". Enable only when you need exact boundaries.
          </p>
        </div>
        <div className={s["form-group"]} style={{ margin: 0 }}>
          <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer" }}>
            <input
              type="checkbox"
              checked={det.case_sensitive ?? false}
              onChange={(e) => onChange({ ...det, case_sensitive: e.target.checked })}
            />
            <span className={s["form-label"]} style={{ margin: 0 }}>Case sensitive</span>
          </label>
        </div>
      </div>
    </>
  );
}

function EntityEditor({
  entities,
  onChange,
}: {
  entities: string[];
  onChange: (e: string[]) => void;
}) {
  const [customInput, setCustomInput] = useState("");

  const catalogEntities = new Set(PRESIDIO_ENTITY_CATALOG.map((e) => e.entity));
  const selectedSet = new Set(entities);
  const customEntities = entities.filter((e) => !catalogEntities.has(e));

  const isFocused = PII_FOCUSED_ENTITIES.every((e) => selectedSet.has(e))
    && entities.every((e) => PII_FOCUSED_ENTITIES.includes(e));
  const isAll = entities.length === 0;

  function toggleEntity(entity: string) {
    const next = new Set(selectedSet);
    if (next.has(entity)) next.delete(entity); else next.add(entity);
    onChange([...next]);
  }

  function addCustom() {
    const trimmed = customInput.trim().toUpperCase();
    if (!trimmed || selectedSet.has(trimmed)) return;
    onChange([...entities, trimmed]);
    setCustomInput("");
  }

  function removeCustom(entity: string) {
    onChange(entities.filter((e) => e !== entity));
  }

  return (
    <div className={s["form-group"]}>
      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 6 }}>
        <label className={s["form-label"]} style={{ margin: 0 }}>Entity types</label>
        <div style={{ display: "flex", gap: 4 }}>
          <button
            type="button"
            className={`${s.btn} ${isFocused ? s["btn--primary"] : s["btn--secondary"]}`}
            style={{ fontSize: 11, padding: "2px 8px" }}
            title="Email, phone, SSN, credit card, IBAN, passport (US+multilingual), driver license, ITIN, crypto, IP, medical license, URL — 0% FP on all corpora"
            onClick={() => onChange([...PII_FOCUSED_ENTITIES])}
          >
            Focused PII (0% FP)
          </button>
          <button
            type="button"
            className={`${s.btn} ${isAll ? s["btn--primary"] : s["btn--secondary"]}`}
            style={{ fontSize: 11, padding: "2px 8px" }}
            title="Scan all Presidio entities — PERSON, LOCATION, DATE_TIME auto-raised to 0.9 but still ~10–15% FP"
            onClick={() => onChange([])}
          >
            All entities (~10% FP)
          </button>
        </div>
      </div>

      <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(220px, 1fr))", gap: 4 }}>
        {PRESIDIO_ENTITY_CATALOG.map(({ entity, label, fp_risk, description }) => {
          const badge = FP_RISK_BADGE[fp_risk];
          return (
            <label
              key={entity}
              style={{
                display: "flex",
                alignItems: "flex-start",
                gap: 8,
                cursor: "pointer",
                padding: "5px 8px",
                borderRadius: 6,
                border: "1px solid var(--border, #e4e4e7)",
                background: selectedSet.has(entity) ? "var(--surface-2, #f4f4f5)" : "transparent",
                fontSize: 12,
                lineHeight: 1.4,
                opacity: isAll ? 0.45 : 1,
              }}
              title={description}
            >
              <input
                type="checkbox"
                style={{ marginTop: 2, flexShrink: 0 }}
                checked={selectedSet.has(entity)}
                disabled={isAll}
                onChange={() => toggleEntity(entity)}
              />
              <span style={{ flex: 1 }}>{label}</span>
              <span style={{ fontSize: 10, background: badge.bg, color: badge.color, borderRadius: 3, padding: "1px 5px", whiteSpace: "nowrap", flexShrink: 0, fontWeight: 600 }}>
                {badge.label}
              </span>
            </label>
          );
        })}
      </div>

      {isAll && (
        <p className={s["form-hint"]} style={{ color: "var(--warning-text, #92400e)", marginTop: 6 }}>
          All entities mode — PERSON, LOCATION, and DATE_TIME are high-FP (gateway auto-raises
          their threshold to 0.9, but expect ~10–15% false positives on normal text).
          Use <strong>Focused PII</strong> to eliminate false positives entirely.
        </p>
      )}

      {customEntities.length > 0 && (
        <div style={{ marginTop: 8, display: "flex", flexWrap: "wrap", gap: 4 }}>
          {customEntities.map((ent) => (
            <span key={ent} style={{ display: "flex", alignItems: "center", gap: 4, background: "var(--surface-2, #f4f4f5)", borderRadius: 4, padding: "2px 8px", fontSize: 12 }}>
              {ent}
              <button type="button" onClick={() => removeCustom(ent)} style={{ background: "none", border: "none", cursor: "pointer", padding: 0, lineHeight: 1, color: "var(--text-muted, #888)" }}>×</button>
            </span>
          ))}
        </div>
      )}

      <div style={{ display: "flex", gap: 6, marginTop: 8 }}>
        <input
          className={s["form-input"]}
          value={customInput}
          onChange={(e) => setCustomInput(e.target.value)}
          placeholder="Custom entity (e.g. IN_PAN, UK_NHS…)"
          onKeyDown={(e) => e.key === "Enter" && (e.preventDefault(), addCustom())}
          style={{ fontSize: 12 }}
        />
        <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={addCustom} style={{ fontSize: 12 }}>Add</button>
      </div>
    </div>
  );
}

function PresidioEditor({ det, onChange }: { det: PresidioDetector; onChange: (d: PresidioDetector) => void }) {
  const allowListRaw = (det.allow_list ?? []).join(", ");
  function onAllowListChange(raw: string) {
    const items = raw.split(",").map(s => s.trim()).filter(Boolean);
    onChange({ ...det, allow_list: items.length ? items : undefined });
  }
  return (
    <>
      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Presidio URL</label>
        <input
          className={s["form-input"]}
          value={det.url ?? "http://127.0.0.1:5002"}
          onChange={(e) => onChange({ ...det, url: e.target.value })}
        />
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
        <p className={s["form-hint"]}>
          Global minimum confidence (0–1). High-FP entities (PERSON, LOCATION, DATE_TIME)
          automatically use 0.9 and ORG uses 0.85 — raising the global threshold above these
          values will also filter them. Values below 0.85 have little effect on high-FP entities.
        </p>
      </div>
      <EntityEditor
        entities={det.entities ?? []}
        onChange={(e) => onChange({ ...det, entities: e })}
      />
      <div className={s["form-row"]}>
        <div className={s["form-group"]} style={{ flex: "3 1 200px" }}>
          <label className={s["form-label"]}>Allow list</label>
          <input
            className={s["form-input"]}
            placeholder="e.g. Myra Security, John Doe"
            value={allowListRaw}
            onChange={(e) => onAllowListChange(e.target.value)}
          />
          <p className={s["form-hint"]}>Comma-separated values that will never be flagged as PII.</p>
        </div>
        <div className={s["form-group"]} style={{ flex: "1 1 100px" }}>
          <label className={s["form-label"]}>Match mode</label>
          <select
            className={s["form-select"]}
            value={det.allow_list_match ?? "exact"}
            onChange={(e) => onChange({ ...det, allow_list_match: e.target.value as "exact" | "partial" })}
          >
            <option value="exact">exact</option>
            <option value="partial">partial</option>
          </select>
        </div>
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

const FP_RISK_BADGE: Record<"low" | "medium" | "high", { label: string; bg: string; color: string }> = {
  low:    { label: "low FP",    bg: "#dcfce7", color: "#166534" },
  medium: { label: "medium FP", bg: "#fef9c3", color: "#854d0e" },
  high:   { label: "high FP",   bg: "#fee2e2", color: "#991b1b" },
};

function PromptGuardEditor({ det, onChange }: { det: PromptGuardDetector; onChange: (d: PromptGuardDetector) => void }) {
  const selected = new Set(det.categories ?? []);
  const isAll = selected.size === 0;
  const isRecommended = RECOMMENDED_BLOCK_CATEGORIES.every((c) => selected.has(c))
    && selected.size === RECOMMENDED_BLOCK_CATEGORIES.length;

  function toggleCategory(code: string) {
    const next = new Set(selected);
    if (next.has(code)) next.delete(code); else next.add(code);
    onChange({ ...det, categories: next.size === 0 ? [] : [...next].sort() });
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
        <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginBottom: 6 }}>
          <label className={s["form-label"]} style={{ margin: 0 }}>Safety categories</label>
          <div style={{ display: "flex", gap: 4 }}>
            <button
              type="button"
              className={`${s.btn} ${isRecommended ? s["btn--primary"] : s["btn--secondary"]}`}
              style={{ fontSize: 11, padding: "2px 8px" }}
              title="All low-FP categories: S1, S3, S4, S9, S11, S12, S14 — ~1.7% FP without context / ~1.1% FP with context_prompt on OR-Bench-hard. Avoids S2 and S6 which cause high FP on security/education content."
              onClick={() => onChange({ ...det, categories: [...RECOMMENDED_BLOCK_CATEGORIES] })}
            >
              Recommended block (~1.7% FP)
            </button>
            <button
              type="button"
              className={`${s.btn} ${isAll ? s["btn--primary"] : s["btn--secondary"]}`}
              style={{ fontSize: 11, padding: "2px 8px" }}
              title="All 14 categories — ~18.6% FP rate on OR-Bench-hard. S2 (14.5% alone) and S6 are the main drivers."
              onClick={() => onChange({ ...det, categories: [] })}
            >
              All categories (~18.6% FP)
            </button>
          </div>
        </div>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill, minmax(260px, 1fr))", gap: 4 }}>
          {[...LLAMA_GUARD_CATEGORIES]
            .sort((a, b) => ({ low: 0, medium: 1, high: 2 }[a.fp_risk] - { low: 0, medium: 1, high: 2 }[b.fp_risk]))
            .map(({ code, label, description, fp_risk, in_recommended }) => {
            const badge = FP_RISK_BADGE[fp_risk];
            return (
              <label
                key={code}
                style={{
                  display: "flex",
                  alignItems: "flex-start",
                  gap: 8,
                  cursor: "pointer",
                  padding: "5px 8px",
                  borderRadius: 6,
                  border: "1px solid var(--border, #e4e4e7)",
                  background: selected.has(code) ? "var(--surface-2, #f4f4f5)" : "transparent",
                  fontSize: 12,
                  lineHeight: 1.4,
                }}
                title={`${code} — ${description}`}
              >
                <input
                  type="checkbox"
                  style={{ marginTop: 2, flexShrink: 0 }}
                  checked={selected.has(code)}
                  onChange={() => toggleCategory(code)}
                />
                <span style={{ flex: 1 }}>
                  {label}
                  {in_recommended && (
                    <span style={{ marginLeft: 5, fontSize: 10, background: "#dcfce7", color: "#166534", borderRadius: 3, padding: "1px 4px", fontWeight: 600 }}>rec</span>
                  )}
                </span>
                <span style={{ fontSize: 10, background: badge.bg, color: badge.color, borderRadius: 3, padding: "1px 5px", whiteSpace: "nowrap", flexShrink: 0, fontWeight: 600 }}>
                  {badge.label}
                </span>
              </label>
            );
          })}
        </div>
        {isAll && (
          <p className={s["form-hint"]} style={{ color: "var(--warning-text, #92400e)" }}>
            All categories selected — expect ~18.6% false positives on security/education content.
            S2 (Non-Violent Crimes, 14.5% FP) and S6 (Specialized Advice) are the main drivers.
            Use <strong>Recommended block</strong> to reduce to ~1.7% FP.
          </p>
        )}
      </div>
      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Context prompt (optional)</label>
        <textarea
          className={s["form-input"]}
          rows={3}
          style={{ resize: "vertical", fontFamily: "inherit", fontSize: 12 }}
          placeholder="Describe your deployment context to reduce false positives. E.g.: 'This platform serves security professionals and researchers. Classify as unsafe only requests clearly seeking operational assistance for causing direct harm.'"
          value={det.context_prompt ?? ""}
          onChange={(e) => onChange({ ...det, context_prompt: e.target.value || undefined })}
        />
        <p className={s["form-hint"]}>
          Injected before each user message to give Llama Guard deployment context.
          Reduces FP on security/education platforms: S2 drops from 14.5% → 7.2% FP;
          recommended_block drops from ~1.7% → ~1.1% FP (benchmarked on OR-Bench-hard).
        </p>
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

function PiiProtectorEditor({ det, onChange }: { det: PiiProtectorDetector; onChange: (d: PiiProtectorDetector) => void }) {
  const allowListRaw = (det.allow_list ?? []).join(", ");
  function onAllowListChange(raw: string) {
    const items = raw.split(",").map(s => s.trim()).filter(Boolean);
    onChange({ ...det, allow_list: items.length ? items : undefined });
  }
  return (
    <>
      <div style={{ fontSize: 12, color: "var(--text-muted, #888)", padding: "6px 0 10px", lineHeight: 1.5 }}>
        Detects PII on the request and replaces it with opaque tokens
        (e.g.&nbsp;<code style={{ fontSize: 11 }}>[PII:a3f9b2:1]</code>).
        Tokens are swapped back to the original values in the response before the client sees it —
        so the LLM never processes real PII while the user still receives meaningful output.
      </div>
      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Analyzer URL</label>
        <input
          className={s["form-input"]}
          value={det.analyzer_url ?? "http://127.0.0.1:5002"}
          onChange={(e) => onChange({ ...det, analyzer_url: e.target.value })}
        />
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
        <p className={s["form-hint"]}>
          Global minimum confidence (0–1). High-FP entities (PERSON, LOCATION, DATE_TIME)
          automatically use 0.9 and ORG uses 0.85 — raising the global threshold above these
          values will also filter them. Values below 0.85 have little effect on high-FP entities.
        </p>
      </div>
      <EntityEditor
        entities={det.entities ?? []}
        onChange={(e) => onChange({ ...det, entities: e })}
      />
      <div className={s["form-row"]}>
        <div className={s["form-group"]} style={{ flex: "3 1 200px" }}>
          <label className={s["form-label"]}>Allow list</label>
          <input
            className={s["form-input"]}
            placeholder="e.g. Myra Security, John Doe"
            value={allowListRaw}
            onChange={(e) => onAllowListChange(e.target.value)}
          />
          <p className={s["form-hint"]}>Comma-separated values that will never be tokenized as PII.</p>
        </div>
        <div className={s["form-group"]} style={{ flex: "1 1 100px" }}>
          <label className={s["form-label"]}>Match mode</label>
          <select
            className={s["form-select"]}
            value={det.allow_list_match ?? "exact"}
            onChange={(e) => onChange({ ...det, allow_list_match: e.target.value as "exact" | "partial" })}
          >
            <option value="exact">exact</option>
            <option value="partial">partial</option>
          </select>
        </div>
      </div>
      <div className={s["form-group"]}>
        <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer" }}>
          <input
            type="checkbox"
            checked={det.skip_system_messages !== false}
            onChange={(e) => onChange({ ...det, skip_system_messages: e.target.checked || undefined })}
          />
          <span className={s["form-label"]} style={{ margin: 0 }}>Skip system &amp; assistant messages (scan user turns only)</span>
        </label>
      </div>
      <div className={s["form-group"]}>
        <label style={{ display: "flex", alignItems: "center", gap: 8, cursor: "pointer" }}>
          <input
            type="checkbox"
            checked={det.fail_open ?? true}
            onChange={(e) => onChange({ ...det, fail_open: e.target.checked })}
          />
          <span className={s["form-label"]} style={{ margin: 0 }}>Fail open (pass requests through if Presidio is unreachable)</span>
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
  jailbreak: "Jailbreak",
  presidio: "Presidio (NLP)",
  prompt_guard: "Prompt Guard",
  pii_protector: "PII Protector",
};

const TYPE_BADGE_COLORS: Record<DetectorConfig["type"], string> = {
  regex: "#3b82f6",
  keyword: "#8b5cf6",
  jailbreak: "#ef4444",
  presidio: "#10b981",
  prompt_guard: "#f59e0b",
  pii_protector: "#06b6d4",
};

// Tier assignment mirrors src/guardrails/orchestrator.lua
const DETECTOR_TIER: Record<DetectorConfig["type"], number> = {
  regex: 1,
  keyword: 1,
  jailbreak: 1,
  presidio: 2,
  prompt_guard: 2,
  pii_protector: 2,
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
    if (det.type === "jailbreak") return <JailbreakEditor det={det} onChange={onUpdate} />;
    if (det.type === "presidio") return <PresidioEditor det={det} onChange={onUpdate} />;
    if (det.type === "prompt_guard") return <PromptGuardEditor det={det} onChange={onUpdate} />;
    if (det.type === "pii_protector") return <PiiProtectorEditor det={det} onChange={onUpdate} />;
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
          {det.type === "pii_protector" ? "⟳ protect" : det.action} · {det.target ?? (det.type === "pii_protector" ? "both" : "request")}
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
// Execution plan: read-only phase/tier visualization
// ---------------------------------------------------------------------------

function DetectorPhaseSummary({ detectors }: { detectors: DetectorConfig[] }) {
  if (detectors.length === 0) return null;

  const sorted = detectors
    .map((det, i) => ({ det, i }))
    .sort((a, b) => {
      const ta = DETECTOR_TIER[a.det.type] ?? 99;
      const tb = DETECTOR_TIER[b.det.type] ?? 99;
      return ta !== tb ? ta - tb : a.i - b.i;
    });

  function phaseArrow(det: DetectorConfig) {
    const target = det.target ?? (det.type === "pii_protector" ? "both" : "request");
    if (target === "both") return "⇄";
    if (target === "response") return "←";
    return "→";
  }

  function phaseLabel(det: DetectorConfig) {
    const target = det.target ?? (det.type === "pii_protector" ? "both" : "request");
    return target;
  }

  function modeLabel(det: DetectorConfig) {
    if (det.type === "pii_protector") return "⟳ reversible";
    return det.action;
  }

  return (
    <div style={{ marginTop: 16, borderTop: "1px solid var(--border, #e4e4e7)", paddingTop: 12 }}>
      <div style={{ fontSize: 11, fontWeight: 600, color: "var(--text-muted, #888)", marginBottom: 6, textTransform: "uppercase", letterSpacing: "0.05em" }}>
        Execution plan
      </div>
      <table style={{ width: "100%", fontSize: 12, borderCollapse: "collapse" }}>
        <thead>
          <tr>
            {["Tier", "Name", "Phase", "Mode"].map((h) => (
              <th key={h} style={{ textAlign: "left", fontWeight: 500, color: "var(--text-muted, #888)", padding: "2px 10px 4px 0", whiteSpace: "nowrap" }}>{h}</th>
            ))}
          </tr>
        </thead>
        <tbody>
          {sorted.map(({ det }, idx) => (
            <tr key={idx} style={{ borderTop: "1px solid var(--border, #e4e4e7)" }}>
              <td style={{ padding: "5px 10px 5px 0", color: "var(--text-muted, #888)", fontVariantNumeric: "tabular-nums" }}>
                {DETECTOR_TIER[det.type] ?? "?"}
              </td>
              <td style={{ padding: "5px 10px 5px 0" }}>
                <span style={{ display: "inline-block", width: 7, height: 7, borderRadius: "50%", background: TYPE_BADGE_COLORS[det.type], marginRight: 6, verticalAlign: "middle", flexShrink: 0 }} />
                {det.name}
              </td>
              <td style={{ padding: "5px 10px 5px 0", whiteSpace: "nowrap" }}>
                <span style={{ fontFamily: "monospace", fontSize: 11, marginRight: 4 }}>{phaseArrow(det)}</span>
                {phaseLabel(det)}
              </td>
              <td style={{ padding: "5px 0", color: det.type === "pii_protector" ? "var(--badge-info-text, #0891b2)" : undefined }}>
                {modeLabel(det)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Main GuardrailBuilder component
// ---------------------------------------------------------------------------

interface GuardrailBuilderProps {
  value: DetectorConfig[];
  onChange: (guardrails: DetectorConfig[]) => void;
}

export function GuardrailBuilder({ value, onChange }: GuardrailBuilderProps) {
  function addDetector(type: DetectorConfig["type"]) {
    let d: DetectorConfig;
    if (type === "regex") d = emptyRegex();
    else if (type === "keyword") d = emptyKeyword();
    else if (type === "jailbreak") d = emptyJailbreak();
    else if (type === "presidio") d = emptyPresidio();
    else if (type === "pii_protector") d = emptyPiiProtector();
    else d = emptyPromptGuard();
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
        <span className={s["form-label"]} style={{ margin: 0 }}>Guardrails ({value.length})</span>
        <div style={{ display: "flex", gap: 6 }}>
          {(["regex", "keyword", "jailbreak", "presidio", "prompt_guard", "pii_protector"] as const).map((type) => (
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
          No guardrails configured. Add one above to start scanning requests or responses.
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

      <DetectorPhaseSummary detectors={value} />
    </div>
  );
}
