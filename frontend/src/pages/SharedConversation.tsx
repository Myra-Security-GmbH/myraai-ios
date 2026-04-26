/**
 * SharedConversation.tsx — Public read-only view of a shared conversation.
 * No authentication required. Accessible at /share/:token.
 *
 * Shows the conversation title and messages (read-only).
 * Authenticated users see a "Continue this conversation" button that
 * forks the shared conversation into their own account.
 */

import { useEffect, useState } from "react";
import { useParams, useNavigate } from "react-router-dom";
import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";

const SHARE_BASE = import.meta.env.VITE_ADMIN_URL
  ? import.meta.env.VITE_ADMIN_URL.replace(/\/admin\/v1$/, "")
  : "";

interface SharedMessage {
  id: string;
  role: "user" | "assistant" | "system";
  content: string;
  created_at: string;
}

interface SharedSnapshot {
  title: string;
  messages: SharedMessage[];
}

export default function SharedConversation() {
  const { token } = useParams<{ token: string }>();
  const navigate = useNavigate();
  const [snapshot, setSnapshot] = useState<SharedSnapshot | null>(null);
  const [notFound, setNotFound] = useState(false);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    if (!token) { setNotFound(true); setLoading(false); return; }
    fetch(`${SHARE_BASE}/share/${token}`)
      .then(async r => {
        if (r.status === 404) { setNotFound(true); return; }
        const data = await r.json();
        setSnapshot(data);
      })
      .catch(() => setNotFound(true))
      .finally(() => setLoading(false));
  }, [token]);

  async function continueConversation() {
    // Try to detect if user is logged in by calling /me
    const adminBase = import.meta.env.VITE_ADMIN_URL ?? "/admin/v1";
    try {
      const meResp = await fetch(`${adminBase.replace(/\/v1$/, "/auth")}/me`, {
        credentials: "include",
      });
      if (!meResp.ok) {
        // Not logged in — redirect to login
        navigate(`/login?next=${encodeURIComponent(window.location.pathname)}`);
        return;
      }
      // Get first available gateway
      const gwResp = await fetch(`${adminBase}/tenants`, { credentials: "include" });
      if (!gwResp.ok) { navigate("/login"); return; }
      const tenants = await gwResp.json() as Array<{ id: string }>;
      let gatewayId: string | null = null;
      for (const t of tenants) {
        const gr = await fetch(`${adminBase}/tenants/${t.id}/gateways`, { credentials: "include" });
        if (!gr.ok) continue;
        const gws = await gr.json() as Array<{ id: string }>;
        if (gws.length) { gatewayId = gws[0].id; break; }
      }
      if (!gatewayId) { alert("No gateway available for forking."); return; }
      const forkResp = await fetch(`${adminBase}/conversations`, {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ source_share_token: token, gateway_id: gatewayId }),
      });
      if (!forkResp.ok) { alert("Failed to fork conversation."); return; }
      const conv = await forkResp.json() as { id: string };
      navigate(`/chat?conv=${conv.id}`);
    } catch {
      navigate("/login");
    }
  }

  if (loading) {
    return (
      <div style={containerStyle}>
        <p style={{ color: "var(--text-secondary, #666)" }}>Loading…</p>
      </div>
    );
  }

  if (notFound || !snapshot) {
    return (
      <div style={containerStyle}>
        <h2 style={{ color: "var(--text-primary, #111)", marginBottom: 8 }}>Not found</h2>
        <p style={{ color: "var(--text-secondary, #666)" }}>
          This conversation is no longer shared.
        </p>
      </div>
    );
  }

  return (
    <div style={containerStyle}>
      <div style={headerStyle}>
        <h1 style={{ margin: 0, fontSize: 22, fontWeight: 700, color: "var(--text-primary, #111)" }}>
          {snapshot.title}
        </h1>
        <button
          onClick={continueConversation}
          data-cy="continue-conversation-btn"
          style={continueStyle}
        >
          Continue this conversation →
        </button>
      </div>

      <div style={threadStyle}>
        {(snapshot.messages || []).filter(m => m.role !== "system").map(m => (
          <div key={m.id} style={bubbleRowStyle(m.role)}>
            <div style={avatarStyle(m.role)}>
              {m.role === "user" ? "U" : "AI"}
            </div>
            <div style={bubbleStyle(m.role)}>
              <ReactMarkdown remarkPlugins={[remarkGfm]}>
                {m.content}
              </ReactMarkdown>
            </div>
          </div>
        ))}
      </div>

      <div style={{ textAlign: "center", marginTop: 32 }}>
        <button
          onClick={continueConversation}
          data-cy="continue-conversation-btn-bottom"
          style={continueStyle}
        >
          Continue this conversation →
        </button>
      </div>
    </div>
  );
}

// ── Inline styles ──────────────────────────────────────────────────────────

const containerStyle: React.CSSProperties = {
  maxWidth: 860,
  margin: "0 auto",
  padding: "40px 24px 80px",
  fontFamily: "inherit",
};

const headerStyle: React.CSSProperties = {
  display: "flex",
  alignItems: "center",
  justifyContent: "space-between",
  gap: 16,
  marginBottom: 32,
  flexWrap: "wrap",
};

const threadStyle: React.CSSProperties = {
  display: "flex",
  flexDirection: "column",
  gap: 4,
};

function bubbleRowStyle(role: string): React.CSSProperties {
  return {
    display: "flex",
    padding: "6px 0",
    gap: 12,
    flexDirection: role === "user" ? "row-reverse" : "row",
  };
}

function avatarStyle(role: string): React.CSSProperties {
  return {
    width: 28,
    height: 28,
    borderRadius: "50%",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    fontSize: 10,
    fontWeight: 700,
    flexShrink: 0,
    marginTop: 6,
    background: role === "user" ? "var(--section-bg)" : "none",
    color: role === "user" ? "var(--text-primary)" : "var(--accent)",
    border: role === "user" ? "1px solid var(--card-border)" : "none",
  };
}

function bubbleStyle(role: string): React.CSSProperties {
  return {
    flex: 1,
    minWidth: 0,
    fontSize: 15,
    lineHeight: 1.65,
    color: "var(--text-primary, #111)",
    maxWidth: role === "user" ? "78%" : undefined,
    background: role === "user" ? "var(--section-bg)" : "transparent",
    border: role === "user" ? "1px solid var(--card-border)" : "none",
    borderRadius: role === "user" ? "18px 18px 4px 18px" : 0,
    padding: role === "user" ? "10px 14px" : "2px 0",
  };
}

const continueStyle: React.CSSProperties = {
  padding: "8px 16px",
  fontSize: 14,
  fontWeight: 500,
  background: "var(--accent)",
  color: "var(--btn-primary-text, #fff)",
  border: "none",
  borderRadius: 6,
  cursor: "pointer",
};
