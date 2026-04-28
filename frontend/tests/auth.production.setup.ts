/**
 * auth.production.setup.ts — Playwright setup for the production instance.
 *
 * Inserts a known OTP into the production MySQL database, completes the
 * login flow for info@schumann.net, and saves the session to
 * tests/.auth/production-session.json so screenshot tests start logged in.
 *
 * Prerequisites:
 *   mysql CLI must be available and can reach 172.17.0.1:3306.
 */

import { test as setup, expect } from "@playwright/test";
import { execSync } from "child_process";
import path from "path";

const EMAIL   = "info@schumann.net";
const CODE    = "947382";   // fixed known code — inserted fresh each run
const SESSION = path.resolve(__dirname, ".auth/production-session.json");

const MYSQL = "mysql -h 172.17.0.1 -u gateway -pgateway ai_gateway";

setup("authenticate against production", async ({ page }) => {
  // Compute SHA-256 of the code (same as auth_handlers.lua)
  const hash = execSync(`printf '%s' '${CODE}' | sha256sum | awk '{print $1}'`)
    .toString().trim();

  const expiry = Math.floor(Date.now() / 1000) + 900;

  // Remove stale unused OTPs for this address, then insert a fresh one
  execSync(`${MYSQL} -e "DELETE FROM email_otp WHERE email='${EMAIL}' AND used_at IS NULL;"`);
  execSync(`${MYSQL} -e "INSERT INTO email_otp (id, email, code_hash, expires_at, ip_addr) VALUES (UUID(), '${EMAIL}', '${hash}', ${expiry}, '127.0.0.1');"`);

  // Intercept the OTP request so no actual email is sent
  await page.route("**/admin/auth/otp/request", route =>
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({ message: "Code sent (intercepted by test)" }),
    })
  );

  await page.goto("/login");
  await expect(page.getByText("Continue with Email code")).toBeVisible({ timeout: 10000 });
  await page.getByText("Continue with Email code").click();

  await page.getByLabel("Email address").fill(EMAIL);
  await page.getByRole("button", { name: "Send code" }).click();

  await expect(page.getByLabel("6-digit code")).toBeVisible({ timeout: 8000 });
  await page.getByLabel("6-digit code").fill(CODE);
  await page.getByRole("button", { name: "Sign in" }).click();

  // Members and viewers land on /chat; admin / tenant_admin on /dashboard.
  await expect(page).toHaveURL(/\/(dashboard|chat|$)/, { timeout: 15000 });

  await page.context().storageState({ path: SESSION });
});
