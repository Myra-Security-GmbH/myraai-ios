import { useState, useEffect } from "react";
import { useNavigate } from "react-router-dom";
import { getCyDataId } from "@myraui/utils";
import { authApi } from "src/api/client";
import { useAuth } from "src/common/contexts/AuthContext";
import s from "./LoginPage.module.scss";

const cyId = getCyDataId("login-page");

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
  const { user, loading, login } = useAuth();

  // Already authenticated — forward immediately
  useEffect(() => {
    if (!loading && user) navigate("/", { replace: true });
  }, [loading, user]);
  const [step, setStep]         = useState<Step>("choose");
  const [email, setEmail]       = useState("");
  const [code, setCode]         = useState("");
  const [rememberMe, setRememberMe] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError]           = useState<string | null>(null);
  const [info, setInfo]             = useState<string | null>(null);

  async function handleRequestOTP(e: React.FormEvent) {
    e.preventDefault();
    setSubmitting(true); setError(null);
    try {
      const res = await authApi.otpRequest(email);
      setInfo(res.message);
      setStep("code-input");
    } catch (err: any) {
      setError(friendlyError(err.message ?? ""));
    } finally {
      setSubmitting(false);
    }
  }

  async function handleVerifyOTP(e: React.FormEvent) {
    e.preventDefault();
    setSubmitting(true); setError(null);
    try {
      const res = await authApi.otpVerify(email, code, rememberMe);
      login(res.user);
      navigate("/", { replace: true });
    } catch (err: any) {
      setError(friendlyError(err.message ?? ""));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className={s.page}>
      <div className={s.card}>
        <div className={s.logo}>
          <img src="/logo.svg" alt="AI Gateway" className={s["logo-img"]} />
        </div>

        <h1 className={s.title}>Sign in to AI Gateway</h1>

        {error && <div className={s.error}>{error}</div>}
        {info  && <div className={s.info}>{info}</div>}

        {step === "choose" && (
          <div className={s.methods}>
            {/* Google SSO — temporarily hidden */}
            {/* <a href="/admin/auth/google" className={s["google-btn"]}>
              <GoogleIcon />
              Continue with Google
            </a>

            <div className={s.divider}><span>or</span></div> */}

            {/* Email OTP */}
            <button className={s["email-btn"]} onClick={() => setStep("email-input")} data-cy={cyId("email-btn")}>
              Continue with Email code
            </button>
          </div>
        )}

        {step === "email-input" && (
          <form onSubmit={handleRequestOTP} className={s.form}>
            <label htmlFor="login-email" className={s.label}>Email address</label>
            <input
              id="login-email"
              type="email"
              value={email}
              onChange={e => setEmail(e.target.value)}
              placeholder="admin@example.com"
              required
              autoFocus
              className={s.input}
              data-cy={cyId("email-input")}
            />
            <label className={s["remember-label"]}>
              <input
                type="checkbox"
                checked={rememberMe}
                onChange={e => setRememberMe(e.target.checked)}
              />
              Stay logged in for 30 days on this device
            </label>
            <button type="submit" disabled={submitting} className={s["primary-btn"]} data-cy={cyId("send-code-btn")}>
              {submitting ? "Sending…" : "Send code"}
            </button>
            <button type="button" className={s["link-btn"]} onClick={() => setStep("choose")}>
              ← Back
            </button>
          </form>
        )}

        {step === "code-input" && (
          <form onSubmit={handleVerifyOTP} className={s.form}>
            <label htmlFor="login-code" className={s.label}>6-digit code</label>
            <p className={s.hint}>We sent a code to <strong>{email}</strong></p>
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
              className={s["code-input"]}
              data-cy={cyId("code-input")}
            />
            <button type="submit" disabled={submitting || code.length !== 6} className={s["primary-btn"]} data-cy={cyId("sign-in-btn")}>
              {submitting ? "Verifying…" : "Sign in"}
            </button>
            <button type="button" className={s["link-btn"]} onClick={() => { setStep("email-input"); setCode(""); setInfo(null); }}>
              ← Back
            </button>
          </form>
        )}

        <AndroidBuildBadge />

        <p style={{ textAlign: "center", fontSize: 12, margin: "16px 0 0" }}>
          <a
            href="https://ai.myra.eu/privacy"
            target="_blank"
            rel="noopener noreferrer"
            style={{ color: "var(--text-muted, #8899aa)", textDecoration: "underline" }}
            data-cy={cyId("privacy-link")}
          >
            Privacy Policy
          </a>
        </p>
      </div>
    </div>
  );
}

function AndroidBuildBadge() {
  const match = navigator.userAgent.match(/MYRAai-Android\/([\d.]+)/);
  if (!match) return null;
  const versionName = match[1];
  const vcMatch = navigator.userAgent.match(/MYRAai-Android\/[\d.]+ \((\d+)\)/);
  const label = vcMatch ? `Android ${versionName} (${vcMatch[1]})` : `Android ${versionName}`;
  return (
    <p style={{ textAlign: "center", fontSize: 11, color: "var(--text-muted, #aaa)", margin: "16px 0 0", letterSpacing: "0.02em" }}>
      {label}
    </p>
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
