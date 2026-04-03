import { useEffect, useState } from "react";
import { useNavigate, useParams } from "react-router-dom";
import { api } from "src/api/client";
import type { ChatProject, Gateway, Tenant } from "src/api/types";
import { useAuth } from "src/common/contexts/AuthContext";
import { useDocumentTitle } from "src/common/hooks/useDocumentTitle";
import s from "src/common/components/layout/Layout.module.scss";
import ProjectCreateModal from "../components/ProjectCreateModal";
import ProjectDetail from "../components/ProjectDetail";

function FolderIcon({ color }: { color?: string }) {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" fill={color ?? "currentColor"} stroke="none" style={{ flexShrink: 0 }}>
      <path d="M22 19a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h5l2 3h9a2 2 0 0 1 2 2z" />
    </svg>
  );
}

export default function Projects() {
  useDocumentTitle("Projects");
  const { user: me } = useAuth();
  const { projectId } = useParams<{ projectId?: string }>();
  const navigate = useNavigate();

  const [projects, setProjects] = useState<ChatProject[]>([]);
  const [tenants, setTenants] = useState<Tenant[]>([]);
  const [gateways, setGateways] = useState<Gateway[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [showCreate, setShowCreate] = useState(false);

  const isAdmin = me?.role === "admin";
  // For admins without a personal tenant, fall back to first loaded tenant.
  const effectiveTenantId = me?.tenant_id ?? (isAdmin ? tenants[0]?.id : undefined);

  useEffect(() => {
    if (isAdmin && !effectiveTenantId) return; // wait for tenants to load
    const params = isAdmin && effectiveTenantId ? `?tenant_id=${effectiveTenantId}` : "";
    api.get<ChatProject[]>(`/projects${params}`)
      .then(setProjects)
      .catch((e) => setError(String(e)))
      .finally(() => setLoading(false));
  }, [isAdmin, effectiveTenantId]);

  useEffect(() => {
    api.get<Tenant[]>("/tenants").then(setTenants).catch(() => {});
  }, []);

  // Load gateways for the effective tenant so the create modal can show them.
  useEffect(() => {
    if (!effectiveTenantId) return;
    api.get<Gateway[]>(`/tenants/${effectiveTenantId}/gateways`).then(setGateways).catch(() => {});
  }, [effectiveTenantId]);

  function handleCreated(proj: ChatProject) {
    setProjects((prev) => [proj, ...prev]);
    setShowCreate(false);
    navigate(`/projects/${proj.id}`);
  }

  function handleUpdated(proj: ChatProject) {
    setProjects((prev) => prev.map((p) => p.id === proj.id ? proj : p));
  }

  function handleDeleted(id: string) {
    setProjects((prev) => prev.filter((p) => p.id !== id));
    navigate("/projects");
  }

  const canCreate = me?.role === "admin" || me?.role === "tenant_admin";

  if (loading) {
    return (
      <div className={s.page}>
        <div className={s["page-header"]}>
          <h1 className={s["page-title"]}>Projects</h1>
        </div>
        <div className={s.empty}>Loading…</div>
      </div>
    );
  }

  if (projectId) {
    const proj = projects.find((p) => p.id === projectId) ?? null;
    return (
      <ProjectDetail
        projectId={projectId}
        initialProject={proj}
        gateways={gateways}
        tenants={tenants}
        onUpdated={handleUpdated}
        onDeleted={() => handleDeleted(projectId)}
        onBack={() => navigate("/projects")}
      />
    );
  }

  return (
    <div className={s.page}>
      <div className={s["page-header"]}>
        <h1 className={s["page-title"]}>Projects</h1>
        {canCreate && (
          <button
            className={`${s.btn} ${s["btn--primary"]}`}
            onClick={() => setShowCreate(true)}
            data-cy="create-project-btn"
          >
            + New Project
          </button>
        )}
      </div>

      {error && <div className={`${s.alert} ${s["alert--error"]}`}>{error}</div>}

      {projects.length === 0 ? (
        <div className={s.empty}>
          <p style={{ margin: "0 0 16px" }}>No projects yet.</p>
          {canCreate && (
            <button className={`${s.btn} ${s["btn--primary"]}`} onClick={() => setShowCreate(true)}>
              + Create your first project
            </button>
          )}
        </div>
      ) : (
        <div className={s["table-wrapper"]}>
          <table className={s.table} data-cy="projects-table">
            <thead>
              <tr>
                {["Project", "Description", "Members", "Files", "Role", "Updated"].map((h) => (
                  <th key={h}>{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {projects.map((p) => (
                <tr
                  key={p.id}
                  onClick={() => navigate(`/projects/${p.id}`)}
                  style={{ cursor: "pointer" }}
                  data-cy={`project-row-${p.id}`}
                >
                  <td>
                    <span style={{ display: "inline-flex", alignItems: "center", gap: 8 }}>
                      <FolderIcon color={p.color} />
                      <strong style={{ fontWeight: 500 }}>{p.icon} {p.name}</strong>
                    </span>
                  </td>
                  <td style={{ color: "var(--text-secondary)" }}>
                    {p.description ? p.description.slice(0, 60) + (p.description.length > 60 ? "…" : "") : "—"}
                  </td>
                  <td>{p.member_count ?? 0}</td>
                  <td>{p.knowledge_count ?? 0}</td>
                  <td>
                    {(p.my_role ?? (isAdmin ? "admin" : null)) && (
                      <span className={`${s.badge} ${s["badge--neutral"]}`}>
                        {p.my_role ?? "admin"}
                      </span>
                    )}
                  </td>
                  <td style={{ color: "var(--text-secondary)", whiteSpace: "nowrap" }}>
                    {new Date(p.updated_at).toLocaleDateString()}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {showCreate && (
        <ProjectCreateModal
          tenants={tenants}
          gateways={gateways}
          defaultTenantId={me?.tenant_id ?? tenants[0]?.id ?? ""}
          onCreated={handleCreated}
          onClose={() => setShowCreate(false)}
        />
      )}
    </div>
  );
}
