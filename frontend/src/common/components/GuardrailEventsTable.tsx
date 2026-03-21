import { useState } from "react";
import { fmtDateTime } from "src/common/utils/date";
import s from "src/common/components/layout/Layout.module.scss";

const LLAMA_GUARD_LABELS: Record<string, string> = {
  S1: "Violent Crimes", S2: "Non-Violent Crimes", S3: "Sex Crimes",
  S4: "Child Exploitation", S5: "Defamation", S6: "Specialized Advice",
  S7: "Privacy", S8: "IP Infringement", S9: "WMD/CBRN", S10: "Hate Speech",
  S11: "Self-Harm", S12: "Explicit Sexual", S13: "Elections", S14: "Code Abuse",
};

export function decodeBlockReason(reason: string | null): string {
  if (!reason) return "—";
  if (/^S\d/.test(reason)) {
    return reason.split(/,\s*/).map((code) => {
      const key = code.trim();
      return LLAMA_GUARD_LABELS[key] ? `${key}: ${LLAMA_GUARD_LABELS[key]}` : key;
    }).join(", ");
  }
  return reason;
}

function fmt(n: number | null | undefined) {
  if (n == null) return "—";
  return n.toLocaleString("en-US", { maximumFractionDigits: 0 });
}

interface Props {
  rows: any[];
  showGuardrailLatency?: boolean;
}

export function GuardrailEventsTable({ rows, showGuardrailLatency = false }: Props) {
  const [expandedId, setExpandedId] = useState<number | null>(null);
  const colSpan = showGuardrailLatency ? 7 : 6;

  return (
    <div className={s["table-wrapper"]}>
      <table className={s.table}>
        <thead>
          <tr>
            <th>Time</th>
            <th>Tenant</th>
            <th>Outcome</th>
            <th>Detector</th>
            <th>Reason</th>
            <th>Latency</th>
            {showGuardrailLatency && <th>Guardrail</th>}
          </tr>
        </thead>
        <tbody>
          {rows.map((row: any, i: number) => {
            const outcome = row.blocked ? "blocked" : row.scrub_applied ? "scrubbed" : "flagged";
            const variant = outcome === "blocked" ? "error" : outcome === "scrubbed" ? "warning" : "neutral";
            const hasDetail = !!(row.response_raw || row.prompt_scrubbed);
            const isExpanded = expandedId === i;
            return (
              <>
                <tr
                  key={i}
                  className={outcome === "blocked" ? s.blocked : ""}
                  style={hasDetail ? { cursor: "pointer", background: "var(--bg-highlight, #fffbe6)" } : undefined}
                  onClick={hasDetail ? () => setExpandedId(isExpanded ? null : i) : undefined}
                >
                  <td className={s.mono} style={{ fontSize: 11 }}>{fmtDateTime(row.ts)}</td>
                  <td><span className={s.code}>{row.tenant ?? row.tenant_id?.slice(0, 8)}</span></td>
                  <td><span className={`${s.badge} ${s[`badge--${variant}`]}`}>{outcome}</span></td>
                  <td style={{ fontSize: 12 }}>
                    {(row.detectors_fired?.length ?? 0) > 0
                      ? row.detectors_fired.join(", ")
                      : (row.blocked_by ?? "—")}
                  </td>
                  <td style={{ fontSize: 12, maxWidth: 240 }}>{decodeBlockReason(row.block_reason)}</td>
                  <td>{fmt(row.latency_ms)} ms</td>
                  {showGuardrailLatency && (
                    <td>{row.guardrail_latency_ms != null ? `${fmt(row.guardrail_latency_ms)} ms` : "—"}</td>
                  )}
                </tr>
                {hasDetail && isExpanded && (
                  <tr key={`${i}-detail`}>
                    <td colSpan={colSpan} style={{ padding: "8px 12px", background: "var(--bg-subtle, #f6f8fa)" }}>
                      {row.prompt_scrubbed && (
                        <div style={{ marginBottom: row.response_raw ? 12 : 0 }}>
                          <div style={{ fontSize: 11, fontWeight: 600, marginBottom: 4, color: "var(--text-muted, #666)" }}>
                            Prompt sent to LLM (after PII substitution)
                          </div>
                          <pre style={{ margin: 0, fontSize: 11, whiteSpace: "pre-wrap", wordBreak: "break-all", maxHeight: 300, overflowY: "auto" }}>
                            {row.prompt_scrubbed}
                          </pre>
                        </div>
                      )}
                      {row.response_raw && (
                        <div>
                          <div style={{ fontSize: 11, fontWeight: 600, marginBottom: 4, color: "var(--text-muted, #666)" }}>
                            LLM response (before PII token restoration)
                          </div>
                          <pre style={{ margin: 0, fontSize: 11, whiteSpace: "pre-wrap", wordBreak: "break-all", maxHeight: 300, overflowY: "auto" }}>
                            {row.response_raw}
                          </pre>
                        </div>
                      )}
                    </td>
                  </tr>
                )}
              </>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}
