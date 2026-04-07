import { useEffect, useState } from "react";
import { useNavigate, useSearchParams } from "react-router-dom";
import { api } from "src/api/client";
import type { ChatProject, ChatConversation, Gateway, Tenant } from "src/api/types";
import { useAuth } from "src/common/contexts/AuthContext";
import { Modal } from "src/common/components/Modal";
import s from "src/common/components/layout/Layout.module.scss";
import MembersDrawer from "./MembersDrawer";
import KnowledgePanel from "./KnowledgePanel";

function BackIcon() {
  return <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><polyline points="15 18 9 12 15 6" /></svg>;
}
function EditIcon() {
  return <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>;
}
function TrashIcon() {
  return <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6M14 11v6"/></svg>;
}
function ChatIcon() {
  return <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"/></svg>;
}
function UsersIcon() {
  return <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M23 21v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/></svg>;
}
function FilesIcon() {
  return <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round"><path d="M13 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><polyline points="13 2 13 9 20 9"/></svg>;
}

type Tab = "overview" | "knowledge" | "members" | "conversations";

const ROLE_BADGE: Record<string, string> = {
  owner:  s["badge--success"],
  editor: s["badge--warning"],
  viewer: s["badge--neutral"],
  admin:  s["badge--neutral"],
};

interface Props {
  projectId: string;
  initialProject: ChatProject | null;
  gateways: Gateway[];
  tenants: Tenant[];
  onUpdated: (proj: ChatProject) => void;
  onDeleted: () => void;
  onBack: () => void;
}

export default function ProjectDetail({ projectId, initialProject, gateways, onUpdated, onDeleted, onBack }: Props) {
  const { user: me } = useAuth();
  const navigate = useNavigate();
  const [project, setProject] = useState<ChatProject | null>(initialProject);
  const [conversations, setConversations] = useState<ChatConversation[]>([]);
  const [loading, setLoading] = useState(!initialProject);
  const [searchParams, setSearchParams] = useSearchParams();
  const VALID_TABS: Tab[] = ["overview", "knowledge", "members", "conversations"];
  const tabParam = searchParams.get("tab") as Tab | null;
  const tab: Tab = tabParam && VALID_TABS.includes(tabParam) ? tabParam : "overview";
  const [editing, setEditing] = useState(false);
  const [editName, setEditName] = useState("");
  const [editDesc, setEditDesc] = useState("");
  const [editInst, setEditInst] = useState("");
  const [editGateway, setEditGateway] = useState("");
  const [savingEdit, setSavingEdit] = useState(false);
  const [editError, setEditError] = useState<string | null>(null);
  const [deleting, setDeleting] = useState(false);
  const [showDeleteConfirm, setShowDeleteConfirm] = useState(false);
  const [showMembers, setShowMembers] = useState(false);

  const canEdit = project && (me?.role === "admin" || project.my_role === "owner" || project.my_role === "editor");
  const canManageMembers = project && (me?.role === "admin" || project.my_role === "owner");
  const canDelete = project && (me?.role === "admin" || project.my_role === "owner");

  useEffect(() => {
    api.get<ChatProject>(`/projects/${projectId}`)
      .then((p) => {
        setProject(p);
        setEditName(p.name);
        setEditDesc(p.description ?? "");
        setEditInst(p.instructions ?? "");
        setEditGateway(p.default_gateway_id ?? "");
      })
      .catch(() => {})
      .finally(() => setLoading(false));
    api.get<ChatConversation[]>(`/projects/${projectId}/conversations`)
      .then(setConversations).catch(() => {});
  }, [projectId]);

  function startEdit() {
    if (!project) return;
    setEditName(project.name);
    setEditDesc(project.description ?? "");
    setEditInst(project.instructions ?? "");
    setEditGateway(project.default_gateway_id ?? "");
    setEditing(true);
    setEditError(null);
  }

  async function saveEdit() {
    setSavingEdit(true);
    setEditError(null);
    try {
      const updated = await api.patch<ChatProject>(`/projects/${projectId}`, {
        name: editName.trim(),
        description: editDesc.trim() || null,
        instructions: editInst.trim() || null,
        default_gateway_id: editGateway || null,
      });
      setProject(updated);
      onUpdated(updated);
      setEditing(false);
    } catch (e) {
      setEditError(String(e));
    } finally {
      setSavingEdit(false);
    }
  }

  async function handleDelete() {
    setDeleting(true);
    try {
      await api.delete(`/projects/${projectId}`);
      onDeleted();
    } catch (e) {
      alert("Delete failed: " + String(e));
      setDeleting(false);
    }
  }

  if (loading) return <div className={s.empty}>Loading…</div>;
  if (!project) return <div className={`${s.alert} ${s["alert--error"]}`} style={{ margin: 24 }}>Project not found.</div>;

  const myRole = project.my_role ?? (me?.role === "admin" ? "admin" : null);

  return (
    <div className={s["detail-panel"]}>

      {/* Header */}
      <div className={s["detail-header"]}>
        <button type="button" className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={onBack}>
          <BackIcon /> Back
        </button>
        <span style={{ fontSize: 20, lineHeight: 1 }}>{project.icon}</span>
        <h2 className={s["detail-title"]}>{project.name}</h2>
        {myRole && (
          <span className={`${s.badge} ${ROLE_BADGE[myRole] ?? s["badge--neutral"]}`}>
            {myRole}
          </span>
        )}
        <div style={{ flex: 1 }} />
        <button type="button" className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`} onClick={() => navigate(`/chat?project_id=${projectId}`)} data-cy="project-open-chat-btn">
          <ChatIcon /> Open Chat
        </button>
        {canEdit && (
          <button type="button" className={`${s.btn} ${s["btn--secondary"]} ${s["btn--sm"]}`} onClick={startEdit} title="Edit project" data-cy="project-edit-btn">
            <EditIcon />
          </button>
        )}
        {canDelete && (
          <button type="button" className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={() => setShowDeleteConfirm(true)} title="Delete project" data-cy="project-delete-btn">
            <TrashIcon />
          </button>
        )}
      </div>

      {/* Tabs */}
      <div className={s.tabs}>
        {(["overview", "knowledge", "members", "conversations"] as Tab[]).map((t) => (
          <button
            key={t}
            type="button"
            className={`${s.tab} ${tab === t ? s["tab--active"] : ""}`}
            onClick={() => setSearchParams(prev => {
              if (t === "overview") prev.delete("tab");
              else prev.set("tab", t);
              return prev;
            })}
          >
            {t === "knowledge" && <FilesIcon />}
            {t === "members" && <UsersIcon />}
            {t.charAt(0).toUpperCase() + t.slice(1)}
          </button>
        ))}
      </div>

      {/* Content */}
      <div className={s["detail-panel-body"]}>

        {tab === "overview" && (
          <div style={{ maxWidth: 640 }}>
            {editing ? (
              <>
                <div className={s["form-group"]}>
                  <label className={s["form-label"]}>Name</label>
                  <input className={s["form-input"]} value={editName} onChange={(e) => setEditName(e.target.value)} />
                </div>
                <div className={s["form-group"]}>
                  <label className={s["form-label"]}>Description</label>
                  <input className={s["form-input"]} value={editDesc} onChange={(e) => setEditDesc(e.target.value)} />
                </div>
                <div className={s["form-group"]}>
                  <label className={s["form-label"]}>Project Instructions</label>
                  <textarea className={s["form-input"]} value={editInst} onChange={(e) => setEditInst(e.target.value)} rows={6}
                    style={{ resize: "vertical", fontFamily: "monospace", fontSize: 12 }} />
                </div>
                <div className={s["form-group"]}>
                    <label className={s["form-label"]}>Default Gateway</label>
                    <select className={s["form-input"]} value={editGateway} onChange={(e) => setEditGateway(e.target.value)}>
                      <option value="">— None —</option>
                      {gateways.map((g) => <option key={g.id} value={g.id}>{g.slug}</option>)}
                    </select>
                    <p className={s["form-hint"]}>The gateway determines which AI provider and model are used.</p>
                  </div>
                {editError && <div className={`${s.alert} ${s["alert--error"]}`}>{editError}</div>}
                <div className={s["form-actions"]}>
                  <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={() => setEditing(false)} disabled={savingEdit}>Cancel</button>
                  <button type="button" className={`${s.btn} ${s["btn--primary"]}`} onClick={saveEdit} disabled={savingEdit} data-cy="project-save-edit-btn">
                    {savingEdit ? "Saving…" : "Save Changes"}
                  </button>
                </div>
              </>
            ) : (
              <>
                {project.description && (
                  <p className={s["page-subtitle"]} style={{ marginBottom: 20 }}>{project.description}</p>
                )}
                <div className={s["stats-grid"]}>
                  <div className={s["stat-card"]}>
                    <div className={s["stat-label"]}>Default Gateway</div>
                    <div className={`${s["stat-value"]} ${s["stat-value--text"]}`}>
                      {gateways.find((g) => g.id === project.default_gateway_id)?.slug ?? "—"}
                    </div>
                  </div>
                  <div className={s["stat-card"]}>
                    <div className={s["stat-label"]}>Members</div>
                    <div className={s["stat-value"]}>{project.members?.length ?? project.member_count ?? 0}</div>
                  </div>
                  <div className={s["stat-card"]}>
                    <div className={s["stat-label"]}>Knowledge Files</div>
                    <div className={s["stat-value"]}>{project.knowledge?.length ?? project.knowledge_count ?? 0}</div>
                  </div>
                </div>
                {project.instructions && (
                  <div>
                    <div className={s["stat-label"]} style={{ marginBottom: 8 }}>Project Instructions</div>
                    <pre style={{ margin: 0, padding: 12, background: "var(--section-bg)", borderRadius: 6, fontSize: 12, whiteSpace: "pre-wrap", wordBreak: "break-word", color: "var(--text-primary)", border: "1px solid var(--card-border)" }}>
                      {project.instructions}
                    </pre>
                  </div>
                )}
              </>
            )}
          </div>
        )}

        {tab === "knowledge" && (
          <KnowledgePanel projectId={projectId} canEdit={!!canEdit} />
        )}

        {tab === "members" && (
          <div style={{ maxWidth: 720 }}>
            <div className={s["section-header"]}>
              <h3 className={s["section-title"]}>Members</h3>
              {canManageMembers && (
                <button type="button" className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`} onClick={() => setShowMembers(true)} data-cy="invite-member-btn">
                  + Invite Member
                </button>
              )}
            </div>
            {(project.members ?? []).length === 0 ? (
              <div className={s.empty}>No members yet.</div>
            ) : (
              <div className={s["table-wrapper"]}>
                <table className={s.table}>
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>Email</th>
                      <th>Role</th>
                      <th>Joined</th>
                      {canManageMembers && <th />}
                    </tr>
                  </thead>
                  <tbody>
                    {(project.members ?? []).map((m) => (
                      <tr key={m.user_id}>
                        <td>{m.name ?? "—"}</td>
                        <td>{m.email}</td>
                        <td>
                          <span className={`${s.badge} ${ROLE_BADGE[m.role] ?? s["badge--neutral"]}`}>
                            {m.role}
                          </span>
                        </td>
                        <td style={{ color: "var(--text-secondary)" }}>{new Date(m.joined_at).toLocaleDateString()}</td>
                        {canManageMembers && (
                          <td>
                            {m.user_id !== project.created_by && (
                              <RemoveMemberButton projectId={projectId} userId={m.user_id} onRemoved={() => {
                                setProject((p) => p ? { ...p, members: (p.members ?? []).filter((x) => x.user_id !== m.user_id) } : p);
                              }} />
                            )}
                          </td>
                        )}
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        )}

        {tab === "conversations" && (
          <div style={{ maxWidth: 720 }}>
            <div className={s["section-header"]}>
              <h3 className={s["section-title"]}>Conversations</h3>
              <button type="button" className={`${s.btn} ${s["btn--primary"]} ${s["btn--sm"]}`} onClick={() => navigate(`/chat?project_id=${projectId}`)}>
                <ChatIcon /> New Conversation
              </button>
            </div>
            {conversations.length === 0 ? (
              <div className={s.empty}>No conversations in this project yet.</div>
            ) : (
              <div className={s["table-wrapper"]}>
                <table className={s.table}>
                  <thead>
                    <tr>
                      <th>Title</th>
                      <th>Model</th>
                      <th>Updated</th>
                    </tr>
                  </thead>
                  <tbody>
                    {conversations.map((c) => (
                      <tr key={c.id} style={{ cursor: "pointer" }} onClick={() => navigate(`/chat?project_id=${projectId}&conv=${c.id}`)}>
                        <td>{c.title || "Untitled"}</td>
                        <td style={{ color: "var(--text-secondary)" }}>{c.model}</td>
                        <td style={{ color: "var(--text-secondary)" }}>{new Date(c.updated_at).toLocaleDateString()}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        )}

      </div>

      {/* Delete confirmation modal */}
      {showDeleteConfirm && (
        <Modal title="Delete Project?" onClose={() => setShowDeleteConfirm(false)}>
          <p style={{ margin: "0 0 8px", color: "var(--text-secondary)" }}>
            This will permanently delete <strong>{project.name}</strong> and remove all its members and knowledge files. Conversations will be detached but not deleted.
          </p>
          <p style={{ margin: "0 0 4px", fontSize: 13, color: "var(--text-secondary)" }}>This cannot be undone.</p>
          <div className={s["form-actions"]}>
            <button type="button" className={`${s.btn} ${s["btn--secondary"]}`} onClick={() => setShowDeleteConfirm(false)} disabled={deleting}>Cancel</button>
            <button type="button" className={`${s.btn} ${s["btn--danger"]}`} onClick={handleDelete} disabled={deleting} data-cy="confirm-delete-project-btn">
              {deleting ? "Deleting…" : "Delete Project"}
            </button>
          </div>
        </Modal>
      )}

      {/* Members drawer */}
      {showMembers && (
        <MembersDrawer
          projectId={projectId}
          onClose={() => setShowMembers(false)}
          onMemberAdded={(member) => {
            setProject((p) => p ? { ...p, members: [...(p.members ?? []), member] } : p);
          }}
        />
      )}
    </div>
  );
}

function RemoveMemberButton({ projectId, userId, onRemoved }: { projectId: string; userId: string; onRemoved: () => void }) {
  const [loading, setLoading] = useState(false);
  async function handle() {
    if (!confirm("Remove this member?")) return;
    setLoading(true);
    try {
      await api.delete(`/projects/${projectId}/members/${userId}`);
      onRemoved();
    } catch (e) {
      alert("Error: " + String(e));
    } finally {
      setLoading(false);
    }
  }
  return (
    <button type="button" className={`${s.btn} ${s["btn--danger"]} ${s["btn--sm"]}`} onClick={handle} disabled={loading}>
      {loading ? "…" : "Remove"}
    </button>
  );
}
