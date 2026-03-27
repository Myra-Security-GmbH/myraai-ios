# Admin Panel Authentication

The admin panel (`/admin/*`) is protected by a stateless JWT session cookie. Two login methods are supported: **Google SSO** and **Email one-time code (OTP)**.

---

## Login page

Navigate to `http://<your-gateway>/login`. You will be redirected here automatically if you access a protected page without a valid session.

![Login page](../assets/screenshots/login-page.png)

---

## Google SSO

Click **Continue with Google**. You will be redirected to Google's consent screen and returned to the dashboard on success.

**Requirements:**
- The gateway must be configured with `AIG_GOOGLE_CLIENT_ID` and `AIG_GOOGLE_CLIENT_SECRET`
- Your email must already exist as a user in the database (users are not auto-provisioned on first SSO login)

**Environment variables:**

| Variable | Description |
|---|---|
| `AIG_GOOGLE_CLIENT_ID` | OAuth 2.0 client ID from Google Cloud Console |
| `AIG_GOOGLE_CLIENT_SECRET` | OAuth 2.0 client secret |
| `AIG_GOOGLE_REDIRECT_URI` | Callback URL (default: `http://localhost:8081/admin/auth/google/callback`) |

In Google Cloud Console, add the redirect URI to the list of **Authorised redirect URIs** for your OAuth 2.0 credential.

---

## Email OTP

Click **Continue with Email code**, enter your email address, and wait for a 6-digit code. The code expires in **15 minutes** and can only be used once.

The code is delivered by email to the address you entered.

Before clicking **Send code**, you can check **Stay logged in for 30 days on this device**. When checked, your session remains active for 30 days instead of the default 8 hours.

---

## Session

After a successful login, a secure session is created.

| Login method | Default session duration | With **Stay logged in** |
|---|---|---|
| Email OTP | 8 hours | 30 days |
| Google SSO | 8 hours | — |

You will be redirected to the login page automatically when your session expires. If you are already logged in and navigate to the login page, you are redirected to the dashboard immediately.

---

## Role model

| Role | Access |
|---|---|
| `admin` | Full platform — all tenants, gateways, users |
| `tenant_admin` | Own tenant — manages users, gateways, and settings within their tenant |
| `member` | Own tenant — full access to gateways within their tenant; can create their own inference tokens via [My Tokens](my-tokens.md) |
| `viewer` | Own tenant — read-only access to the admin panel; cannot make inference requests |

Any user in the database can log in to the admin panel regardless of role. Create users via **Users → New User** or the [Users API](../api-reference/users-tokens.md).

---

## API reference

| Method | Path | Description |
|---|---|---|
| `GET` | `/admin/auth/me` | Return current user from JWT (used by frontend on load) |
| `POST` | `/admin/auth/logout` | Expire the session cookie |
| `POST` | `/admin/auth/otp/request` | Send 6-digit OTP to email |
| `POST` | `/admin/auth/otp/verify` | Verify OTP; set session cookie. Pass `remember_me: true` in the request body to request a 30-day session. |
| `GET` | `/admin/auth/google` | Start Google OAuth flow |
| `GET` | `/admin/auth/google/callback` | OAuth callback; set session cookie |
