/**
 * start-redirect.spec.ts — verify the post-login landing page is role-aware:
 *   admin / tenant_admin → /dashboard
 *   member  / viewer     → /chat
 *
 * The "/" route in the SPA picks a destination based on user.role. This test
 * exercises that branch by creating a temporary user, completing the OTP
 * login flow, and asserting the URL after sign-in.
 */

import { test, expect, Page, BrowserContext } from "@playwright/test";
import { execSync } from "child_process";

const ADMIN_BASE = process.env.PLAYWRIGHT_ADMIN_URL
  ? `${process.env.PLAYWRIGHT_ADMIN_URL}/admin/v1`
  : "http://localhost:5173/admin/v1";

const DB_HOST = process.env.E2E_DB_HOST ?? "172.17.0.1";
const DB_USER = process.env.E2E_DB_USER ?? "gateway_int";
const DB_PASS = process.env.E2E_DB_PASS ?? "yefVaf]oresev8";
const DB_NAME = process.env.E2E_DB_NAME ?? "ai_gateway_int";

function sql(query: string) {
  execSync(
    `mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} ${DB_NAME} -e ${JSON.stringify(query)}`,
    { stdio: "pipe" }
  );
}

function insertOTP(email: string, code: string): void {
  const hash   = execSync(`echo -n '${code}' | sha256sum | awk '{print $1}'`).toString().trim();
  const expiry = Math.floor(Date.now() / 1000) + 900;
  const id     = execSync("cat /proc/sys/kernel/random/uuid").toString().trim();
  sql(`DELETE FROM email_otp WHERE email='${email}' AND used_at IS NULL`);
  sql(`INSERT INTO email_otp (id, email, code_hash, expires_at, ip_addr) VALUES ('${id}', '${email}', '${hash}', ${expiry}, '127.0.0.1')`);
}

async function getMyratestId(page: Page): Promise<string> {
  const resp = await page.request.get(`${ADMIN_BASE}/tenants`);
  expect(resp.ok(), `GET /tenants: ${resp.status()}`).toBeTruthy();
  const tenants = await resp.json() as Array<{ id: string; name: string }>;
  const t = tenants.find(x => x.name === "myratest") ?? tenants[0];
  expect(t, "no tenant available").toBeTruthy();
  return t!.id;
}

async function createUser(page: Page, email: string, role: "admin" | "member" | "viewer", tenant_id: string): Promise<string> {
  const resp = await page.request.post(`${ADMIN_BASE}/tenants/${tenant_id}/users`, {
    data: { email, name: `Start Redirect ${role}`, role },
  });
  expect(resp.ok(), `POST /tenants/${tenant_id}/users (${role}): ${resp.status()} ${await resp.text()}`).toBeTruthy();
  const u = await resp.json() as { id: string };
  return u.id;
}

async function deleteUser(page: Page, userId: string) {
  await page.request.delete(`${ADMIN_BASE}/users/${userId}`).catch(() => {});
}

async function loginAs(context: BrowserContext, email: string, code: string): Promise<Page> {
  const page = await context.newPage();
  await page.route("**/admin/auth/otp/request", route =>
    route.fulfill({ status: 200, contentType: "application/json",
                    body: JSON.stringify({ message: "Code sent (intercepted by test)" }) })
  );
  await page.goto("/login");
  await page.getByText("Continue with Email code").click();
  await page.getByLabel("Email address").fill(email);
  await page.getByRole("button", { name: "Send code" }).click();
  await expect(page.getByLabel("6-digit code")).toBeVisible();
  await page.getByLabel("6-digit code").fill(code);
  await page.getByRole("button", { name: "Sign in" }).click();
  // Wait for the post-login redirect to settle so the session cookie is set
  // before any caller does its own navigation.
  await page.waitForURL(/\/(chat|dashboard)$/, { timeout: 10000 });
  return page;
}

test.describe("start-redirect after login", () => {
  // Use a fresh browser context (no shared admin session) for each role test.
  test.use({ storageState: { cookies: [], origins: [] } });

  test("member lands on /chat after login", async ({ context, browser }) => {
    // Use an admin context just to create the user via the API.
    const adminContext = await browser.newContext({
      storageState: "tests/.auth/docker-session.json",
    });
    const adminPage = await adminContext.newPage();
    const tenantId  = await getMyratestId(adminPage);
    const email     = `start-redirect-member-${Date.now()}@local.test`;
    const userId    = await createUser(adminPage, email, "member", tenantId);

    try {
      insertOTP(email, "246810");
      const page = await loginAs(context, email, "246810");

      await expect(page).toHaveURL(/\/chat$/, { timeout: 10000 });
      await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
    } finally {
      await deleteUser(adminPage, userId);
      sql(`DELETE FROM user WHERE email='${email}'`);
      await adminContext.close();
    }
  });

  test("viewer lands on /chat after login", async ({ context, browser }) => {
    const adminContext = await browser.newContext({
      storageState: "tests/.auth/docker-session.json",
    });
    const adminPage = await adminContext.newPage();
    const tenantId  = await getMyratestId(adminPage);
    const email     = `start-redirect-viewer-${Date.now()}@local.test`;
    const userId    = await createUser(adminPage, email, "viewer", tenantId);

    try {
      insertOTP(email, "135790");
      const page = await loginAs(context, email, "135790");

      await expect(page).toHaveURL(/\/chat$/, { timeout: 10000 });
      await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
    } finally {
      await deleteUser(adminPage, userId);
      sql(`DELETE FROM user WHERE email='${email}'`);
      await adminContext.close();
    }
  });

  test("admin lands on /dashboard after login", async ({ context, browser }) => {
    const adminContext = await browser.newContext({
      storageState: "tests/.auth/docker-session.json",
    });
    const adminPage = await adminContext.newPage();
    const tenantId  = await getMyratestId(adminPage);
    const email     = `start-redirect-admin-${Date.now()}@local.test`;
    const userId    = await createUser(adminPage, email, "admin", tenantId);

    try {
      insertOTP(email, "112233");
      const page = await loginAs(context, email, "112233");

      await expect(page).toHaveURL(/\/dashboard$/, { timeout: 10000 });
      await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
    } finally {
      await deleteUser(adminPage, userId);
      sql(`DELETE FROM user WHERE email='${email}'`);
      await adminContext.close();
    }
  });

  test("member visiting / is redirected to /chat", async ({ context, browser }) => {
    const adminContext = await browser.newContext({
      storageState: "tests/.auth/docker-session.json",
    });
    const adminPage = await adminContext.newPage();
    const tenantId  = await getMyratestId(adminPage);
    const email     = `start-redirect-root-${Date.now()}@local.test`;
    const userId    = await createUser(adminPage, email, "member", tenantId);

    try {
      insertOTP(email, "987654");
      const page = await loginAs(context, email, "987654");

      // After login, navigate explicitly to /
      await page.goto("/");
      await expect(page).toHaveURL(/\/chat$/, { timeout: 10000 });
    } finally {
      await deleteUser(adminPage, userId);
      sql(`DELETE FROM user WHERE email='${email}'`);
      await adminContext.close();
    }
  });
});
