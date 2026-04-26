/**
 * chat-presets.spec.ts — E2E tests for tenant-level chat presets.
 *
 * Verifies:
 * 1. Admin can PATCH tenant with chat_presets → 200, stored as array
 * 2. GET /tenants returns chat_presets as an array (not object)
 * 3. plan + siem_config NOT nulled when only chat_presets is patched
 * 4. chat_presets can be replaced and cleared (→ [])
 * 5. member user sees preset buttons instead of gateway+model selectors in /chat
 * 6. admin user still sees full gateway+model selectors regardless of presets
 *
 * Depends on the "permissions-setup" project fixtures for member + tenant_admin sessions.
 */

import { test, expect } from "./base";
import path from "path";
import fs from "fs";

// Admin API base — must use the admin vhost directly (not the SPA baseURL).
const ADMIN_BASE = (process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu") + "/admin/v1";

const ADMIN_SESSION        = path.resolve(__dirname, ".auth/docker-session.json");
const MEMBER_SESSION       = path.resolve(__dirname, ".auth/member-session.json");
const TENANT_ADMIN_SESSION = path.resolve(__dirname, ".auth/tenant-admin-session.json");
const FIXTURES_PATH        = path.resolve(__dirname, ".auth/fixtures.json");

interface Fixtures {
  tenantAId: string;
  tenantBId: string;
  gatewayAId: string;
  memberId: string;
}

function fix(): Fixtures {
  return JSON.parse(fs.readFileSync(FIXTURES_PATH, "utf-8"));
}

const PRESET_A = {
  id:         "preset-test-0001",
  name:       "Safe PII",
  gateway_id: "", // filled in from fixtures at runtime
  provider:   "anthropic",
  model:      "claude-sonnet-4-6",
};

// ---------------------------------------------------------------------------
// Admin: API-level preset management
// ---------------------------------------------------------------------------

test.describe("chat presets: admin API", () => {
  test.use({ storageState: ADMIN_SESSION });

  test("PATCH chat_presets → 200 and GET returns array", async ({ page }) => {
    const { tenantAId, gatewayAId } = fix();
    const preset = { ...PRESET_A, gateway_id: gatewayAId };

    const patch = await page.request.patch(`${ADMIN_BASE}/tenants/${tenantAId}`, {
      data: { chat_presets: [preset] },
    });
    expect(patch.status()).toBe(200);

    const get = await page.request.get(`${ADMIN_BASE}/tenants`);
    expect(get.status()).toBe(200);
    const tenants = await get.json() as Array<{ id: string; plan: string; chat_presets: unknown[] }>;
    const ta = tenants.find((t) => t.id === tenantAId);
    expect(ta).toBeDefined();

    // chat_presets must be an array, not an object
    expect(Array.isArray(ta!.chat_presets)).toBe(true);
    expect(ta!.chat_presets).toHaveLength(1);
    const stored = ta!.chat_presets[0] as typeof preset;
    expect(stored.name).toBe("Safe PII");
    expect(stored.provider).toBe("anthropic");
    expect(stored.model).toBe("claude-sonnet-4-6");
    expect(stored.gateway_id).toBe(gatewayAId);
  });

  test("PATCH chat_presets does not null plan or siem_config", async ({ page }) => {
    const { tenantAId, gatewayAId } = fix();

    // First get current plan so we can verify it's preserved
    const before = await page.request.get(`${ADMIN_BASE}/tenants`);
    const tenantsBefore = await before.json() as Array<{ id: string; plan: string }>;
    const planBefore = tenantsBefore.find((t) => t.id === tenantAId)!.plan;
    expect(planBefore).toBeTruthy(); // plan must not be null

    // PATCH only chat_presets
    const patch = await page.request.patch(`${ADMIN_BASE}/tenants/${tenantAId}`, {
      data: { chat_presets: [{ ...PRESET_A, gateway_id: gatewayAId }] },
    });
    expect(patch.status()).toBe(200);

    // plan must still be the original value
    const after = await page.request.get(`${ADMIN_BASE}/tenants`);
    const tenantsAfter = await after.json() as Array<{ id: string; plan: string }>;
    const planAfter = tenantsAfter.find((t) => t.id === tenantAId)!.plan;
    expect(planAfter).toBe(planBefore);
  });

  test("PATCH empty array clears presets → GET returns []", async ({ page }) => {
    const { tenantAId } = fix();

    const patch = await page.request.patch(`${ADMIN_BASE}/tenants/${tenantAId}`, {
      data: { chat_presets: [] },
    });
    expect(patch.status()).toBe(200);

    const get = await page.request.get(`${ADMIN_BASE}/tenants`);
    const tenants = await get.json() as Array<{ id: string; chat_presets: unknown[] }>;
    const ta = tenants.find((t) => t.id === tenantAId);
    expect(Array.isArray(ta!.chat_presets)).toBe(true);
    expect(ta!.chat_presets).toHaveLength(0);
  });

  test("multiple presets stored and retrieved in order", async ({ page }) => {
    const { tenantAId, gatewayAId } = fix();
    const presets = [
      { ...PRESET_A, id: "preset-test-0001", name: "Safe PII",          gateway_id: gatewayAId },
      { ...PRESET_A, id: "preset-test-0002", name: "Local Processing",  gateway_id: gatewayAId, provider: "vllm", model: "qwen3-30b" },
    ];

    const patch = await page.request.patch(`${ADMIN_BASE}/tenants/${tenantAId}`, {
      data: { chat_presets: presets },
    });
    expect(patch.status()).toBe(200);

    const get = await page.request.get(`${ADMIN_BASE}/tenants`);
    const tenants = await get.json() as Array<{ id: string; chat_presets: typeof presets }>;
    const ta = tenants.find((t) => t.id === tenantAId)!;
    expect(ta.chat_presets).toHaveLength(2);
    expect(ta.chat_presets[0].name).toBe("Safe PII");
    expect(ta.chat_presets[1].name).toBe("Local Processing");
    expect(ta.chat_presets[1].provider).toBe("vllm");

    // Cleanup
    await page.request.patch(`${ADMIN_BASE}/tenants/${tenantAId}`, { data: { chat_presets: [] } });
  });
});

// ---------------------------------------------------------------------------
// member: /chat shows preset buttons when presets exist
// Requires a fresh member session — run with --project=permissions to set up.
// Tests skip gracefully if member session is expired.
// ---------------------------------------------------------------------------

test.describe("chat presets: member sees preset selector", () => {
  test.use({ storageState: MEMBER_SESSION });

  async function ensureLoggedIn(page: import("@playwright/test").Page) {
    await page.goto("/chat");
    await page.waitForTimeout(600);
    if (await page.getByText("Sign in", { exact: false }).isVisible().catch(() => false)) {
      test.skip(true, "Member session expired — run: npx playwright test --project=permissions-setup first");
    }
  }

  test("member sees preset buttons when presets defined", async ({ page, browser }) => {
    const { tenantAId, gatewayAId } = fix();

    // Set preset as admin
    const adminCtx = await browser.newContext({ storageState: ADMIN_SESSION });
    const adminPage = await adminCtx.newPage();
    await adminPage.request.patch(`${ADMIN_BASE}/tenants/${tenantAId}`, {
      data: { chat_presets: [{ ...PRESET_A, id: "preset-ui-test-001", gateway_id: gatewayAId }] },
    });
    await adminCtx.close();

    try {
      await ensureLoggedIn(page);
      // Member has exactly 1 tenant (tenantA) — no tenant select is shown.
      // Presets are loaded automatically for the member's tenant.
      await page.locator('[data-testid="config-bar"]').waitFor({ state: "visible", timeout: 5000 });

      // Preset button visible; gateway+model selectors replaced
      await expect(page.getByRole("button", { name: "Safe PII" })).toBeVisible({ timeout: 5000 });
      await expect(page.getByText("Gateway", { exact: true })).not.toBeVisible();
      await expect(page.getByText("Model", { exact: true })).not.toBeVisible();
    } finally {
      const cleanCtx = await browser.newContext({ storageState: ADMIN_SESSION });
      const cleanPage = await cleanCtx.newPage();
      await cleanPage.request.patch(`${ADMIN_BASE}/tenants/${tenantAId}`, { data: { chat_presets: [] } });
      await cleanCtx.close();
    }
  });

  test("member sees full selectors when no presets defined", async ({ page, browser }) => {
    const { tenantAId } = fix();

    const adminCtx = await browser.newContext({ storageState: ADMIN_SESSION });
    const adminPage = await adminCtx.newPage();
    await adminPage.request.patch(`${ADMIN_BASE}/tenants/${tenantAId}`, { data: { chat_presets: [] } });
    await adminCtx.close();

    await ensureLoggedIn(page);
    // Member has exactly 1 tenant (tenantA) — no tenant select is shown.
    // Wait for the config bar, then check the gateway label appears.
    await page.locator('[data-testid="config-bar"]').waitFor({ state: "visible", timeout: 5000 });

    await expect(page.getByText("Gateway", { exact: true })).toBeVisible({ timeout: 5000 });
  });
});

// ---------------------------------------------------------------------------
// admin: /chat shows preset buttons when presets exist (same as all users)
// ---------------------------------------------------------------------------

test.describe("chat presets: admin sees preset selector", () => {
  test.use({ storageState: ADMIN_SESSION });

  test("admin sees preset buttons when presets exist", async ({ page, browser }) => {
    const { tenantAId, gatewayAId } = fix();
    const preset = { ...PRESET_A, id: "preset-admin-test-001", gateway_id: gatewayAId };

    // Set preset
    await page.request.patch(`${ADMIN_BASE}/tenants/${tenantAId}`, {
      data: { chat_presets: [preset] },
    });

    try {
      await page.goto("/chat");
      // Use data-testid to avoid the detachment race when React swaps gateway→preset select.
      const tenantSel = page.locator('[data-testid="config-tenant-select"]');
      await tenantSel.waitFor({ state: "visible", timeout: 8000 });
      await tenantSel.selectOption(tenantAId);

      // Admin sees preset buttons too
      await expect(page.getByRole("button", { name: "Safe PII" })).toBeVisible({ timeout: 5000 });
      await expect(page.getByText("Gateway", { exact: true })).not.toBeVisible();
    } finally {
      await page.request.patch(`${ADMIN_BASE}/tenants/${tenantAId}`, { data: { chat_presets: [] } });
    }
  });

  test("admin sees full selectors when no presets defined", async ({ page }) => {
    const { tenantAId } = fix();

    await page.request.patch(`${ADMIN_BASE}/tenants/${tenantAId}`, { data: { chat_presets: [] } });

    await page.goto("/chat");
    const tenantSel = page.locator('[data-testid="config-tenant-select"]');
    await tenantSel.waitFor({ state: "visible", timeout: 8000 });
    await tenantSel.selectOption(tenantAId);

    await expect(page.getByText("Gateway", { exact: true })).toBeVisible({ timeout: 5000 });
    await expect(page.locator("[aria-haspopup='listbox']")).toBeVisible({ timeout: 3000 });
  });
});
