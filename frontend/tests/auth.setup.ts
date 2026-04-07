/**
 * auth.setup.ts — Playwright global setup: inserts a known OTP into the DB,
 * completes the login flow, and saves the browser session to
 * tests/.auth/session.json so all other tests start already logged in.
 *
 * Run automatically by Playwright before any test (see playwright.config.ts).
 */

import { test as setup, expect } from "@playwright/test";
import { execSync } from "child_process";
import path from "path";

const MYSQL   = "mysql -h 172.17.0.1 -u gateway -pgateway ai_gateway -e";
const EMAIL   = "info@schumann.net";
const CODE    = "999888";
const SESSION = path.resolve(__dirname, ".auth/session.json");

setup("authenticate", async ({ page }) => {
  // Compute SHA-256 of the code the same way auth_handlers.lua does
  const hash = execSync(`echo -n '${CODE}' | sha256sum | awk '{print $1}'`)
    .toString().trim();

  const expiry = Math.floor(Date.now() / 1000) + 900;
  const id     = execSync("cat /proc/sys/kernel/random/uuid").toString().trim();

  // Clean up any leftover unused OTPs for this email, then insert a fresh one
  execSync(`${MYSQL} "DELETE FROM email_otp WHERE email='${EMAIL}' AND used_at IS NULL;"`);
  execSync(`${MYSQL} "INSERT INTO email_otp (id, email, code_hash, expires_at, ip_addr) VALUES ('${id}', '${EMAIL}', '${hash}', ${expiry}, '127.0.0.1');"`);


  await page.route("**/admin/auth/otp/request", route =>
    route.fulfill({ status: 200, contentType: "application/json",
                    body: JSON.stringify({ message: "Code sent (intercepted by test)" }) })
  );

  await page.goto("/login");
  await expect(page.getByText("Continue with Email code")).toBeVisible();
  await page.getByText("Continue with Email code").click();

  await page.getByLabel("Email address").fill(EMAIL);
  await page.getByRole("button", { name: "Send code" }).click();

  // Wait for the code input step
  await expect(page.getByLabel("6-digit code")).toBeVisible();
  await page.getByLabel("6-digit code").fill(CODE);
  await page.getByRole("button", { name: "Sign in" }).click();

  // Should land on dashboard after successful login
  await expect(page).toHaveURL(/\/(dashboard|$)/, { timeout: 10000 });

  await page.context().storageState({ path: SESSION });
});
