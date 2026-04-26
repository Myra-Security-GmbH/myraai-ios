/**
 * workers.teardown.ts — Removes the 10 e2e worker users created by workers.setup.ts.
 * Runs after the test suite completes. Best-effort: failure does not fail the suite.
 */

import { test as teardown } from "@playwright/test";
import { execSync } from "child_process";

const DB_HOST = process.env.E2E_DB_HOST ?? "172.17.0.1";
const DB_USER = process.env.E2E_DB_USER ?? "gateway";
const DB_PASS = process.env.E2E_DB_PASS ?? "gateway";
const DB_NAME = process.env.E2E_DB_NAME ?? "ai_gateway";

function sql(q: string): void {
  execSync(
    `mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} ${DB_NAME} -e ${JSON.stringify(q)}`,
    { stdio: "pipe" }
  );
}

teardown("remove worker users", async () => {
  try {
    sql(`DELETE FROM \`user\` WHERE email LIKE 'e2e-worker-%@test.local'`);
    sql(`DELETE FROM email_otp WHERE email LIKE 'e2e-worker-%@test.local'`);
  } catch {
    // best-effort — do not fail the suite on teardown errors
  }
});
