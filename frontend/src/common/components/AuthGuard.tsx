import { useEffect } from "react";
import { useNavigate } from "react-router-dom";
import { useAuth } from "src/common/contexts/AuthContext";

/** Wraps all protected routes. Redirects to /login if no session. */
export default function AuthGuard({ children }: { children: React.ReactNode }) {
  const { user, loading } = useAuth();
  const navigate = useNavigate();

  useEffect(() => {
    if (!loading && !user) {
      navigate("/login", { replace: true });
    }
  }, [loading, user, navigate]);

  if (loading) {
    return (
      <div style={{ display: "flex", alignItems: "center", justifyContent: "center", minHeight: "100vh" }}>
        <span style={{ color: "var(--text-muted, #888)", fontSize: 14 }}>Loading…</span>
      </div>
    );
  }

  if (!user) return null;

  return <>{children}</>;
}
