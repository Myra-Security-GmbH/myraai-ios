import { useState } from "react";
import { Modal } from "src/common/components/Modal";
import s from "src/common/components/layout/Layout.module.scss";

interface TokenRevealModalProps {
  token: string;
  onClose: () => void;
}

export function TokenRevealModal({ token, onClose }: TokenRevealModalProps) {
  const [copied, setCopied] = useState(false);
  function copy() {
    navigator.clipboard.writeText(token);
    setCopied(true);
    setTimeout(() => setCopied(false), 2000);
  }
  return (
    <Modal title="Token Created" onClose={onClose}>
      <div className={`${s.alert} ${s["alert--warning"]}`} style={{ marginBottom: 12 }}>
        Copy this token now — it will not be shown again.
      </div>
      <div className={s.mono} style={{ background: "var(--bg-secondary)", padding: "10px 14px", borderRadius: 6, wordBreak: "break-all", fontSize: 13, marginBottom: 14, cursor: "pointer" }} title="Click to copy" onClick={copy}>
        {token}
      </div>
      <div className={s["form-actions"]}>
        <button className={`${s.btn} ${s["btn--primary"]}`} onClick={copy}>{copied ? "Copied!" : "Copy"}</button>
        <button className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose}>Done</button>
      </div>
    </Modal>
  );
}
