/**
 * permissions.teardown.ts — Removes DB fixtures created by permissions.setup.ts.
 *
 * Runs automatically after all tests in the "permissions" project complete
 * (wired via the `teardown` property on the "permissions-setup" project in
 * playwright.config.ts).  Also removes the org-session and fixtures JSON files.
 */

import { test as teardown } from "@playwright/test";
import { execSync } from "child_process";
import path from "path";
import fs from "fs";

const DB          = "/opt/ai-gateway/data/config.db";
const ORG_SESSION = path.resolve(__dirname, ".auth/org-session.json");
const FIXTURES    = path.resolve(__dirname, ".auth/fixtures.json");

const SLUG_ORG_A    = "__perm-test-org-a__";
const SLUG_ORG_B    = "__perm-test-org-b__";
const SLUG_TENANT_A = "__perm-test-tenant-a__";
const SLUG_TENANT_B = "__perm-test-tenant-b__";
const SLUG_GW_A     = "__perm-test-gw-a__";
const SLUG_GW_B     = "__perm-test-gw-b__";
const ADMIN_EMAIL   = "org-admin-test@local.test";

function db(query: string) {
  execSync(`sqlite3 ${DB} ${JSON.stringify(query)}`);
}

teardown("remove permission test fixtures", async () => {
  db(`DELETE FROM user WHERE email = '${ADMIN_EMAIL}'`);
  db(`DELETE FROM gateway WHERE slug IN ('${SLUG_GW_A}','${SLUG_GW_B}')`);
  db(`DELETE FROM tenant WHERE slug IN ('${SLUG_TENANT_A}','${SLUG_TENANT_B}')`);
  db(`DELETE FROM organization WHERE slug IN ('${SLUG_ORG_A}','${SLUG_ORG_B}')`);

  for (const f of [ORG_SESSION, FIXTURES]) {
    if (fs.existsSync(f)) fs.unlinkSync(f);
  }
});
