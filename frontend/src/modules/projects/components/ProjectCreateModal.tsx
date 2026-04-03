import { useState } from "react";
import { api } from "src/api/client";
import type { ChatProject, Gateway, Tenant } from "src/api/types";
import { Modal } from "src/common/components/Modal";
import s from "src/common/components/layout/Layout.module.scss";

const ICON_OPTIONS = ["📁", "💼", "🔬", "🎨", "💡", "🚀", "📊", "🛠️", "📝", "🌐"];
const COLOR_OPTIONS = [
  "#2563eb", "#7c3aed", "#059669", "#dc2626", "#d97706",
  "#0891b2", "#db2777", "#65a30d", "#4f46e5", "#374151",
];

interface Props {
  tenants: Tenant[];
  gateways: Gateway[];
  defaultTenantId: string;
  onCreated: (proj: ChatProject) => void;
  onClose: () => void;
}

export default function ProjectCreateModal({ tenants, gateways, defaultTenantId, onCreated, onClose }: Props) {
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [instructions, setInstructions] = useState("");
  const [icon, setIcon] = useState("📁");
  const [color, setColor] = useState("#2563eb");
  const [gatewayId, setGatewayId] = useState("");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  void tenants;

  async function handleSave() {
    if (!name.trim()) { setError("Name is required"); return; }
    setSaving(true);
    setError(null);
    try {
      const proj = await api.post<ChatProject>("/projects", {
        name: name.trim(),
        description: description.trim() || null,
        instructions: instructions.trim() || null,
        icon,
        color,
        default_gateway_id: gatewayId || null,
        tenant_id: defaultTenantId || undefined,
      });
      onCreated(proj);
    } catch (e) {
      setError(String(e));
    } finally {
      setSaving(false);
    }
  }

  return (
    <Modal title="New Project" onClose={onClose} error={error}>

      <div className={s["picker-row"]}>
        <div className={s["picker-group"]}>
          <span className={s["form-label"]}>Icon</span>
          <div className={s["picker-options"]}>
            {ICON_OPTIONS.map((ic) => (
              <button
                key={ic}
                type="button"
                className={`${s["picker-btn"]} ${icon === ic ? s["picker-btn--selected"] : ""}`}
                onClick={() => setIcon(ic)}
              >
                {ic}
              </button>
            ))}
          </div>
        </div>
        <div className={s["picker-group"]}>
          <span className={s["form-label"]}>Color</span>
          <div className={s["picker-options"]}>
            {COLOR_OPTIONS.map((c) => (
              <button
                key={c}
                type="button"
                className={`${s["color-swatch"]} ${color === c ? s["color-swatch--selected"] : ""}`}
                style={{ background: c }}
                onClick={() => setColor(c)}
              />
            ))}
          </div>
        </div>
      </div>

      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Name *</label>
        <input
          autoFocus
          className={s["form-input"]}
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && handleSave()}
          placeholder="e.g. Research Project"
          data-cy="project-name-input"
        />
      </div>

      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Description</label>
        <input
          className={s["form-input"]}
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          placeholder="Short description (optional)"
        />
      </div>

      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Project Instructions</label>
        <textarea
          className={s["form-input"]}
          value={instructions}
          onChange={(e) => setInstructions(e.target.value)}
          rows={4}
          placeholder="Custom system prompt for all conversations in this project (optional)"
          style={{ resize: "vertical", fontFamily: "monospace", fontSize: 12 }}
          data-cy="project-instructions-input"
        />
      </div>

      <div className={s["form-group"]}>
        <label className={s["form-label"]}>Default Gateway</label>
        <select
          className={s["form-input"]}
          value={gatewayId}
          onChange={(e) => setGatewayId(e.target.value)}
        >
          <option value="">— None —</option>
          {gateways.map((g) => (
            <option key={g.id} value={g.id}>{g.slug}</option>
          ))}
        </select>
        <p className={s["form-hint"]}>The gateway determines which AI provider and model are used.</p>
      </div>

      <div className={s["form-actions"]}>
        <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={onClose} disabled={saving}>
          Cancel
        </button>
        <button type="button" className={`${s.btn} ${s["btn--primary"]}`} onClick={handleSave} disabled={saving} data-cy="project-save-btn">
          {saving ? "Creating…" : "Create Project"}
        </button>
      </div>

    </Modal>
  );
}
