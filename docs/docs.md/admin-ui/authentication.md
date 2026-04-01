---
title: Logging in
description: How to log in to the AI Gateway admin panel using Google SSO or email OTP, and how sessions work.
---

# Logging in

![View: Login](../assets/screenshots/login-page.png)
*View: Login*

The admin panel is protected by a stateless JWT session cookie. Two login methods are available: **Google SSO** and **email one-time code (OTP)**. The login page is accessible at `/login`. The system redirects you to this page automatically when you access a protected page without a valid session.

Any user account in the system can log in to the admin panel, regardless of role. Accounts are not created automatically on first login — an administrator must create your account in advance. See [User management](users.md) for details.

---

## Session duration

After a successful login, the system creates a secure session.

| Login method | Default session duration | With **Stay logged in** |
|---|---|---|
| Email OTP | 8 hours | 30 days |
| Google SSO | 8 hours | — |

When your session expires, the system redirects you to the login page. If you navigate to the login page while already holding a valid session, the system redirects you to the dashboard immediately.

---

## Role model

| Role | Access |
|---|---|
| `admin` | Full platform — all tenants, gateways, users |
| `tenant_admin` | Own tenant — manages users, gateways, and settings within their tenant |
| `member` | Own tenant — full access to gateways within their tenant; can create inference tokens via [My tokens](my-tokens.md) |
| `viewer` | Own tenant — read-only access to the admin panel; cannot make inference requests |

---

## Logging in with Google SSO

Before you begin, ensure the following conditions are met:

- ☑ Your email address already exists as a user in the system. Contact your administrator if you do not have access.

► Proceed as follows to log in with Google SSO:

1. Navigate to `/login`.
2. Click the **Continue with Google** button.
   ⇒ The system redirects you to Google's consent screen.
3. Authenticate with your Google account.

→ The system returns you to the dashboard.

---

## Logging in with email OTP

Before you begin, ensure the following conditions are met:

- ☑ Your email address already exists as a user in the system.

► Proceed as follows to log in with an email one-time code:

1. Navigate to `/login`.
2. Click the **Continue with Email code** button.
3. Enter your email address in the **Email** text field.
4. If required, check **Stay logged in for 30 days on this device** to extend your session to 30 days.
5. Click the **Send code** button.
   ⇒ The system sends a 6-digit code to your email address. The code expires after 15 minutes and can only be used once.
6. Enter the code in the **One-time code** text field.
7. Click the **Verify** button.

→ The system creates your session and redirects you to the dashboard.
