/**
 * login.spec.ts — E2E tests for the admin panel authentication flow.
 *
 * Covers: redirect to /login, email OTP request, OTP verify, session
 * persistence via /me, wrong code, expired code, replay, and logout.
 *
 * Run with:
 *   cd frontend && npx playwright test tests/login.spec.ts --project=chromium
 */

import { test, expect, BrowserContext } from "@playwright/test";
import { execSync } from "child_process";

const DB    = "/opt/ai-gateway/data/config.db";
const EMAIL = "sascha@schumann.net";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function insertOTP(code: string, offsetSecs = 900): string {
  const hash   = execSync(`echo -n '${code}' | sha256sum | awk '{print $1}'`).toString().trim();
  const expiry = Math.floor(Date.now() / 1000) + offsetSecs;
  const id     = execSync("cat /proc/sys/kernel/random/uuid").toString().trim();
  execSync(`sqlite3 ${DB} "DELETE FROM email_otp WHERE email='${EMAIL}' AND used_at IS NULL;"`);
  execSync(`sqlite3 ${DB} "INSERT INTO email_otp (id, email, code_hash, expires_at, ip_addr) VALUES ('${id}', '${EMAIL}', '${hash}', ${expiry}, '127.0.0.1');"`);
  return id;
}

// Intercept the OTP request endpoint so no actual email is sent.
// The OTP is pre-inserted into the DB by insertOTP(), so the real verify
// call still hits the backend end-to-end.
async function doOTPLogin(context: BrowserContext, code: string) {
  const page = await context.newPage();
  await page.route("**/admin/auth/otp/request", route =>
    route.fulfill({ status: 200, contentType: "application/json",
                    body: JSON.stringify({ message: "Code sent (intercepted by test)" }) })
  );
  await page.goto("/login");
  await page.getByText("Continue with Email code").click();
  await page.getByLabel("Email address").fill(EMAIL);
  await page.getByRole("button", { name: "Send code" }).click();
  await expect(page.getByLabel("6-digit code")).toBeVisible();
  await page.getByLabel("6-digit code").fill(code);
  await page.getByRole("button", { name: "Sign in" }).click();
  return page;
}

// ---------------------------------------------------------------------------
// Unauthenticated redirects  (no storageState — fresh browser context)
// ---------------------------------------------------------------------------

test.describe("unauthenticated redirects", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("GET / redirects to /login when no session", async ({ page }) => {
    await page.goto("/");
    await expect(page).toHaveURL(/\/login/);
  });

  test("GET /dashboard redirects to /login when no session", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page).toHaveURL(/\/login/);
  });

  test("login page renders all three steps", async ({ page }) => {
    await page.goto("/login");
    await expect(page.getByText("Sign in to AI Gateway")).toBeVisible();
    await expect(page.getByText("Continue with Google")).toBeVisible();
    await expect(page.getByText("Continue with Email code")).toBeVisible();
  });

  test("clicking email button shows email input step", async ({ page }) => {
    await page.goto("/login");
    await page.getByText("Continue with Email code").click();
    await expect(page.getByLabel("Email address")).toBeVisible();
    await expect(page.getByRole("button", { name: "Send code" })).toBeVisible();
  });

  test("back button returns to choose step", async ({ page }) => {
    await page.goto("/login");
    await page.getByText("Continue with Email code").click();
    await page.getByRole("button", { name: /← Back/ }).click();
    await expect(page.getByText("Continue with Email code")).toBeVisible();
  });
});

// ---------------------------------------------------------------------------
// OTP request  (no storageState — fresh browser context)
// ---------------------------------------------------------------------------

test.describe("OTP request", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("returns generic message for unknown email (anti-enumeration)", async ({ page }) => {
    await page.goto("/login");
    await page.getByText("Continue with Email code").click();
    await page.getByLabel("Email address").fill("nobody@example.com");
    await page.getByRole("button", { name: "Send code" }).click();
    // Same message regardless — should still advance to code step
    await expect(page.getByLabel("6-digit code")).toBeVisible({ timeout: 5000 });
  });

  test("advances to code step for registered email", async ({ page }) => {
    await page.goto("/login");
    await page.getByText("Continue with Email code").click();
    await page.getByLabel("Email address").fill(EMAIL);
    await page.getByRole("button", { name: "Send code" }).click();
    await expect(page.getByLabel("6-digit code")).toBeVisible({ timeout: 5000 });
    await expect(page.getByText(EMAIL)).toBeVisible();
  });
});

// ---------------------------------------------------------------------------
// OTP verify — success and failure paths  (fresh context, insert OTP in DB)
// ---------------------------------------------------------------------------

test.describe("OTP verify", () => {
  test.use({ storageState: { cookies: [], origins: [] } });

  test("wrong code shows error, stays on login", async ({ context }) => {
    insertOTP("777111");
    const page = await doOTPLogin(context, "000000");  // wrong code
    // Error banner should appear, still on /login
    await expect(page.getByText(/invalid|expired|error/i)).toBeVisible({ timeout: 5000 });
    await expect(page).toHaveURL(/\/login/);
  });

  test("correct code logs in and redirects to dashboard", async ({ context }) => {
    insertOTP("654321");
    const page = await doOTPLogin(context, "654321");
    await expect(page).toHaveURL(/\/(dashboard|$)/, { timeout: 10000 });
    await expect(page.locator("nav, aside")).toBeVisible();
  });

  test("session persists: /me returns user after login", async ({ context }) => {
    insertOTP("543210");
    const page = await doOTPLogin(context, "543210");
    await expect(page).toHaveURL(/\/(dashboard|$)/, { timeout: 10000 });

    // Call /me directly — should return the logged-in user
    const res  = await page.request.get("/admin/auth/me");
    expect(res.status()).toBe(200);
    const body = await res.json();
    expect(body.email).toBe(EMAIL);
    expect(body.role).toBe("admin");
  });

  test("replay attack: same code rejected on second use", async ({ context }) => {
    insertOTP("111222");

    // First login succeeds
    const page1 = await doOTPLogin(context, "111222");
    await expect(page1).toHaveURL(/\/(dashboard|$)/, { timeout: 10000 });

    // Second attempt with same code — start fresh page (no session cookie)
    const page2 = await context.newPage();
    await page2.route("**/admin/auth/otp/request", route =>
      route.fulfill({ status: 200, contentType: "application/json",
                      body: JSON.stringify({ message: "Code sent (intercepted by test)" }) })
    );
    await page2.goto("/login");
    await page2.getByText("Continue with Email code").click();
    await page2.getByLabel("Email address").fill(EMAIL);
    await page2.getByRole("button", { name: "Send code" }).click();
    await expect(page2.getByLabel("6-digit code")).toBeVisible();
    await page2.getByLabel("6-digit code").fill("111222");
    await page2.getByRole("button", { name: "Sign in" }).click();

    await expect(page2.getByText(/invalid|expired|error/i)).toBeVisible({ timeout: 5000 });
  });

  test("expired OTP is rejected", async ({ context }) => {
    insertOTP("333444", -1);  // already expired
    const page = await doOTPLogin(context, "333444");
    await expect(page.getByText(/invalid|expired|error/i)).toBeVisible({ timeout: 5000 });
    await expect(page).toHaveURL(/\/login/);
  });
});

// ---------------------------------------------------------------------------
// Logout  (uses saved session from auth.setup.ts)
// ---------------------------------------------------------------------------

test.describe("logout", () => {
  test("logout clears session and redirects to /login", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page).toHaveURL(/\/dashboard/);

    // Click the logout button in sidebar
    await page.getByRole("button", { name: /log.?out|sign.?out/i }).click();
    await expect(page).toHaveURL(/\/login/, { timeout: 5000 });

    // Verify session is gone: /me should return 401
    const res = await page.request.get("/admin/auth/me");
    expect(res.status()).toBe(401);
  });

  test("after logout, protected routes redirect to /login", async ({ page }) => {
    await page.goto("/dashboard");
    await page.getByRole("button", { name: /log.?out|sign.?out/i }).click();
    await expect(page).toHaveURL(/\/login/, { timeout: 5000 });

    await page.goto("/tenants");
    await expect(page).toHaveURL(/\/login/);
  });
});
