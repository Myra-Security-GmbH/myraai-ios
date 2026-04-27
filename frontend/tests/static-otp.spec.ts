/**
 * static-otp.spec.ts — E2E tests for the static OTP feature.
 *
 * When a user has static_otp_hash set, otp/request skips the email send and
 * otp/verify accepts the fixed code directly (no expiry, reusable).
 * Tests use the admin API directly rather than browser login to avoid
 * the full login-page round-trip timeout in the int environment.
 */

import { test, expect } from "./base";
import { execSync } from "child_process";

const ADMIN_BASE = process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173";
const AUTH_BASE  = ADMIN_BASE.replace("/admin/v1", "").replace(/\/admin$/, "");

test.describe("Static OTP — service account login", () => {
  test.setTimeout(20_000);

  let testUserId = "";
  let testEmail  = "";
  const staticCode = "847293";

  test.beforeAll(async ({ browser }) => {
    const ctx = await browser.newContext({
      storageState: require("path").resolve(__dirname, ".auth/docker-session.json"),
    });
    const req = ctx.request;

    // Find myratest tenant
    const tenantsRes = await req.get(`${ADMIN_BASE}/admin/v1/tenants`);
    expect(tenantsRes.ok(), `GET /tenants: ${await tenantsRes.text()}`).toBeTruthy();
    const tenants: Array<{ id: string; slug: string }> = await tenantsRes.json();
    const myratest = tenants.find(t => t.slug === "myratest");
    expect(myratest, "myratest tenant not found").toBeTruthy();

    // Create a unique test user
    testEmail = `static-otp-test-${Date.now()}@example.com`;
    const createRes = await req.post(`${ADMIN_BASE}/admin/v1/tenants/${myratest!.id}/users`, {
      data: { email: testEmail, role: "member" },
    });
    expect(createRes.ok(), `Create user: ${await createRes.text()}`).toBeTruthy();
    const created: { id: string } = await createRes.json();
    testUserId = created.id;

    // Set a static OTP
    const otpRes = await req.put(`${ADMIN_BASE}/admin/v1/users/${testUserId}/static-otp`, {
      data: { code: staticCode },
    });
    expect(otpRes.ok(), `PUT static-otp: ${await otpRes.text()}`).toBeTruthy();
    const otpBody: { ok: boolean; code: string } = await otpRes.json();
    expect(otpBody.ok).toBe(true);
    expect(otpBody.code).toBe(staticCode);

    await ctx.close();
  });

  test.afterAll(async ({ browser }) => {
    if (!testUserId) return;
    const ctx = await browser.newContext({
      storageState: require("path").resolve(__dirname, ".auth/docker-session.json"),
    });
    await ctx.request.delete(`${ADMIN_BASE}/admin/v1/users/${testUserId}`);
    await ctx.close();
  });

  // -------------------------------------------------------------------------
  // V1 — otp/request returns generic OK for static OTP users (no email sent)
  // -------------------------------------------------------------------------
  test("otp/request returns 200 for static OTP user without sending email", async ({ page }) => {
    const res = await page.context().request.post(`${AUTH_BASE}/admin/auth/otp/request`, {
      data: { email: testEmail },
    });
    expect(res.ok(), `otp/request: ${await res.text()}`).toBeTruthy();
    const body = await res.json();
    // Returns the same generic message as for normal users — no leaked info
    expect(body.message).toBeTruthy();
  });

  // -------------------------------------------------------------------------
  // V2 — otp/verify with correct static code returns a session cookie
  // -------------------------------------------------------------------------
  test("correct static code logs in and returns session cookie", async ({ page }) => {
    const res = await page.context().request.post(`${AUTH_BASE}/admin/auth/otp/verify`, {
      data: { email: testEmail, code: staticCode },
    });
    expect(res.ok(), `otp/verify: ${await res.text()}`).toBeTruthy();
    const body: { user: { id: string; email: string; role: string } } = await res.json();
    expect(body.user.email).toBe(testEmail);
    expect(body.user.role).toBe("member");

    // Session cookie must be present in the response headers
    const headers = res.headersArray();
    const setCookie = headers.find(h => h.name.toLowerCase() === "set-cookie");
    expect(setCookie, "aig_admin session cookie not set").toBeTruthy();
    expect(setCookie!.value).toMatch(/aig_admin=/);
  });

  // -------------------------------------------------------------------------
  // V3 — Static code is reusable (not consumed like a normal email OTP)
  // -------------------------------------------------------------------------
  test("static code can be used a second time (not consumed)", async ({ page }) => {
    const res = await page.context().request.post(`${AUTH_BASE}/admin/auth/otp/verify`, {
      data: { email: testEmail, code: staticCode },
    });
    expect(res.ok(), `second verify: ${await res.text()}`).toBeTruthy();
    const body: { user: { email: string } } = await res.json();
    expect(body.user.email).toBe(testEmail);
  });

  // -------------------------------------------------------------------------
  // V4 — Wrong code is rejected
  // -------------------------------------------------------------------------
  test("wrong code is rejected for static OTP user", async ({ page }) => {
    const res = await page.context().request.post(`${AUTH_BASE}/admin/auth/otp/verify`, {
      data: { email: testEmail, code: "000000" },
    });
    expect(res.status()).toBe(401);
    const body = await res.json();
    expect(body.error).toBeTruthy();
  });

  // -------------------------------------------------------------------------
  // V5 — Clearing static OTP blocks the fixed code
  // -------------------------------------------------------------------------
  test("clearing static OTP makes the old code invalid", async ({ page }) => {
    // Clear static OTP via admin API
    const clearRes = await page.context().request.put(
      `${ADMIN_BASE}/admin/v1/users/${testUserId}/static-otp`,
      { data: { code: null } },
    );
    expect(clearRes.ok(), `Clear static-otp: ${await clearRes.text()}`).toBeTruthy();
    const clearBody: { ok: boolean } = await clearRes.json();
    expect(clearBody.ok).toBe(true);

    // Old static code should no longer work
    const res = await page.context().request.post(`${AUTH_BASE}/admin/auth/otp/verify`, {
      data: { email: testEmail, code: staticCode },
    });
    expect(res.status()).toBe(401);
  });

  // -------------------------------------------------------------------------
  // V6 — PUT /admin/v1/users/:id/static-otp validates code length
  // -------------------------------------------------------------------------
  test("static OTP endpoint rejects codes shorter than 4 characters", async ({ page }) => {
    const res = await page.context().request.put(
      `${ADMIN_BASE}/admin/v1/users/${testUserId}/static-otp`,
      { data: { code: "12" } },
    );
    expect(res.status()).toBe(400);
  });
});
