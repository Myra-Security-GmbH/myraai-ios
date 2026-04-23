import { useState } from "react";
import { api } from "src/api/client";
import type { ProjectMember, ProjectRole } from "src/api/types";
import { Modal } from "src/common/components/Modal";
import s from "src/common/components/layout/Layout.module.scss";

interface Props {
  projectId: string;
  onClose: () => void;
  onMemberAdded: (member: ProjectMember) => void;
}

export default function MembersDrawer({ projectId, onClose, onMemberAdded }: Props) {
  const [email, setEmail] = useState("");
  const [role, setRole] = useState<ProjectRole>("viewer");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);

  async function handleInvite() {
    if (!email.trim()) { setError("Email is required"); return; }
    setSaving(true);
    setError(null);
    setSuccess(null);
    try {
      const users = await api.get<Array<{ id: string; email: string; name: string | null }>>(
        `/users/search?email=${encodeURIComponent(email.trim())}`
      ).catch(() => []);
      const found = Array.isArray(users)
        ? users.find((u) => u.email.toLowerCase() === email.trim().toLowerCase())
        : null;
      if (!found) {
        setError("User not found. They must have an account first.");
        setSaving(false);
        return;
      }
      await api.post(`/projects/${projectId}/members`, { user_id: found.id, role });
      onMemberAdded({ user_id: found.id, role, email: found.email, name: found.name, joined_at: Math.floor(Date.now() / 1000) });
      setSuccess(`${found.email} added as ${role}.`);
      setEmail("");
    } catch (e) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal title="Invite Member" onClose={onClose} error={error}>

      {success && <div className={`${s.alert} ${s["alert--success"]}`}>{success}</div>}

      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Email address</label>
        <input
          autoFocus
          type="email"
          className={s["form-input"]}
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && handleInvite()}
          placeholder="user@example.com"
          data-cy="member-email-input"
        />
      </div>

      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Role</label>
        <select
          className={s["form-input"]}
          value={role}
          onChange={(e) => setRole(e.target.value as ProjectRole)}
        >
          <option value="viewer">Viewer — can read and chat</option>
          <option value="editor">Editor — can add knowledge files</option>
          <option value="owner">Owner — full control</option>
        </select>
      </div>

      <div className={s["form-actions"]}>
        <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose} disabled={saving}>
          Close
        </button>
        <button type="button" className={`${s.btn} ${s["btn--primary"]}`} onClick={handleInvite} disabled={saving} data-cy="confirm-invite-btn">
          {saving ? "Inviting…" : "Invite"}
        </button>
      </div>

    </Modal>
  );
}
