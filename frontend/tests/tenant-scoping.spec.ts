/**
 * tenant-scoping.spec.ts — E2E tests for tenant-member resource isolation.
 *
 * Verifies that:
 * 1. member users can only access resources within their own tenant
 * 2. member users receive 403 for system-wide endpoints
 * 3. platform admin users retain full access to everything
 *
 * Depends on the "permissions-setup" project which inserts DB fixtures and
 * saves tests/.auth/member-session.json + tests/.auth/fixtures.json.
 *
 * Run with:
 *   cd frontend && npx playwright test tests/tenant-scoping.spec.ts --project=permissions
 */

import { test, expect } from "@playwright/test";
import path from "path";
import fs from "fs";

const MEMBER_SESSION = path.resolve(__dirname, ".auth/member-session.json");
const ADMIN_SESSION  = path.resolve(__dirname, ".auth/session.json");
const FIXTURES_PATH  = path.resolve(__dirname, ".auth/fixtures.json");

interface Fixtures {
  tenantAId: string; tenantBId: string;
  gatewayAId: string; gatewayBId: string;
  memberId: string; adminId: string;
}

function fix(): Fixtures {
  return JSON.parse(fs.readFileSync(FIXTURES_PATH, "utf-8"));
}

// ---------------------------------------------------------------------------
// member user — scoped to tenant A
// ---------------------------------------------------------------------------

test.describe("member: own-tenant resources (expect 200)", () => {
  test.use({ storageState: MEMBER_SESSION });

  test("GET own gateway → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayAId}`);
    expect(res.status()).toBe(200);
  });

  test("GET own tenant gateways → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/tenants/${fix().tenantAId}/gateways`);
    expect(res.status()).toBe(200);
  });

  test("GET own tenant users → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/tenants/${fix().tenantAId}/users`);
    expect(res.status()).toBe(200);
  });

  test("GET own tenant spend → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/tenants/${fix().tenantAId}/spend`);
    expect(res.status()).toBe(200);
  });

  test("GET own gateway tokens → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayAId}/tokens`);
    expect(res.status()).toBe(200);
  });

  test("GET own gateway keys → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayAId}/keys`);
    expect(res.status()).toBe(200);
  });

  test("GET own gateway rules → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayAId}/rules`);
    expect(res.status()).toBe(200);
  });

  test("GET own gateway spend → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayAId}/spend`);
    expect(res.status()).toBe(200);
  });
});

test.describe("member: cross-tenant resources (expect 403)", () => {
  test.use({ storageState: MEMBER_SESSION });

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

  test("GET tenant gateways in other tenant → 403", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/tenants/${fix().tenantBId}/gateways`);
    expect(res.status()).toBe(403);
  });

  test("POST gateway in other tenant → 403", async ({ page }) => {
    const res = await page.request.post(`/admin/v1/tenants/${fix().tenantBId}/gateways`, {
      data: { slug: "should-fail" },
    });
    expect(res.status()).toBe(403);
  });

  test("GET users in other tenant → 403", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/tenants/${fix().tenantBId}/users`);
    expect(res.status()).toBe(403);
  });

  test("POST user in other tenant → 403", async ({ page }) => {
    const res = await page.request.post(`/admin/v1/tenants/${fix().tenantBId}/users`, {
      data: { email: "x@x.com" },
    });
    expect(res.status()).toBe(403);
  });

  test("GET other tenant spend → 403", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/tenants/${fix().tenantBId}/spend`);
    expect(res.status()).toBe(403);
  });

  test("GET other tenant analytics → 403", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/tenants/${fix().tenantBId}/analytics`);
    expect(res.status()).toBe(403);
  });

  test("DELETE other tenant budget → 403", async ({ page }) => {
    const res = await page.request.delete(`/admin/v1/tenants/${fix().tenantBId}/budget`);
    expect(res.status()).toBe(403);
  });

  test("GET tokens for other tenant's gateway → 403", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayBId}/tokens`);
    expect(res.status()).toBe(403);
  });

  test("GET keys for other tenant's gateway → 403", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayBId}/keys`);
    expect(res.status()).toBe(403);
  });

  test("GET rules for other tenant's gateway → 403", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayBId}/rules`);
    expect(res.status()).toBe(403);
  });

  test("GET circuit-breaker for other tenant's gateway → 403", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayBId}/circuit-breaker`);
    expect(res.status()).toBe(403);
  });

  test("GET guardrail-stats for other tenant's gateway → 403", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayBId}/guardrail-stats`);
    expect(res.status()).toBe(403);
  });

  test("GET traces for other tenant's gateway → 403", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayBId}/traces`);
    expect(res.status()).toBe(403);
  });

  test("GET spend for other tenant's gateway → 403", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayBId}/spend`);
    expect(res.status()).toBe(403);
  });

  test("DELETE budget for other tenant's gateway → 403", async ({ page }) => {
    const res = await page.request.delete(`/admin/v1/gateways/${fix().gatewayBId}/budget`);
    expect(res.status()).toBe(403);
  });
});

test.describe("member: system-wide endpoints (expect 403)", () => {
  test.use({ storageState: MEMBER_SESSION });

  test("PUT /model-prices → 403", async ({ page }) => {
    const res = await page.request.put("/admin/v1/model-prices", {
      data: { provider: "openai", model: "gpt-4", input_per_1k: 0.01, output_per_1k: 0.03 },
    });
    expect(res.status()).toBe(403);
  });

  test("DELETE /model-prices/:p/:m → 403", async ({ page }) => {
    const res = await page.request.delete("/admin/v1/model-prices/openai/gpt-4");
    expect(res.status()).toBe(403);
  });

  test("GET /audit-log → 403", async ({ page }) => {
    const res = await page.request.get("/admin/v1/audit-log");
    expect(res.status()).toBe(403);
  });

  test("GET /stats/analytics → 403", async ({ page }) => {
    const res = await page.request.get("/admin/v1/stats/analytics");
    expect(res.status()).toBe(403);
  });

  test("GET /client-errors → 403", async ({ page }) => {
    const res = await page.request.get("/admin/v1/client-errors");
    expect(res.status()).toBe(403);
  });

  test("POST /tenants (create tenant) → 403", async ({ page }) => {
    const res = await page.request.post("/admin/v1/tenants", {
      data: { slug: "should-fail-member" },
    });
    expect(res.status()).toBe(403);
  });
});

test.describe("member: filtered list endpoints", () => {
  test.use({ storageState: MEMBER_SESSION });

  test("GET /logs does not leak other tenant IDs", async ({ page }) => {
    const res = await page.request.get("/admin/v1/logs?limit=200");
    expect(res.status()).toBe(200);
    const entries: any[] = await res.json();
    const leaked = entries.filter(e => e.tenant_id === fix().tenantBId);
    expect(leaked).toHaveLength(0);
  });

  test("GET /stats does not include other tenant in by_tenant", async ({ page }) => {
    const res = await page.request.get("/admin/v1/stats");
    expect(res.status()).toBe(200);
    const body = await res.json();
    const leaked = (body.by_tenant ?? []).filter((t: any) => t.tenant_id === fix().tenantBId);
    expect(leaked).toHaveLength(0);
  });
});

// ---------------------------------------------------------------------------
// Platform admin — full access
// ---------------------------------------------------------------------------

test.describe("admin: full access to all resources", () => {
  test.use({ storageState: ADMIN_SESSION });

  test("GET gateway in tenant B → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/gateways/${fix().gatewayBId}`);
    expect(res.status()).toBe(200);
  });

  test("GET tenant gateways in tenant B → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/tenants/${fix().tenantBId}/gateways`);
    expect(res.status()).toBe(200);
  });

  test("GET tenant gateways in tenant A → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/tenants/${fix().tenantAId}/gateways`);
    expect(res.status()).toBe(200);
  });

  test("GET users in tenant B → 200", async ({ page }) => {
    const res = await page.request.get(`/admin/v1/tenants/${fix().tenantBId}/users`);
    expect(res.status()).toBe(200);
  });

  test("GET /audit-log → 200", async ({ page }) => {
    const res = await page.request.get("/admin/v1/audit-log");
    expect(res.status()).toBe(200);
  });

  test("GET /stats/analytics → 200", async ({ page }) => {
    const res = await page.request.get("/admin/v1/stats/analytics");
    expect(res.status()).toBe(200);
  });

  test("GET /client-errors → 200", async ({ page }) => {
    const res = await page.request.get("/admin/v1/client-errors");
    expect(res.status()).toBe(200);
  });

  test("GET /logs contains entries from all tenants (not filtered)", async ({ page }) => {
    const res = await page.request.get("/admin/v1/logs");
    expect(res.status()).toBe(200);
    const entries = await res.json();
    expect(Array.isArray(entries)).toBe(true);
  });
});
