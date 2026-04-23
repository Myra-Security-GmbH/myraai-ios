/**
 * AppFeedbackPage — admin inbox for application-level user feedback
 * (bug reports, feature suggestions submitted via AppFeedbackWidget).
 *
 * Only visible to users with role=admin.
 * URL: /feedback
 */

import { useEffect, useState } from "react";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import { api } from "src/api/client";
import { fmtDateTime } from "src/common/utils/date";
import s from "src/common/components/layout/Layout.module.scss";

interface AppFeedback {
  id: string;
  user_id: string | null;
  user_email: string | null;
  type: "bug" | "feature" | "other";
  summary: string;
  description: string | null;
  url: string | null;
  created_at: number;
  processed: number;
}

const TYPE_BADGE: Record<string, string> = {
  bug:     "badge--error",
  feature: "badge--success",
  other:   "badge--neutral",
};

const TYPE_LABELS: Record<string, string> = {
  bug:     "Bug",
  feature: "Feature",
  other:   "Other",
};

export default function AppFeedbackPage() {
  useDocumentTitle("Feedback Inbox");

  const [items, setItems] = useState<AppFeedback[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [typeFilter, setTypeFilter] = useState("");
  const [expandedId, setExpandedId] = useState<string | null>(null);
  const [processingId, setProcessingId] = useState<string | null>(null);

  async function load() {
    setLoading(true);
    setError(null);
    try {
      const params = typeFilter ? `?type=${encodeURIComponent(typeFilter)}` : "";
      const data = await api.get<AppFeedback[]>(`/app-feedback${params}`);
      setItems(data);
    } catch (e) {
      setError(e instanceof Error ? e.message : "Failed to load feedback.");
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { load(); }, [typeFilter]); // eslint-disable-line react-hooks/exhaustive-deps

  async function toggleProcessed(item: AppFeedback) {
    setProcessingId(item.id);
    try {
      await api.patch(`/app-feedback/${item.id}`, { processed: !item.processed });
      setItems((prev) =>
        prev.map((i) => i.id === item.id ? { ...i, processed: i.processed ? 0 : 1 } : i)
      );
    } catch { /* no-op */ } finally {
      setProcessingId(null);
    }
  }

  const unprocessedCount = items.filter((i) => !i.processed).length;

  return (
    <div className={s.page}>
      <div className={s["page-header"]}>
        <div>
          <h1 className={s["page-title"]}>
            Feedback Inbox
            {unprocessedCount > 0 && (
              <span
                className={`${s.badge} ${s["badge--warning"]}`}
                style={{ marginLeft: 10, verticalAlign: "middle" }}
              >
                {unprocessedCount} new
              </span>
            )}
          </h1>
          <p className={s["page-subtitle"]}>
            Bug reports and feature suggestions submitted by users.
          </p>
        </div>
      </div>

      {/* Filter bar */}
      <div style={{ display: "flex", gap: 8, marginBottom: 16 }}>
        {["", "bug", "feature", "other"].map((t) => (
          <button
            key={t || "all"}
            data-cy={`feedback-filter-${t || "all"}`}
            className={`${s.btn} ${typeFilter === t ? s["btn--primary"] : s["btn--secondary"]} ${s["btn--sm"]}`}
            onClick={() => setTypeFilter(t)}
          >
            {t ? TYPE_LABELS[t] : "All"}
          </button>
        ))}
      </div>

      {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}

      {loading ? (
        <p style={{ color: "var(--text-secondary)" }}>Loading…</p>
      ) : items.length === 0 ? (
        <div className={s.empty}>No feedback submissions yet.</div>
      ) : (
        <div className={s["table-wrapper"]}>
          <table className={s.table}>
            <thead>
              <tr>
                <th>Date</th>
                <th>Type</th>
                <th>Summary</th>
                <th>User</th>
                <th>Processed</th>
              </tr>
            </thead>
            <tbody>
              {items.map((item) => (
                <>
                  <tr
                    key={item.id}
                    style={{ cursor: "pointer", opacity: item.processed ? 0.6 : 1 }}
                    onClick={() => setExpandedId(expandedId === item.id ? null : item.id)}
                    data-cy="feedback-row"
                  >
                    <td style={{ whiteSpace: "nowrap" }}>{fmtDateTime(item.created_at)}</td>
                    <td>
                      <span className={`${s.badge} ${s[TYPE_BADGE[item.type] ?? "badge--neutral"]}`}>
                        {TYPE_LABELS[item.type] ?? item.type}
                      </span>
                    </td>
                    <td>{item.summary}</td>
                    <td style={{ color: "var(--text-secondary)", fontSize: 13 }}>
                      {item.user_email ?? "—"}
                    </td>
                    <td>
                      <button
                        className={`${s.btn} ${s["btn--sm"]} ${item.processed ? s["btn--primary"] : s["btn--secondary"]}`}
                        disabled={processingId === item.id}
                        onClick={(e) => { e.stopPropagation(); toggleProcessed(item); }}
                        data-cy="feedback-toggle-processed"
                        title={item.processed ? "Mark as unprocessed" : "Mark as processed"}
                      >
                        {item.processed ? "Done" : "Mark done"}
                      </button>
                    </td>
                  </tr>
                  {expandedId === item.id && (
                    <tr key={`${item.id}-detail`}>
                      <td colSpan={5} style={{ padding: "12px 16px", background: "var(--table-row-hover)" }}>
                        {item.description ? (
                          <p style={{ margin: "0 0 8px", whiteSpace: "pre-wrap", fontSize: 13 }}>
                            {item.description}
                          </p>
                        ) : (
                          <p style={{ margin: "0 0 8px", color: "var(--text-secondary)", fontSize: 13 }}>
                            No additional details.
                          </p>
                        )}
                        {item.url && (
                          <p style={{ margin: 0, fontSize: 12, color: "var(--text-secondary)" }}>
                            Page: <code style={{ wordBreak: "break-all" }}>{item.url}</code>
                          </p>
                        )}
                      </td>
                    </tr>
                  )}
                </>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
