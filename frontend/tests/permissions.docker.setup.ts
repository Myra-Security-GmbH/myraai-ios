/**
 * permissions.docker.setup.ts — Like permissions.setup.ts but inserts fixtures
 * into MySQL (used by the Docker stack) instead of SQLite.
 *
 * Creates:
 *   - Two test tenants (__perm-test-tenant-a__, __perm-test-tenant-b__)
 *   - One gateway per tenant
 *   - A member user for tenant A
 *   - A tenant_admin user for tenant A
 *   - tests/.auth/member-session.json
 *   - tests/.auth/tenant-admin-session.json
 *   - tests/.auth/fixtures.json
 */

import { test as setup, expect } from "@playwright/test";
import { execSync } from "child_process";
import path from "path";
import fs from "fs";

const DB_HOST = "172.17.0.1";
const DB_USER = "gateway";
const DB_PASS = "gateway";
const DB_NAME = "ai_gateway";

const MEMBER_SESSION       = path.resolve(__dirname, ".auth/member-session.json");
const TENANT_ADMIN_SESSION = path.resolve(__dirname, ".auth/tenant-admin-session.json");
const FIXTURES             = path.resolve(__dirname, ".auth/fixtures.json");

const MEMBER_EMAIL       = "perm-test-member@local.test";
const TENANT_ADMIN_EMAIL = "perm-test-tenant-admin@local.test";
const OTP_CODE           = "776655";

const SLUG_TENANT_A = "z-perm-test-tenant-a";
const SLUG_TENANT_B = "z-perm-test-tenant-b";
const SLUG_GW_A     = "z-perm-test-gw-a";
const SLUG_GW_B     = "z-perm-test-gw-b";

function sql(query: string) {
  execSync(
    `mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} ${DB_NAME} -e ${JSON.stringify(query)}`,
    { stdio: "pipe" }
  );
}

function sqlNoFk(query: string) {
  const wrapped = `SET foreign_key_checks=0; ${query}; SET foreign_key_checks=1;`;
  execSync(
    `mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} ${DB_NAME} -e ${JSON.stringify(wrapped)}`,
    { stdio: "pipe" }
  );
}

function uuid(): string {
  return execSync("cat /proc/sys/kernel/random/uuid").toString().trim();
}

async function loginAs(page: any, email: string, sessionPath: string) {
  const hash   = execSync(`echo -n '${OTP_CODE}' | sha256sum | awk '{print $1}'`).toString().trim();
  const expiry = Math.floor(Date.now() / 1000) + 900;
  const otpId  = uuid();

  sql(`DELETE FROM email_otp WHERE email='${email}' AND used_at IS NULL`);
  sql(`INSERT INTO email_otp (id, email, code_hash, expires_at, ip_addr) VALUES ('${otpId}', '${email}', '${hash}', ${expiry}, '127.0.0.1')`);

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
  await expect(page).toHaveURL(/\/(dashboard|$)/, { timeout: 5000 });

  await page.context().storageState({ path: sessionPath });
}

setup("create permission fixtures (MySQL)", async ({ page }) => {
  // ---- Teardown previous run ----
  sql(`DELETE FROM user WHERE email IN ('${MEMBER_EMAIL}','${TENANT_ADMIN_EMAIL}')`);
  sql(`DELETE FROM gateway WHERE slug IN ('${SLUG_GW_A}','${SLUG_GW_B}')`);
  sqlNoFk(`DELETE FROM tenant WHERE slug IN ('${SLUG_TENANT_A}','${SLUG_TENANT_B}')`);

  // ---- Create fixture data ----
  const tenantAId  = uuid();
  const tenantBId  = uuid();
  const gatewayAId = uuid();
  const gatewayBId = uuid();
  const memberId   = uuid();
  const adminId    = uuid();

  sql(`INSERT INTO tenant (id, slug, plan) VALUES ('${tenantAId}', '${SLUG_TENANT_A}', 'standard')`);
  sql(`INSERT INTO tenant (id, slug, plan) VALUES ('${tenantBId}', '${SLUG_TENANT_B}', 'standard')`);
  sql(`INSERT INTO gateway (id, tenant_id, slug, config) VALUES ('${gatewayAId}', '${tenantAId}', '${SLUG_GW_A}', '{}')`);
  sql(`INSERT INTO gateway (id, tenant_id, slug, config) VALUES ('${gatewayBId}', '${tenantBId}', '${SLUG_GW_B}', '{}')`);
  sql(`INSERT INTO user (id, tenant_id, email, role) VALUES ('${memberId}', '${tenantAId}', '${MEMBER_EMAIL}', 'member')`);
  sql(`INSERT INTO user (id, tenant_id, email, role) VALUES ('${adminId}', '${tenantAId}', '${TENANT_ADMIN_EMAIL}', 'tenant_admin')`);

  // ---- Save fixture IDs ----
  fs.writeFileSync(FIXTURES, JSON.stringify({
    tenantAId, tenantBId,
    gatewayAId, gatewayBId,
    memberId, adminId,
  }, null, 2));

  // ---- Log in as member ----
  await loginAs(page, MEMBER_EMAIL, MEMBER_SESSION);
});

setup("create tenant_admin session (MySQL)", async ({ page }) => {
  // fixtures.json must already exist (written by first setup step above)
  await loginAs(page, TENANT_ADMIN_EMAIL, TENANT_ADMIN_SESSION);
});
