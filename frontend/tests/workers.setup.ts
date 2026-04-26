/**
 * workers.setup.ts — Creates 10 admin users for parallel test isolation.
 *
 * Each Playwright worker gets its own authenticated session so that
 * deleteConversations() only deletes that worker's own fixtures.
 *
 * Users: e2e-worker-{0..9}@test.local  (role: admin, tenant_id: e2e-tenant-{i})
 * Sessions: tests/.auth/worker-{i}-session.json
 * Meta:     tests/.auth/worker-{i}-meta.json  { tenantId, gatewayId, gatewaySlug }
 *
 * Workers belong to e2e-tenant-{i} so MCP connectors, projects, and other
 * tenant-scoped CRUD are naturally isolated between workers.  Inference tests
 * that need real API keys look up myratest gateways via the admin API — admin
 * role gives cross-tenant read access.
 *
 * DB credentials are read from env vars (set by run_docker_integration.sh or
 * run_docker_production.sh for their respective environments):
 *   E2E_DB_HOST  (default: 172.17.0.1)
 *   E2E_DB_USER  (default: gateway)
 *   E2E_DB_PASS  (default: gateway)
 *   E2E_DB_NAME  (default: ai_gateway)
 */

import { test as setup, expect } from "@playwright/test";
import { execSync } from "child_process";
import path from "path";
import fs from "fs";

const DB_HOST    = process.env.E2E_DB_HOST ?? "172.17.0.1";
const DB_USER    = process.env.E2E_DB_USER ?? "gateway";
const DB_PASS    = process.env.E2E_DB_PASS ?? "gateway";
const DB_NAME    = process.env.E2E_DB_NAME ?? "ai_gateway";
const NUM_WORKERS = 10;
const OTP_BASE   = 777000; // codes: 777000 … 777009

function sql(q: string): void {
  execSync(
    `mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} ${DB_NAME}`,
    { input: q, stdio: ["pipe", "pipe", "pipe"] }
  );
}

function sqlOne(q: string): string {
  return execSync(
    `mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} -N ${DB_NAME}`,
    { input: q, stdio: ["pipe", "pipe", "pipe"] }
  ).toString().trim().split("\n")[0] ?? "";
}

function uuid(): string {
  return execSync("cat /proc/sys/kernel/random/uuid").toString().trim();
}

setup("create worker users and sessions", async ({ browser }) => {
  const authDir = path.resolve(__dirname, ".auth");
  fs.mkdirSync(authDir, { recursive: true });

  for (let i = 0; i < NUM_WORKERS; i++) {
    const email   = `e2e-worker-${i}@test.local`;
    const code    = String(OTP_BASE + i);
    const hash    = execSync(`echo -n '${code}' | sha256sum | awk '{print $1}'`).toString().trim();
    const expiry  = Math.floor(Date.now() / 1000) + 900;
    const otpId   = uuid();
    const userId  = uuid();
    const session = path.join(authDir, `worker-${i}-session.json`);
    const meta    = path.join(authDir, `worker-${i}-meta.json`);

    // Resolve per-worker tenant and gateway IDs (seeded statically in each env DB).
    const tenantId   = sqlOne(`SELECT id FROM tenant  WHERE slug='e2e-tenant-${i}'  LIMIT 1`);
    const gatewayId  = sqlOne(`SELECT id FROM gateway WHERE slug='e2e-gateway-${i}' LIMIT 1`);
    if (!tenantId)  throw new Error(`e2e-tenant-${i} not found in DB — run the seeding SQL for this environment`);
    if (!gatewayId) throw new Error(`e2e-gateway-${i} not found in DB — run the seeding SQL for this environment`);
    const gatewaySlug = `e2e-gateway-${i}`;

    fs.writeFileSync(meta, JSON.stringify({ tenantId, gatewayId, gatewaySlug }, null, 2));

    // Idempotent user creation — INSERT IGNORE skips if email already exists
    sql(
      `INSERT IGNORE INTO \`user\` (id, tenant_id, email, name, role, created_at) ` +
      `VALUES ('${userId}', '${tenantId}', '${email}', 'E2E Worker ${i}', 'admin', UNIX_TIMESTAMP())`
    );
    // Migrate existing users (may have been created in myratest or with NULL tenant in prior runs)
    sql(`UPDATE \`user\` SET tenant_id='${tenantId}' WHERE email='${email}' AND tenant_id != '${tenantId}'`);

    // Refresh OTP (clear any stale ones first)
    sql(`DELETE FROM email_otp WHERE email='${email}' AND used_at IS NULL`);
    sql(
      `INSERT INTO email_otp (id, email, code_hash, expires_at, ip_addr) ` +
      `VALUES ('${otpId}', '${email}', '${hash}', ${expiry}, '127.0.0.1')`
    );

    const ctx  = await browser.newContext();
    const page = await ctx.newPage();

    // Intercept OTP request so no real email is sent
    await page.route("**/admin/auth/otp/request", route =>
      route.fulfill({ status: 200, contentType: "application/json",
                      body: JSON.stringify({ message: "intercepted by workers.setup" }) })
    );

    await page.goto("/login");
    await expect(page.getByText("Continue with Email code")).toBeVisible({ timeout: 10000 });
    await page.getByText("Continue with Email code").click();
    await page.getByLabel("Email address").fill(email);
    await page.getByRole("button", { name: "Send code" }).click();
    await expect(page.getByLabel("6-digit code")).toBeVisible({ timeout: 5000 });
    await page.getByLabel("6-digit code").fill(code);
    await page.getByRole("button", { name: "Sign in" }).click();
    await expect(page).toHaveURL(/\/(dashboard|$)/, { timeout: 10000 });

    await ctx.storageState({ path: session });
    await ctx.close();
  }
});
