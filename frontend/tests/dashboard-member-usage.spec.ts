/**
 * dashboard-member-usage.spec.ts — verifies that member/viewer role users
 * see their own usage on the /dashboard page (not a 403 blank screen), and
 * that admin-only sections are hidden for them.
 *
 * Tests use a temp member user created in the worker's isolated tenant,
 * authenticated via OTP (same pattern as projects.spec.ts permission tests).
 */

import { test, expect, type Page, type Browser } from "./base";
import { execSync } from "child_process";

const ADMIN_BASE = (process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173") + "/admin/v1";
const AUTH_BASE  = (process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173") + "/admin/auth";
const DB_HOST    = process.env.E2E_DB_HOST ?? "172.17.0.1";
const DB_USER    = process.env.E2E_DB_USER ?? "gateway";
const DB_PASS    = process.env.E2E_DB_PASS ?? "gateway";
const DB_NAME    = process.env.E2E_DB_NAME ?? "ai_gateway";
const OTP_CODE   = "887766";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function sql(query: string) {
  execSync(
    `mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} ${DB_NAME} -e "${query.replace(/"/g, '\\"')}"`,
    { stdio: "pipe" },
  );
}

async function createMemberUser(page: Page, tenantId: string, email: string): Promise<string> {
  const r = await page.context().request.post(`${ADMIN_BASE}/tenants/${tenantId}/users`, {
    data: { email, role: "member" },
  });
  expect(r.ok(), `create member user ${email}: ${await r.text()}`).toBeTruthy();
  return ((await r.json()) as { id: string }).id;
}

async function deleteUser(page: Page, userId: string) {
  await page.context().request.delete(`${ADMIN_BASE}/users/${userId}`).catch(() => {});
}

/**
 * Authenticate as `email` via OTP and return a new page in a new browser
 * context.  Caller must close the context when done.
 */
async function loginAsMember(browser: Browser, email: string) {
  const hash   = execSync(`echo -n '${OTP_CODE}' | sha256sum | awk '{print $1}'`).toString().trim();
  const expiry = Math.floor(Date.now() / 1000) + 900;
  const otpId  = execSync("cat /proc/sys/kernel/random/uuid").toString().trim();

  sql(`DELETE FROM email_otp WHERE email='${email}' AND used_at IS NULL`);
  sql(`INSERT INTO email_otp (id, email, code_hash, expires_at, ip_addr) VALUES ('${otpId}', '${email}', '${hash}', ${expiry}, '127.0.0.1')`);

  const tempCtx = await browser.newContext({ ignoreHTTPSErrors: true });
  try {
    const resp = await tempCtx.request.post(`${AUTH_BASE}/otp/verify`, {
      data: { email, code: OTP_CODE },
    });
    expect(resp.ok(), `OTP verify for ${email}: ${await resp.text()}`).toBeTruthy();
  } finally {
    // fall through — cookies are in tempCtx
  }

  const cookies = await tempCtx.cookies();
  await tempCtx.close();

  const baseURL = process.env.PLAYWRIGHT_BASE_URL ?? "http://localhost:5173";
  const ctx  = await browser.newContext({ baseURL, ignoreHTTPSErrors: true });
  await ctx.addCookies(cookies);
  const memberPage = await ctx.newPage();
  return { page: memberPage, ctx };
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

test.describe("Dashboard — member/viewer role shows own usage", () => {
  test.setTimeout(60_000);

  test("member user sees dashboard (200 from /stats) not a blank error", async ({ page, browser, workerTenantId }) => {
    const email  = `e2e-member-dash-${Date.now()}@example.invalid`;
    const userId = await createMemberUser(page, workerTenantId, email);

    const { page: mPage, ctx } = await loginAsMember(browser, email);
    try {
      // Intercept /stats to verify 200 (not 403)
      let statsStatus = 0;
      mPage.on("response", (resp) => {
        if (resp.url().includes("/admin/v1/stats") && !resp.url().includes("timeseries") && !resp.url().includes("analytics")) {
          statsStatus = resp.status();
        }
      });

      await mPage.goto("/dashboard");
      await mPage.waitForTimeout(1500);

      expect(statsStatus, "/stats must return 200 for member users").toBe(200);

      // Page must load — loading spinner must not persist
      const loading = mPage.getByText("Loading…");
      await expect(loading).toBeHidden({ timeout: 10_000 });
    } finally {
      await ctx.close();
      await deleteUser(page, userId);
    }
  });

  test("member user sees 'My Usage' title (not 'Dashboard')", async ({ page, browser, workerTenantId }) => {
    const email  = `e2e-member-title-${Date.now()}@example.invalid`;
    const userId = await createMemberUser(page, workerTenantId, email);

    const { page: mPage, ctx } = await loginAsMember(browser, email);
    try {
      await mPage.goto("/dashboard");
      await mPage.waitForLoadState("networkidle");

      const h1 = mPage.locator("h1");
      await expect(h1).toHaveText("My Usage", { timeout: 8_000 });

      const subtitle = mPage.getByText("Your personal API usage");
      await expect(subtitle).toBeVisible({ timeout: 5_000 });
    } finally {
      await ctx.close();
      await deleteUser(page, userId);
    }
  });

  test("member user does not see 'Usage by Tenant' section", async ({ page, browser, workerTenantId }) => {
    const email  = `e2e-member-notenant-${Date.now()}@example.invalid`;
    const userId = await createMemberUser(page, workerTenantId, email);

    const { page: mPage, ctx } = await loginAsMember(browser, email);
    try {
      await mPage.goto("/dashboard");
      await mPage.waitForLoadState("networkidle");

      // Must not see the "Usage by Tenant" heading at any point after load
      const tenantSection = mPage.getByText("Usage by Tenant", { exact: false });
      await expect(tenantSection).toBeHidden({ timeout: 5_000 });
    } finally {
      await ctx.close();
      await deleteUser(page, userId);
    }
  });

  test("member user does not see 'Recent Guardrail Events' section", async ({ page, browser, workerTenantId }) => {
    const email  = `e2e-member-noguard-${Date.now()}@example.invalid`;
    const userId = await createMemberUser(page, workerTenantId, email);

    const { page: mPage, ctx } = await loginAsMember(browser, email);
    try {
      await mPage.goto("/dashboard");
      await mPage.waitForLoadState("networkidle");

      const guardrailSection = mPage.getByText("Recent Guardrail Events", { exact: false });
      await expect(guardrailSection).toBeHidden({ timeout: 5_000 });
    } finally {
      await ctx.close();
      await deleteUser(page, userId);
    }
  });

  test("admin user still sees 'Dashboard' title", async ({ page }) => {
    await page.goto("/dashboard");
    await page.waitForLoadState("networkidle");

    const h1 = page.locator("h1");
    await expect(h1).toHaveText("Dashboard", { timeout: 8_000 });

    const subtitle = page.getByText("Real-time AI Gateway metrics");
    await expect(subtitle).toBeVisible({ timeout: 5_000 });
  });
});
