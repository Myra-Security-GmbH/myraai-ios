import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { authApi } from "src/api/client";
import { useAuth } from "src/common/contexts/AuthContext";

type Step = "choose" | "email-input" | "code-input";

function friendlyError(raw: string): string {
  if (raw.includes("invalid or expired")) return "That code is incorrect or has expired. Please request a new one.";
  if (raw === "forbidden")                return "This email is not authorised to access the admin panel.";
  if (raw === "email required")           return "Please enter your email address.";
  if (raw === "email and code required")  return "Please enter your email and the 6-digit code.";
  if (raw === "internal error")           return "Something went wrong. Please try again later.";
  if (raw.toLowerCase().includes("network") || raw.toLowerCase().includes("failed to fetch"))
                                          return "Could not reach the server. Check your connection and try again.";
  return "Something went wrong. Please try again later.";
}

export default function LoginPage() {
  const navigate  = useNavigate();
  const { login } = useAuth();
  const [step, setStep]     = useState<Step>("choose");
  const [email, setEmail]   = useState("");
  const [code, setCode]     = useState("");
  const [loading, setLoading] = useState(false);
  const [error, setError]   = useState<string | null>(null);
  const [info, setInfo]     = useState<string | null>(null);

  async function handleRequestOTP(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true); setError(null);
    try {
      const res = await authApi.otpRequest(email);
      setInfo(res.message);
      setStep("code-input");
    } catch (err: any) {
      setError(friendlyError(err.message ?? ""));
    } finally {
      setLoading(false);
    }
  }

  async function handleVerifyOTP(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true); setError(null);
    try {
      const res = await authApi.otpVerify(email, code);
      login(res.user);
      navigate("/", { replace: true });
    } catch (err: any) {
      setError(friendlyError(err.message ?? ""));
    } finally {
      setLoading(false);
    }
  }

  return (
    <div style={styles.page}>
      <div style={styles.card}>
        <div style={styles.logo}>
          <img src="/logo.svg" alt="AI Gateway" style={styles.logoImg} />
        </div>

        <h1 style={styles.title}>Sign in to AI Gateway</h1>

        {error && <div style={styles.error}>{error}</div>}
        {info  && <div style={styles.info}>{info}</div>}

        {step === "choose" && (
          <div style={styles.methods}>
            {/* Google SSO */}
            <a href="/admin/auth/google" style={styles.googleBtn}>
              <GoogleIcon />
              Continue with Google
            </a>

            <div style={styles.divider}><span>or</span></div>

            {/* Email OTP */}
            <button style={styles.emailBtn} onClick={() => setStep("email-input")}>
              Continue with Email code
            </button>
          </div>
        )}

        {step === "email-input" && (
          <form onSubmit={handleRequestOTP} style={styles.form}>
            <label htmlFor="login-email" style={styles.label}>Email address</label>
            <input
              id="login-email"
              type="email"
              value={email}
              onChange={e => setEmail(e.target.value)}
              placeholder="admin@example.com"
              required
              autoFocus
              style={styles.input}
            />
            <button type="submit" disabled={loading} style={styles.primaryBtn}>
              {loading ? "Sending…" : "Send code"}
            </button>
            <button type="button" style={styles.linkBtn} onClick={() => setStep("choose")}>
              ← Back
            </button>
          </form>
        )}

        {step === "code-input" && (
          <form onSubmit={handleVerifyOTP} style={styles.form}>
            <label htmlFor="login-code" style={styles.label}>6-digit code</label>
            <p style={styles.hint}>We sent a code to <strong>{email}</strong></p>
            <input
              id="login-code"
              type="text"
              inputMode="numeric"
              pattern="[0-9]{6}"
              maxLength={6}
              value={code}
              onChange={e => setCode(e.target.value.replace(/\D/g, "").slice(0, 6))}
              placeholder="123456"
              required
              autoFocus
              style={{ ...styles.input, letterSpacing: "0.3em", fontSize: 22, textAlign: "center" }}
            />
            <button type="submit" disabled={loading || code.length !== 6} style={styles.primaryBtn}>
              {loading ? "Verifying…" : "Sign in"}
            </button>
            <button type="button" style={styles.linkBtn} onClick={() => { setStep("email-input"); setCode(""); setInfo(null); }}>
              ← Back
            </button>
          </form>
        )}
      </div>
    </div>
  );
}

function GoogleIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" style={{ flexShrink: 0 }}>
      <path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"/>
      <path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"/>
      <path fill="#FBBC05" d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"/>
      <path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"/>
    </svg>
  );
}

const styles: Record<string, React.CSSProperties> = {
  page: {
    minHeight: "100dvh",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    background: "var(--bg, #f5f5f5)",
    padding: 16,
  },
  card: {
    background: "var(--card-bg, #fff)",
    border: "1px solid var(--border, #e5e7eb)",
    borderRadius: 12,
    padding: "40px 36px",
    width: "100%",
    maxWidth: 400,
    boxShadow: "0 4px 24px rgba(0,0,0,.06)",
  },
  logo: {
    display: "flex",
    justifyContent: "center",
    marginBottom: 24,
  },
  logoImg: {
    height: 36,
    background: "#1B3A5C",
    padding: "8px 16px",
    borderRadius: 8,
  },
  title: {
    fontSize: 20,
    fontWeight: 600,
    textAlign: "center",
    margin: "0 0 24px",
    color: "var(--text, #111)",
  },
  methods: {
    display: "flex",
    flexDirection: "column",
    gap: 12,
  },
  googleBtn: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    gap: 10,
    padding: "10px 16px",
    borderRadius: 8,
    border: "1px solid var(--border, #e5e7eb)",
    background: "var(--card-bg, #fff)",
    color: "var(--text, #111)",
    fontSize: 14,
    fontWeight: 500,
    textDecoration: "none",
    cursor: "pointer",
    transition: "background .15s",
  },
  divider: {
    display: "flex",
    alignItems: "center",
    gap: 8,
    color: "var(--text-muted, #888)",
    fontSize: 12,
  },
  emailBtn: {
    padding: "10px 16px",
    borderRadius: 8,
    border: "1px solid var(--border, #e5e7eb)",
    background: "transparent",
    color: "var(--text, #111)",
    fontSize: 14,
    fontWeight: 500,
    cursor: "pointer",
  },
  form: {
    display: "flex",
    flexDirection: "column",
    gap: 12,
  },
  label: {
    fontSize: 13,
    fontWeight: 500,
    color: "var(--text, #111)",
    marginBottom: -4,
  },
  hint: {
    fontSize: 13,
    color: "var(--text-muted, #888)",
    margin: 0,
  },
  input: {
    padding: "10px 12px",
    borderRadius: 8,
    border: "1px solid var(--border, #e5e7eb)",
    fontSize: 15,
    outline: "none",
    width: "100%",
    boxSizing: "border-box",
    background: "var(--input-bg, #fff)",
    color: "var(--text, #111)",
  },
  primaryBtn: {
    padding: "10px 16px",
    borderRadius: 8,
    border: "none",
    background: "var(--primary, #2563eb)",
    color: "#fff",
    fontSize: 14,
    fontWeight: 500,
    cursor: "pointer",
    marginTop: 4,
  },
  linkBtn: {
    padding: "6px 0",
    background: "none",
    border: "none",
    color: "var(--text-muted, #888)",
    fontSize: 13,
    cursor: "pointer",
    textAlign: "left",
  },
  error: {
    background: "rgba(239,68,68,.08)",
    color: "#dc2626",
    border: "1px solid rgba(239,68,68,.2)",
    borderRadius: 8,
    padding: "10px 12px",
    fontSize: 13,
    marginBottom: 12,
  },
  info: {
    background: "rgba(34,197,94,.08)",
    color: "#16a34a",
    border: "1px solid rgba(34,197,94,.2)",
    borderRadius: 8,
    padding: "10px 12px",
    fontSize: 13,
    marginBottom: 12,
  },
};
