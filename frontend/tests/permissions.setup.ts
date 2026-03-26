/**
 * permissions.setup.ts — Creates isolated test fixtures for org-scoping tests.
 *
 * Inserts two orgs (A and B), one tenant + one gateway per org, and a
 * member user for org A.  Logs in as that user and saves their session
 * to tests/.auth/org-session.json.  Writes all fixture IDs to
 * tests/.auth/fixtures.json so org-scoping.spec.ts can reference them.
 *
 * Teardown: fixtures are cleaned up at the top of each run so the DB stays tidy.
 *
 * Run via the "permissions-setup" Playwright project (see playwright.config.ts).
 */

import { test as setup, expect } from "@playwright/test";
import { execSync } from "child_process";
import path from "path";
import fs from "fs";

const DB          = "/opt/ai-gateway/data/config.db";
const ORG_SESSION = path.resolve(__dirname, ".auth/org-session.json");
const FIXTURES    = path.resolve(__dirname, ".auth/fixtures.json");

const ADMIN_EMAIL = "org-admin-test@local.test";
const OTP_CODE    = "776655";

// Slug sentinels — unique enough to avoid collisions with real data
const SLUG_ORG_A    = "__perm-test-org-a__";
const SLUG_ORG_B    = "__perm-test-org-b__";
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

setup("create permission fixtures and org-admin session", async ({ page }) => {
  // ---- Teardown previous run ----
  db(`DELETE FROM user WHERE email = '${ADMIN_EMAIL}'`);
  db(`DELETE FROM gateway WHERE slug IN ('${SLUG_GW_A}','${SLUG_GW_B}')`);
  db(`DELETE FROM tenant WHERE slug IN ('${SLUG_TENANT_A}','${SLUG_TENANT_B}')`);
  db(`DELETE FROM organization WHERE slug IN ('${SLUG_ORG_A}','${SLUG_ORG_B}')`);

  // ---- Create fixture data ----
  const orgAId     = uuid();
  const orgBId     = uuid();
  const tenantAId  = uuid();
  const tenantBId  = uuid();
  const gatewayAId = uuid();
  const gatewayBId = uuid();
  const userId     = uuid();

  db(`INSERT INTO organization (id, name, slug) VALUES ('${orgAId}', 'Perm Test Org A', '${SLUG_ORG_A}')`);
  db(`INSERT INTO organization (id, name, slug) VALUES ('${orgBId}', 'Perm Test Org B', '${SLUG_ORG_B}')`);

  db(`INSERT INTO tenant (id, slug, plan, organization_id) VALUES ('${tenantAId}', '${SLUG_TENANT_A}', 'standard', '${orgAId}')`);
  db(`INSERT INTO tenant (id, slug, plan, organization_id) VALUES ('${tenantBId}', '${SLUG_TENANT_B}', 'standard', '${orgBId}')`);

  db(`INSERT INTO gateway (id, tenant_id, slug, config) VALUES ('${gatewayAId}', '${tenantAId}', '${SLUG_GW_A}', '{}')`);
  db(`INSERT INTO gateway (id, tenant_id, slug, config) VALUES ('${gatewayBId}', '${tenantBId}', '${SLUG_GW_B}', '{}')`);

  // org member: organization_id = org A, role = member
  db(`INSERT INTO user (id, organization_id, email, role) VALUES ('${userId}', '${orgAId}', '${ADMIN_EMAIL}', 'member')`);

  // ---- Log in as admin_org user ----
  const hash   = execSync(`echo -n '${OTP_CODE}' | sha256sum | awk '{print $1}'`).toString().trim();
  const expiry = Math.floor(Date.now() / 1000) + 900;
  const otpId  = uuid();

  db(`DELETE FROM email_otp WHERE email='${ADMIN_EMAIL}' AND used_at IS NULL`);
  db(`INSERT INTO email_otp (id, email, code_hash, expires_at, ip_addr) VALUES ('${otpId}', '${ADMIN_EMAIL}', '${hash}', ${expiry}, '127.0.0.1')`);

  await page.route("**/admin/auth/otp/request", route =>
    route.fulfill({ status: 200, contentType: "application/json",
                    body: JSON.stringify({ message: "ok" }) })
  );

  await page.goto("/login");
  await page.getByText("Continue with Email code").click();
  await page.getByLabel("Email address").fill(ADMIN_EMAIL);
  await page.getByRole("button", { name: "Send code" }).click();
  await expect(page.getByLabel("6-digit code")).toBeVisible();
  await page.getByLabel("6-digit code").fill(OTP_CODE);
  await page.getByRole("button", { name: "Sign in" }).click();
  await expect(page).toHaveURL(/\/(dashboard|$)/, { timeout: 10000 });

  await page.context().storageState({ path: ORG_SESSION });

  // ---- Save fixture IDs for the spec ----
  fs.writeFileSync(FIXTURES, JSON.stringify({
    orgAId, orgBId,
    tenantAId, tenantBId,
    gatewayAId, gatewayBId,
  }, null, 2));
});
