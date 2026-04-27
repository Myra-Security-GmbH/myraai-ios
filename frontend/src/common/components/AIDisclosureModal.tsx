/**
 * AIDisclosureModal.tsx — One-time generative-AI disclosure shown to a user
 * once after they sign in. Required by Google Play's generative-AI policy
 * (effective Jan 28 2026) and matched on the App Store side.
 *
 * Persists acknowledgement in localStorage. Bump the storage key suffix when
 * the disclosure copy changes materially so existing users see it again.
 */

import { useEffect, useState } from "react";
import { Modal } from "src/common/components/Modal";
import s from "src/common/components/layout/Layout.module.scss";

const STORAGE_KEY = "aig:ai-disclosure-acknowledged-v1";

export default function AIDisclosureModal() {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    try {
      if (localStorage.getItem(STORAGE_KEY) !== "1") setOpen(true);
    } catch {
      // localStorage unavailable (private mode, etc.) — show once per session
      // rather than blocking access entirely.
      setOpen(true);
    }
  }, []);

  function acknowledge() {
    try { localStorage.setItem(STORAGE_KEY, "1"); } catch { /* ignore */ }
    setOpen(false);
  }

  if (!open) return null;

  return (
    <Modal title="A note about MYRA AI" onClose={acknowledge} disableOverlayClose>
      <p style={{ marginBottom: 12 }}>
        MYRA AI uses large language models to generate responses. Output can
        be inaccurate, incomplete, biased, or otherwise inappropriate. Treat
        it as a starting point, not a final answer — especially for medical,
        legal, financial, or safety-critical decisions.
      </p>
      <p style={{ marginBottom: 12 }}>
        If a response is offensive, unsafe, or wrong in a way you'd like us
        to know about, you can flag it from inside the conversation: open
        the action menu on the assistant message and choose <strong>Report</strong>.
      </p>
      <p style={{ marginBottom: 16, color: "var(--text-secondary)", fontSize: 14 }}>
        Your prompts and any files you upload are sent to the model
        provider configured for your gateway. See the{" "}
        <a href="/privacy" target="_blank" rel="noopener noreferrer">privacy policy</a> for details.
      </p>
      <div className={s["form-actions"]}>
        <button
          type="button"
          className={`${s.btn} ${s["btn--primary"]}`}
          onClick={acknowledge}
          data-cy="ai-disclosure-ack"
        >
          Got it
        </button>
      </div>
    </Modal>
  );
}
