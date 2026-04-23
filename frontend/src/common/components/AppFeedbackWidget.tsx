/**
 * AppFeedbackWidget — modal for submitting bug reports, feature suggestions,
 * or general feedback. Controlled externally: caller owns open/onClose state.
 *
 * Usage:
 *   const [open, setOpen] = useState(false);
 *   <AppFeedbackWidget open={open} onClose={() => setOpen(false)} />
 */

import { useState, useEffect } from "react";
import { api } from "src/api/client";
import { Modal } from "./Modal";
import s from "./layout/Layout.module.scss";

type FeedbackType = "bug" | "feature" | "other";

const TYPE_LABELS: Record<FeedbackType, string> = {
  bug:     "Bug report",
  feature: "Feature suggestion",
  other:   "Other",
};

interface Props {
  open: boolean;
  onClose: () => void;
}

export function AppFeedbackWidget({ open, onClose }: Props) {
  const [type, setType] = useState<FeedbackType>("other");
  const [summary, setSummary] = useState("");
  const [description, setDescription] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState(false);

  // Reset form when modal opens
  useEffect(() => {
    if (open) {
      setSuccess(false);
      setError(null);
    }
  }, [open]);

  function handleClose() {
    onClose();
    setTimeout(() => {
      setType("other");
      setSummary("");
      setDescription("");
      setSaving(false);
      setError(null);
    }, 150);
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    if (!summary.trim()) { setError("Summary is required."); return; }
    setSaving(true);
    setError(null);
    try {
      await api.post("/app-feedback", {
        type,
        summary: summary.trim(),
        description: description.trim() || undefined,
        url: window.location.href,
      });
      setSuccess(true);
      setTimeout(() => handleClose(), 1800);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Failed to submit feedback.");
    } finally {
      setSaving(false);
    }
  }

  if (!open) return null;

  return (
    <Modal title="Send Feedback" onClose={handleClose} error={error}>
      {success ? (
        <div className={`${s.alert} ${s["alert--success"]}`} style={{ margin: "16px 0 0" }}>
          Thanks for your feedback!
        </div>
      ) : (
        <form onSubmit={handleSubmit} style={{ display: "flex", flexDirection: "column", gap: 16, marginTop: 16 }}>
          <div className={s["form-group"]}>
            <label className={s["form-label"]}>Type</label>
            <div className={s["picker-options"]} style={{ gap: 6 }}>
              {(Object.keys(TYPE_LABELS) as FeedbackType[]).map((t) => (
                <button
                  key={t}
                  type="button"
                  className={`${s["picker-btn"]} ${type === t ? s["picker-btn--selected"] : ""}`}
                  onClick={() => setType(t)}
                >
                  {TYPE_LABELS[t]}
                </button>
              ))}
            </div>
          </div>

          <div className={s["form-group"]}>
            <label className={s["form-label"]} htmlFor="app-fb-summary">
              Summary <span style={{ color: "var(--text-error, #e74c3c)" }}>*</span>
            </label>
            <input
              id="app-fb-summary"
              data-cy="app-feedback-summary"
              className={s["form-input"]}
              type="text"
              maxLength={255}
              placeholder="One-line description…"
              value={summary}
              onChange={(e) => setSummary(e.target.value)}
              required
              autoFocus
            />
          </div>

          <div className={s["form-group"]}>
            <label className={s["form-label"]} htmlFor="app-fb-description">
              Details (optional)
            </label>
            <textarea
              id="app-fb-description"
              data-cy="app-feedback-description"
              className={s["form-input"]}
              rows={4}
              maxLength={4000}
              placeholder="Steps to reproduce, expected behaviour, screenshots…"
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              style={{ resize: "vertical" }}
            />
          </div>

          <div className={s["form-actions"]}>
            <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={handleClose} disabled={saving}>
              Cancel
            </button>
            <button
              type="submit"
              data-cy="app-feedback-submit"
              className={`${s.btn} ${s["btn--primary"]}`}
              disabled={saving || !summary.trim()}
            >
              {saving ? "Sending…" : "Send"}
            </button>
          </div>
        </form>
      )}
    </Modal>
  );
}
