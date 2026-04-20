/**
 * auth.docker.setup.ts — Like auth.setup.ts but inserts the OTP into MySQL
 * (used by the Docker stack) instead of SQLite.
 */

import { test as setup, expect } from "@playwright/test";
import { execSync } from "child_process";
import path from "path";

const DB_HOST = "172.17.0.1";
const DB_USER = "gateway";
const DB_PASS = "gateway";
const DB_NAME = "ai_gateway";
const EMAIL   = "info@schumann.net";
const CODE    = "999888";
const SESSION = path.resolve(__dirname, ".auth/docker-session.json");

function sql(query: string) {
  execSync(
    `mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} ${DB_NAME} -e ${JSON.stringify(query)}`,
    { stdio: "pipe" }
  );
}

setup("authenticate against Docker (MySQL)", async ({ page }) => {
  const hash   = execSync(`echo -n '${CODE}' | sha256sum | awk '{print $1}'`).toString().trim();
  const expiry = Math.floor(Date.now() / 1000) + 900;
  const id     = execSync("cat /proc/sys/kernel/random/uuid").toString().trim();

  sql(`DELETE FROM email_otp WHERE email='${EMAIL}' AND used_at IS NULL`);
  sql(`INSERT INTO email_otp (id, email, code_hash, expires_at, ip_addr) VALUES ('${id}', '${EMAIL}', '${hash}', ${expiry}, '127.0.0.1')`);

  // Intercept the OTP request so no real email is sent
  await page.route("**/admin/auth/otp/request", route =>
    route.fulfill({ status: 200, contentType: "application/json",
                    body: JSON.stringify({ message: "Code sent (intercepted by test)" }) })
  );

  await page.goto("/login");
  await expect(page.getByText("Continue with Email code")).toBeVisible();
  await page.getByText("Continue with Email code").click();

  await page.getByLabel("Email address").fill(EMAIL);
  await page.getByRole("button", { name: "Send code" }).click();

  await expect(page.getByLabel("6-digit code")).toBeVisible();
  await page.getByLabel("6-digit code").fill(CODE);
  await page.getByRole("button", { name: "Sign in" }).click();

  await expect(page).toHaveURL(/\/(dashboard|$)/, { timeout: 5000 });
  await page.context().storageState({ path: SESSION });
});
