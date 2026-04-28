/**
 * ReportMessageModal — lets a user report an assistant response as offensive,
 * inaccurate, unsafe, or "other". Required by Google Play's generative-AI
 * policy: users must be able to flag offensive AI output without leaving the
 * app. POSTs to /admin/v1/reports.
 */

import { useState } from "react";
import { Modal } from "src/common/components/Modal";
import { api } from "src/api/client";
import { collectWithBridge } from "src/common/utils/clientContext";
import s from "src/common/components/layout/Layout.module.scss";

type Reason = "offensive" | "inaccurate" | "unsafe" | "other";

interface Props {
  messageId: string;
  messageText: string;
  conversationId?: string | null;
  onClose: () => void;
}

export default function ReportMessageModal({ messageId, messageText, conversationId, onClose }: Props) {
  const [reason, setReason] = useState<Reason>("offensive");
  const [notes, setNotes] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState(false);

  async function submit() {
    setSubmitting(true);
    setError(null);
    try {
      const client_context = await collectWithBridge();
      await api.post("/reports", {
        conversation_id: conversationId ?? null,
        message_id:      messageId,
        message_text:    messageText.slice(0, 16000),
        reason,
        notes:           notes.trim() || null,
        client_context,
      });
      setDone(true);
    } catch (e: any) {
      setError(e?.message ?? "Failed to submit report");
      setSubmitting(false);
    }
  }

  if (done) {
    return (
      <Modal title="Report submitted" onClose={onClose}>
        <p style={{ marginBottom: 16 }}>
          Thanks — our moderation team will review this response. You can
          continue using the app while we look into it.
        </p>
        <div className={s["form-actions"]}>
          <button
            type="button"
            className={`${s.btn} ${s["btn--primary"]}`}
            onClick={onClose}
            data-cy="report-done"
          >
            Close
          </button>
        </div>
      </Modal>
    );
  }

  return (
    <Modal title="Report this response" onClose={onClose} error={error}>
      <p style={{ marginBottom: 12, fontSize: 14, color: "var(--text-secondary)" }}>
        Help us improve our models and content filters. Your report goes to
        Myra Security GmbH for review.
      </p>

      <div className={s["form-group"]}>
        <label className={s["form-label"]} htmlFor="report-reason">Reason</label>
        <select
          id="report-reason"
          className={s["form-input"]}
          value={reason}
          onChange={(e) => setReason(e.target.value as Reason)}
          disabled={submitting}
          data-cy="report-reason"
        >
          <option value="offensive">Offensive or hateful content</option>
          <option value="unsafe">Unsafe or dangerous advice</option>
          <option value="inaccurate">Inaccurate or misleading</option>
          <option value="other">Other</option>
        </select>
      </div>

      <div className={s["form-group"]}>
        <label className={s["form-label"]} htmlFor="report-notes">Notes (optional)</label>
        <textarea
          id="report-notes"
          className={s["form-input"]}
          rows={4}
          value={notes}
          onChange={(e) => setNotes(e.target.value.slice(0, 2000))}
          disabled={submitting}
          placeholder="Anything else we should know?"
          data-cy="report-notes"
        />
      </div>

      <div className={s["form-actions"]}>
        <button
          type="button"
          className={`${s.btn} ${s["btn--secondary"]}`}
          onClick={onClose}
          disabled={submitting}
        >
          Cancel
        </button>
        <button
          type="button"
          className={`${s.btn} ${s["btn--primary"]}`}
          onClick={submit}
          disabled={submitting}
          data-cy="report-submit"
        >
          {submitting ? "Sending…" : "Submit report"}
        </button>
      </div>
    </Modal>
  );
}
