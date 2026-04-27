/**
 * ReportsPage — admin inbox for content reports filed by users via the
 * "Report" button in the chat. Required by Google Play's generative-AI
 * policy (effective Jan 28 2026): users must be able to flag offensive
 * AI output and the developer must operate a moderation pipeline.
 *
 * Visible to admin and tenant_admin. URL: /reports.
 */

import { useEffect, useState } from "react";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { api } from "src/api/client";
import { fmtDateTime } from "src/common/utils/date";
import s from "src/common/components/layout/Layout.module.scss";

type Status = "open" | "triaged" | "dismissed";
type Reason = "offensive" | "inaccurate" | "unsafe" | "other";

interface ContentReport {
  id: string;
  user_id: string;
  user_email: string | null;
  tenant_id: string | null;
  conversation_id: string | null;
  message_id: string | null;
  message_text: string | null;
  reason: Reason;
  notes: string | null;
  status: Status;
  created_at: number;
  triaged_at: number | null;
  triaged_by_id: string | null;
}

const REASON_LABELS: Record<Reason, string> = {
  offensive:  "Offensive",
  unsafe:     "Unsafe advice",
  inaccurate: "Inaccurate",
  other:      "Other",
};

const REASON_BADGE: Record<Reason, string> = {
  offensive:  "badge--error",
  unsafe:     "badge--error",
  inaccurate: "badge--warning",
  other:      "badge--neutral",
};

const STATUS_BADGE: Record<Status, string> = {
  open:      "badge--warning",
  triaged:   "badge--success",
  dismissed: "badge--neutral",
};

export default function ReportsPage() {
  useDocumentTitle("Content Reports");

  const [items, setItems] = useState<ContentReport[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState<Status | "">("");
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [actingId, setActingId] = useState<string | null>(null);

  async function load() {
    setLoading(true);
    setError(null);
    try {
      const params = statusFilter ? `?status=${encodeURIComponent(statusFilter)}` : "";
      const data = await api.get<ContentReport[]>(`/reports${params}`);
      setItems(data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load reports.");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { load(); }, [statusFilter]); // eslint-disable-line react-hooks/exhaustive-deps

  async function setStatus(item: ContentReport, status: Status) {
    setActingId(item.id);
    try {
      await api.patch(`/reports/${item.id}`, { status });
      setItems((prev) => prev.map((i) =>
        i.id === item.id
          ? { ...i, status, triaged_at: status === "open" ? null : Math.floor(Date.now() / 1000) }
          : i,
      ));
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to update report.");
    } finally {
      setActingId(null);
    }
  }

  const openCount = items.filter((i) => i.status === "open").length;

  return (
    <div className={s.page}>
      <div className={s["page-header"]}>
        <div>
          <h1 className={s["page-title"]}>
            Content Reports
            {openCount > 0 && (
              <span
                className={`${s.badge} ${s["badge--warning"]}`}
                style={{ marginLeft: 10, verticalAlign: "middle" }}
              >
                {openCount} open
              </span>
            )}
          </h1>
          <p className={s["page-subtitle"]}>
            User-submitted reports of inappropriate or inaccurate model output.
          </p>
        </div>
      </div>

      <div style={{ display: "flex", gap: 8, marginBottom: 16 }}>
        {(["", "open", "triaged", "dismissed"] as const).map((status) => (
          <button
            key={status || "all"}
            data-cy={`reports-filter-${status || "all"}`}
            className={`${s.btn} ${statusFilter === status ? s["btn--primary"] : s["btn--secondary"]} ${s["btn--sm"]}`}
            onClick={() => setStatusFilter(status)}
          >
            {status ? status[0].toUpperCase() + status.slice(1) : "All"}
          </button>
        ))}
      </div>

      {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}

      {loading ? (
        <p style={{ color: "var(--text-secondary)" }}>Loading…</p>
      ) : items.length === 0 ? (
        <div className={s.empty}>No reports {statusFilter ? `with status “${statusFilter}”` : "yet"}.</div>
      ) : (
        <div className={s["table-wrapper"]}>
          <table className={s.table}>
            <thead>
              <tr>
                <th>When</th>
                <th>Reporter</th>
                <th>Reason</th>
                <th>Status</th>
                <th>Preview</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {items.map((item) => {
                const expanded = expandedId === item.id;
                const preview = (item.message_text ?? "").slice(0, 120);
                return (
                  <>
                    <tr
                      key={item.id}
                      data-cy="report-row"
                      style={{ cursor: "pointer" }}
                      onClick={() => setExpandedId(expanded ? null : item.id)}
                    >
                      <td className={s.mono} style={{ fontSize: 12, whiteSpace: "nowrap" }}>
                        {fmtDateTime(item.created_at)}
                      </td>
                      <td>{item.user_email ?? <span style={{ color: "var(--text-secondary)" }}>—</span>}</td>
                      <td>
                        <span className={`${s.badge} ${s[REASON_BADGE[item.reason]]}`}>
                          {REASON_LABELS[item.reason]}
                        </span>
                      </td>
                      <td>
                        <span className={`${s.badge} ${s[STATUS_BADGE[item.status]]}`}>
                          {item.status}
                        </span>
                      </td>
                      <td style={{ color: "var(--text-secondary)", fontSize: 13 }}>
                        {preview}
                        {(item.message_text?.length ?? 0) > 120 ? "…" : ""}
                      </td>
                      <td onClick={(e) => e.stopPropagation()}>
                        {item.status !== "triaged" && (
                          <button
                            data-cy="report-mark-triaged"
                            className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
                            onClick={() => setStatus(item, "triaged")}
                            disabled={actingId === item.id}
                          >
                            Mark triaged
                          </button>
                        )}
                        {item.status !== "dismissed" && (
                          <button
                            data-cy="report-dismiss"
                            className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
                            style={{ marginLeft: 6 }}
                            onClick={() => setStatus(item, "dismissed")}
                            disabled={actingId === item.id}
                          >
                            Dismiss
                          </button>
                        )}
                        {item.status !== "open" && (
                          <button
                            data-cy="report-reopen"
                            className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`}
                            style={{ marginLeft: 6 }}
                            onClick={() => setStatus(item, "open")}
                            disabled={actingId === item.id}
                          >
                            Reopen
                          </button>
                        )}
                      </td>
                    </tr>
                    {expanded && (
                      <tr>
                        <td colSpan={6} style={{ background: "var(--section-bg)", padding: 16 }}>
                          {item.notes && (
                            <div style={{ marginBottom: 12 }}>
                              <div style={{ fontSize: 12, fontWeight: 600, color: "var(--text-secondary)", marginBottom: 4 }}>
                                Reporter notes
                              </div>
                              <div style={{ whiteSpace: "pre-wrap" }}>{item.notes}</div>
                            </div>
                          )}
                          <div>
                            <div style={{ fontSize: 12, fontWeight: 600, color: "var(--text-secondary)", marginBottom: 4 }}>
                              Reported message
                            </div>
                            <pre style={{
                              whiteSpace: "pre-wrap",
                              background: "var(--card-bg)",
                              border: "1px solid var(--card-border)",
                              borderRadius: 6,
                              padding: 12,
                              maxHeight: 400,
                              overflow: "auto",
                              fontFamily: "inherit",
                              fontSize: 14,
                            }}>{item.message_text ?? "(empty)"}</pre>
                          </div>
                          <div style={{ marginTop: 12, fontSize: 12, color: "var(--text-secondary)" }}>
                            ID: <span className={s.code}>{item.id}</span>
                            {item.message_id && <> · Message: <span className={s.code}>{item.message_id}</span></>}
                            {item.conversation_id && <> · Conversation: <span className={s.code}>{item.conversation_id}</span></>}
                          </div>
                        </td>
                      </tr>
                    )}
                  </>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
