/**
 * tenant-admin-scoping.spec.ts — E2E tests for tenant_admin role isolation.
 *
 * Verifies that:
 * 1. tenant_admin can manage users and gateways within their own tenant
 * 2. tenant_admin is blocked from resources in other tenants
 * 3. tenant_admin cannot create new tenants (admin-only)
 * 4. tenant_admin cannot assign roles beyond their own level
 *
 * Depends on the "permissions-setup" project which inserts DB fixtures and
 * saves tests/.auth/tenant-admin-session.json.
 */

import { test, expect } from "@playwright/test";
import path from "path";
import fs from "fs";

const TENANT_ADMIN_SESSION = path.resolve(__dirname, ".auth/tenant-admin-session.json");
const FIXTURES_PATH        = path.resolve(__dirname, ".auth/fixtures.json");

interface Fixtures {
  tenantAId: string; tenantBId: string;
  gatewayAId: string; gatewayBId: string;
  memberId: string; adminId: string;
}

function fix(): Fixtures {
  return JSON.parse(fs.readFileSync(FIXTURES_PATH, "utf-8"));
}

test.use({ storageState: TENANT_ADMIN_SESSION });

// ---------------------------------------------------------------------------
// Own-tenant access (should succeed)
// ---------------------------------------------------------------------------

test.describe("tenant_admin: own-tenant resources (expect 200/201)", () => {

  test("GET own tenant users → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/tenants/${fix().tenantAId}/users`);
    expect(res.status()).toBe(200);
  });

  test("GET own tenant gateways → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/tenants/${fix().tenantAId}/gateways`);
    expect(res.status()).toBe(200);
  });

  test("GET own gateway → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayAId}`);
    expect(res.status()).toBe(200);
  });

  test("PATCH own gateway config → 200", async ({ page }) => {
    const res = await page.request.patch(`/admin/v1/gateways/${fix().gatewayAId}`, {
      data: { config: {} },
    });
    expect(res.status()).toBe(200);
  });

  test("GET own gateway tokens → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayAId}/tokens`);
    expect(res.status()).toBe(200);
  });

  test("GET own tenant spend → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/tenants/${fix().tenantAId}/spend`);
    expect(res.status()).toBe(200);
  });
});

// ---------------------------------------------------------------------------
// Cross-tenant access (should be denied)
// ---------------------------------------------------------------------------

test.describe("tenant_admin: cross-tenant resources (expect 403)", () => {

  test("GET users in other tenant → 403", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/tenants/${fix().tenantBId}/users`);
    expect(res.status()).toBe(403);
  });

  test("POST user in other tenant → 403", async ({ page }) => {
    const res = await page.request.post(`/admin/v1/tenants/${fix().tenantBId}/users`, {
      data: { email: "x@x.com", role: "member" },
    });
    expect(res.status()).toBe(403);
  });

  test("GET gateway in other tenant → 403", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayBId}`);
    expect(res.status()).toBe(403);
  });

  test("PATCH gateway in other tenant → 403", async ({ page }) => {
    const res = await page.request.patch(`/admin/v1/gateways/${fix().gatewayBId}`, {
      data: { config: {} },
    });
    expect(res.status()).toBe(403);
  });

  test("DELETE gateway in other tenant → 403", async ({ page }) => {
    const res = await page.request.delete(`/admin/v1/gateways/${fix().gatewayBId}`);
    expect(res.status()).toBe(403);
  });

  test("GET spend for other tenant → 403", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/tenants/${fix().tenantBId}/spend`);
    expect(res.status()).toBe(403);
  });
});

// ---------------------------------------------------------------------------
// Tenant creation (admin-only)
// ---------------------------------------------------------------------------

test.describe("tenant_admin: tenant creation (expect 403)", () => {

  test("POST /tenants → 403 (only admin can create tenants)", async ({ page }) => {
    const res = await page.request.post("/admin/v1/tenants", {
      data: { slug: "should-fail-tenant-admin" },
    });
    expect(res.status()).toBe(403);
  });
});

// ---------------------------------------------------------------------------
// Role assignment limits
// ---------------------------------------------------------------------------

test.describe("tenant_admin: role assignment (own tenant)", () => {

  test("PATCH own-tenant member → member role is allowed (200)", async ({ page }) => {
    const res = await page.request.patch(`/admin/v1/users/${fix().memberId}`, {
      data: { role: "member" },
    });
    // 200 expected — tenant_admin can manage users in own tenant
    expect(res.status()).toBe(200);
  });

  test("PATCH own-tenant member → viewer role is allowed (200)", async ({ page }) => {
    const res = await page.request.patch(`/admin/v1/users/${fix().memberId}`, {
      data: { role: "viewer" },
    });
    expect(res.status()).toBe(200);
    // Restore role
    await page.request.patch(`/admin/v1/users/${fix().memberId}`, { data: { role: "member" } });
  });

  test("PATCH own-tenant user → admin role is denied (403)", async ({ page }) => {
    const res = await page.request.patch(`/admin/v1/users/${fix().memberId}`, {
      data: { role: "admin" },
    });
    // The backend validate_role_assignment blocks tenant_admin from assigning admin
    expect(res.status()).toBe(403);
  });
});

// ---------------------------------------------------------------------------
// System-wide endpoints (expect 403)
// ---------------------------------------------------------------------------

test.describe("tenant_admin: system-wide endpoints (expect 403)", () => {

  test("GET /audit-log → 403", async ({ page }) => {
    const res = await page.request.get("/admin/v1/audit-log");
    expect(res.status()).toBe(403);
  });

  test("GET /stats/analytics → 403", async ({ page }) => {
    const res = await page.request.get("/admin/v1/stats/analytics");
    expect(res.status()).toBe(403);
  });

  test("PUT /model-prices → 403", async ({ page }) => {
    const res = await page.request.put("/admin/v1/model-prices", {
      data: { provider: "openai", model: "gpt-4", input_per_1k: 0.01, output_per_1k: 0.03 },
    });
    expect(res.status()).toBe(403);
  });
});
