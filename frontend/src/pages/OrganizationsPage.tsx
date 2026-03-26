import { useEffect, useState } from "react";
import { api } from "src/api/client";
import { Organization } from "src/api/types";
import { useAuth } from "src/common/contexts/AuthContext";
import { fmtDate } from "src/common/utils/date";
import s from "src/common/components/layout/Layout.module.scss";

// ---------------------------------------------------------------------------
// Modal
// ---------------------------------------------------------------------------

function OrgModal({ org, onClose, onSaved }: {
  org?: Organization; onClose: () => void; onSaved: () => void;
}) {
  const isEdit = !!org;
  const [name, setName] = useState(org?.name ?? "");
  const [slug, setSlug] = useState(org?.slug ?? "");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true); setError(null);
    try {
      if (isEdit) {
        await api.patch(`/organizations/${org!.id}`, { name, slug });
      } else {
        await api.post("/organizations", { name, slug });
      }
      onSaved(); onClose();
    } catch (err: any) { setError(err.message); }
    finally { setLoading(false); }
  }

  return (
    <div className={s["modal-overlay"]} onClick={(e) => e.target === e.currentTarget && onClose()}>
      <div className={s.modal}>
        <div className={s["modal-header"]}>
          <h2 className={s["modal-title"]}>{isEdit ? `Edit: ${org!.name}` : "New Organization"}</h2>
          <button className={s["modal-close"]} onClick={onClose}>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
          </button>
        </div>
        {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}
        <form onSubmit={handleSubmit}>
          <div className={s["form-group"]}>
            <label htmlFor="org-name" className={s["form-label"]}>Name *</label>
            <input
              id="org-name"
              className={s["form-input"]}
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Acme Corp"
              required
            />
          </div>
          <div className={s["form-group"]}>
            <label htmlFor="org-slug" className={s["form-label"]}>Slug *</label>
            <input
              id="org-slug"
              className={s["form-input"]}
              value={slug}
              onChange={(e) => setSlug(e.target.value.toLowerCase().replace(/[^a-z0-9-]/g, ""))}
              placeholder="acme-corp"
              required
            />
            <p className={s["form-hint"]}>Lowercase letters, numbers, and hyphens only.</p>
          </div>
          <div className={s["form-actions"]}>
            <button type="button" className={s["btn-secondary"]} onClick={onClose}>Cancel</button>
            <button type="submit" className={s["btn-primary"]} disabled={loading}>
              {loading ? "Saving…" : isEdit ? "Save changes" : "Create"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

export default function OrganizationsPage() {
  const { user } = useAuth();
  const isAdmin = user?.role === "admin";

  const [orgs, setOrgs] = useState<Organization[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [modal, setModal] = useState<{ open: boolean; org?: Organization }>({ open: false });
  const [deleteId, setDeleteId] = useState<string | null>(null);

  async function load() {
    setLoading(true); setError(null);
    try {
      const data = await api.get<Organization[]>("/organizations");
      setOrgs(data);
    } catch (err: any) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => { load(); }, []);

  async function handleDelete(id: string) {
    try {
      await api.delete(`/organizations/${id}`);
      setDeleteId(null);
      load();
    } catch (err: any) {
      setError(err.message);
    }
  }

  return (
    <div className={s.page}>
      <div className={s["page-header"]}>
        <div>
          <h1 className={s["page-title"]}>Organizations</h1>
          <p className={s["page-subtitle"]}>Manage organizations and their access scope.</p>
        </div>
        {isAdmin && (
          <button className={s["btn-primary"]} onClick={() => setModal({ open: true })}>
            + New Organization
          </button>
        )}
      </div>

      {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}

      {loading ? (
        <div className={s["empty-state"]}>Loading…</div>
      ) : orgs.length === 0 ? (
        <div className={s["empty-state"]}>
          <p>No organizations yet.</p>
          {isAdmin && (
            <button className={s["btn-primary"]} onClick={() => setModal({ open: true })}>
              Create your first organization
            </button>
          )}
        </div>
      ) : (
        <div className={s.card}>
          <table className={s.table}>
            <thead>
              <tr>
                <th>Name</th>
                <th>Slug</th>
                <th>Created</th>
                {isAdmin && <th style={{ width: 120 }}>Actions</th>}
              </tr>
            </thead>
            <tbody>
              {orgs.map((org) => (
                <tr key={org.id}>
                  <td className={s["td-bold"]}>{org.name}</td>
                  <td><code className={s.code}>{org.slug}</code></td>
                  <td>{fmtDate(org.created_at)}</td>
                  {isAdmin && (
                    <td>
                      <div className={s["row-actions"]}>
                        <button
                          className={s["btn-icon"]}
                          title="Edit"
                          onClick={() => setModal({ open: true, org })}
                        >
                          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/></svg>
                        </button>
                        <button
                          className={`${s["btn-icon"]} ${s["btn-icon--danger"]}`}
                          title="Delete"
                          onClick={() => setDeleteId(org.id)}
                        >
                          <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/><path d="M10 11v6"/><path d="M14 11v6"/><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg>
                        </button>
                      </div>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {modal.open && (
        <OrgModal
          org={modal.org}
          onClose={() => setModal({ open: false })}
          onSaved={load}
        />
      )}

      {deleteId && (
        <div className={s["modal-overlay"]} onClick={() => setDeleteId(null)}>
          <div className={s.modal} onClick={(e) => e.stopPropagation()}>
            <div className={s["modal-header"]}>
              <h2 className={s["modal-title"]}>Delete Organization</h2>
            </div>
            <p style={{ padding: "0 0 16px", color: "var(--text-muted, #888)", fontSize: 14 }}>
              This will permanently delete the organization. Tenants assigned to it will become unassigned.
            </p>
            <div className={s["form-actions"]}>
              <button className={s["btn-secondary"]} onClick={() => setDeleteId(null)}>Cancel</button>
              <button className={s["btn-danger"]} onClick={() => handleDelete(deleteId)}>Delete</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
