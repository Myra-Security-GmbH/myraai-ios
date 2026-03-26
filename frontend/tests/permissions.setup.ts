/**
 * permissions.setup.ts — Creates isolated test fixtures for tenant-scoping tests.
 *
 * Inserts two tenants (A and B), one gateway per tenant, one member user for
 * tenant A, and one tenant_admin user for tenant A.  Logs in as the member user
 * and saves their session to tests/.auth/member-session.json.  Logs in as the
 * tenant_admin user and saves to tests/.auth/tenant-admin-session.json.  Writes
 * all fixture IDs to tests/.auth/fixtures.json.
 *
 * Teardown: fixtures are cleaned up at the top of each run so the DB stays tidy.
 *
 * Run via the "permissions-setup" Playwright project (see playwright.config.ts).
 */

import { test as setup, expect } from "@playwright/test";
import { execSync } from "child_process";
import path from "path";
import fs from "fs";

const DB                   = "/opt/ai-gateway/data/config.db";
const MEMBER_SESSION       = path.resolve(__dirname, ".auth/member-session.json");
const TENANT_ADMIN_SESSION = path.resolve(__dirname, ".auth/tenant-admin-session.json");
const FIXTURES             = path.resolve(__dirname, ".auth/fixtures.json");

const MEMBER_EMAIL       = "perm-test-member@local.test";
const TENANT_ADMIN_EMAIL = "perm-test-tenant-admin@local.test";
const OTP_CODE           = "776655";

// Slug sentinels — unique enough to avoid collisions with real data
const SLUG_TENANT_A = "__perm-test-tenant-a__";
const SLUG_TENANT_B = "__perm-test-tenant-b__";
const SLUG_GW_A     = "__perm-test-gw-a__";
const SLUG_GW_B     = "__perm-test-gw-b__";

function uuid(): string {
  return execSync("cat /proc/sys/kernel/random/uuid").toString().trim();
}

function db(query: string) {
  execSync(`sqlite3 ${DB} ${JSON.stringify(query)}`);
}

async function loginAs(page: any, email: string, sessionPath: string) {
  const hash   = execSync(`echo -n '${OTP_CODE}' | sha256sum | awk '{print $1}'`).toString().trim();
  const expiry = Math.floor(Date.now() / 1000) + 900;
  const otpId  = uuid();

  db(`DELETE FROM email_otp WHERE email='${email}' AND used_at IS NULL`);
  db(`INSERT INTO email_otp (id, email, code_hash, expires_at, ip_addr) VALUES ('${otpId}', '${email}', '${hash}', ${expiry}, '127.0.0.1')`);

  await page.route("**/admin/auth/otp/request", route =>
    route.fulfill({ status: 200, contentType: "application/json",
                    body: JSON.stringify({ message: "ok" }) })
  );

  await page.goto("/login");
  await page.getByText("Continue with Email code").click();
  await page.getByLabel("Email address").fill(email);
  await page.getByRole("button", { name: "Send code" }).click();
  await expect(page.getByLabel("6-digit code")).toBeVisible();
  await page.getByLabel("6-digit code").fill(OTP_CODE);
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page).toHaveURL(/\/(dashboard|$)/, { timeout: 10000 });

  await page.context().storageState({ path: sessionPath });
}

setup("create permission fixtures and sessions", async ({ page }) => {
  // ---- Teardown previous run ----
  db(`DELETE FROM user WHERE email IN ('${MEMBER_EMAIL}','${TENANT_ADMIN_EMAIL}')`);
  db(`DELETE FROM gateway WHERE slug IN ('${SLUG_GW_A}','${SLUG_GW_B}')`);
  db(`DELETE FROM tenant WHERE slug IN ('${SLUG_TENANT_A}','${SLUG_TENANT_B}')`);

  // ---- Create fixture data ----
  const tenantAId  = uuid();
  const tenantBId  = uuid();
  const gatewayAId = uuid();
  const gatewayBId = uuid();
  const memberId   = uuid();
  const adminId    = uuid();

  db(`INSERT INTO tenant (id, slug, plan) VALUES ('${tenantAId}', '${SLUG_TENANT_A}', 'standard')`);
  db(`INSERT INTO tenant (id, slug, plan) VALUES ('${tenantBId}', '${SLUG_TENANT_B}', 'standard')`);

  db(`INSERT INTO gateway (id, tenant_id, slug, config) VALUES ('${gatewayAId}', '${tenantAId}', '${SLUG_GW_A}', '{}')`);
  db(`INSERT INTO gateway (id, tenant_id, slug, config) VALUES ('${gatewayBId}', '${tenantBId}', '${SLUG_GW_B}', '{}')`);

  // member user: tenant A
  db(`INSERT INTO user (id, tenant_id, email, role) VALUES ('${memberId}', '${tenantAId}', '${MEMBER_EMAIL}', 'member')`);
  // tenant_admin user: tenant A
  db(`INSERT INTO user (id, tenant_id, email, role) VALUES ('${adminId}', '${tenantAId}', '${TENANT_ADMIN_EMAIL}', 'tenant_admin')`);

  // ---- Save fixture IDs ----
  fs.writeFileSync(FIXTURES, JSON.stringify({
    tenantAId, tenantBId,
    gatewayAId, gatewayBId,
    memberId, adminId,
  }, null, 2));

  // ---- Log in as member ----
  await loginAs(page, MEMBER_EMAIL, MEMBER_SESSION);
});

setup("create tenant_admin session", async ({ page }) => {
  // fixtures.json must already exist (written by first setup step)
  await loginAs(page, TENANT_ADMIN_EMAIL, TENANT_ADMIN_SESSION);
});
