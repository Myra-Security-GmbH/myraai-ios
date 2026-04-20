/**
 * chat-preset-switch.spec.ts
 *
 * Regression test for: switching a tenant preset inside a project conversation
 * was silently reverted after any conversations-list state update (e.g. the
 * auto-title rename that fires at the end of a model response).
 *
 * Root cause: `loadConversation()` never updated the URL `?conv=` param, so
 * `convParam` diverged from `activeConvId` after any sidebar navigation.
 * Whenever `setConversations` fired (rename, star, updated_at), the effect
 * at Chat.tsx:362 saw `activeConvId !== convParam`, found the old conversation
 * in the list, and reloaded it — resetting gateway+model to the stored values
 * and erasing the user's preset selection.
 *
 * Fix: `loadConversation()` now calls `setSearchParams({ conv: id })` so the
 * URL always mirrors `activeConvId`, and the effect guard returns early.
 *
 * Test strategy (no inference required):
 *   1. Create two conversations A and B in a project.
 *   2. Navigate to ?conv=B so convParam = B.
 *   3. Click conv A in the sidebar → loadConversation(A).
 *      Old code: convParam stays B; new code: URL updated to ?conv=A.
 *   4. Switch from "SAFE local only" to "PII claude-sonnet-4-6" preset.
 *   5. Trigger a setConversations update by renaming conv A from the sidebar.
 *      Old code: effect sees convParam(B) ≠ activeConvId(A) → reloads B,
 *                resets gateway → SAFE preset re-selected.
 *      New code: convParam = A = activeConvId → early return → PII stays.
 *   6. Assert PII preset is still selected and conv A is still active.
 */

import { test, expect, type Page } from "@playwright/test";

const ADMIN_BASE = (process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173") + "/admin/v1";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

interface TenantRow {
  id: string;
  slug: string;
  chat_presets?: Array<{ id: string; name: string; gateway_id: string; model: string; provider: string }>;
}
interface GatewayRow  { id: string; slug: string }
interface ProjectRow  { id: string; name: string }
interface ConvRow     { id: string; title: string }

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function getMyratestTenant(page: Page): Promise<TenantRow> {
  const r = await page.context().request.get(`${ADMIN_BASE}/tenants`);
  expect(r.ok(), `GET /tenants: ${await r.text()}`).toBeTruthy();
  const tenants = await r.json() as TenantRow[];
  const t = tenants.find((t) => t.slug === "myratest");
  expect(t, "myratest tenant must exist").toBeTruthy();
  return t!;
}

async function getFirstGateway(page: Page, tenantId: string): Promise<GatewayRow> {
  const r = await page.context().request.get(`${ADMIN_BASE}/tenants/${tenantId}/gateways`);
  expect(r.ok(), `GET /gateways: ${await r.text()}`).toBeTruthy();
  const gws = await r.json() as GatewayRow[];
  expect(gws.length, "at least one gateway").toBeGreaterThan(0);
  return gws[0];
}

async function createProject(page: Page, tenantId: string, name: string): Promise<string> {
  const r = await page.context().request.post(`${ADMIN_BASE}/projects`, {
    data: { name, icon: "🧪", color: "#2563eb", tenant_id: tenantId },
  });
  expect(r.ok(), `create project: ${await r.text()}`).toBeTruthy();
  return ((await r.json()) as ProjectRow).id;
}

async function deleteProject(page: Page, id: string) {
  await page.context().request.delete(`${ADMIN_BASE}/projects/${id}`).catch(() => {});
}

async function createConversation(page: Page, gatewayId: string, projectId: string, title: string): Promise<string> {
  const r = await page.context().request.post(`${ADMIN_BASE}/conversations`, {
    data: { gateway_id: gatewayId, title, project_id: projectId },
  });
  expect(r.ok(), `create conversation "${title}": ${await r.text()}`).toBeTruthy();
  return ((await r.json()) as ConvRow).id;
}

async function deleteConversation(page: Page, id: string) {
  await page.context().request.delete(`${ADMIN_BASE}/conversations/${id}`).catch(() => {});
}

async function setChatPreferences(page: Page, gatewayId: string, tenantId: string) {
  // Navigate somewhere first so localStorage is scoped to the origin
  if (!page.url().startsWith("http://localhost")) {
    await page.goto("/dashboard");
  }
  await page.evaluate(({ g, t }) => {
    localStorage.setItem("aig-chat-gateway", g);
    localStorage.setItem("aig-chat-tenant", t);
    // Clear any previously remembered preset so the default kicks in
    localStorage.removeItem("aig-chat-preset");
  }, { g: gatewayId, t: tenantId });
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

test.describe("Chat — preset switching in project conversations", () => {

  // ── 1. Preset switch persists after conversations-list update ──────────────

  test("switching preset persists after setConversations fires (regression: auto-title revert)", async ({ page }) => {
    const tenant  = await getMyratestTenant(page);
    const presets = tenant.chat_presets ?? [];

    // This test requires the myratest tenant to have at least two presets
    if (presets.length < 2) {
      test.fail(true, `myratest must have ≥2 chat_presets, found ${presets.length}`);
      return;
    }

    const presetA = presets[0]; // "SAFE local only"
    const presetB = presets[1]; // "PII claude-sonnet-4-6"

    // Create a fresh project + two conversations
    const projectId = await createProject(page, tenant.id, `preset-switch-test-${Date.now()}`);
    let convAId = "";
    let convBId = "";

    try {
      // Use presetA's gateway for both conversations (matching stored gateway_id)
      const gw = await getFirstGateway(page, tenant.id);
      convAId = await createConversation(page, presetA.gateway_id, projectId, "Conv A — preset regression");
      convBId = await createConversation(page, presetA.gateway_id, projectId, "Conv B — preset regression");

      // Set up localStorage: tenant = myratest, gateway = presetA gateway
      await setChatPreferences(page, gw.id, tenant.id);

      // Step 1: navigate to conv B → convParam = B
      await page.goto(`/chat?conv=${convBId}&project_id=${projectId}`);

      // Wait for the preset buttons to appear (tenant presets loaded)
      await expect(page.getByRole("button", { name: presetA.name })).toBeVisible({ timeout: 10000 });
      await expect(page.getByRole("button", { name: presetB.name })).toBeVisible({ timeout: 5000 });

      // Step 2: click conv A in the sidebar → loadConversation(A)
      //   Old code: convParam stays B; new code: URL → ?conv=A
      const convAEntry = page.getByRole("option").filter({ hasText: "Conv A — preset regression" });
      await expect(convAEntry).toBeVisible({ timeout: 8000 });
      await convAEntry.click();

      // Confirm conv A loaded (title or empty thread visible)
      await expect(page).toHaveURL(new RegExp(`conv=${convAId}`), { timeout: 5000 });

      // Step 3: switch to preset B
      await page.getByRole("button", { name: presetB.name }).click();

      // Preset B button must be visually selected (font-weight 600, thicker border)
      await expect(
        page.getByRole("button", { name: presetB.name })
      ).toHaveCSS("font-weight", "600", { timeout: 2000 });
      await expect(
        page.getByRole("button", { name: presetA.name })
      ).not.toHaveCSS("font-weight", "600");

      // Step 4: trigger a setConversations update by renaming conv A from the sidebar.
      //   This mimics the auto-title rename that fires after a model response.
      //   Old code: effect reloads conv B → resets gateway → preset A re-selected.
      //   New code: convParam = A = activeConvId → returns early → preset B stays.
      const convATitle = page.locator(`.conv-item-title`, { hasText: "Conv A — preset regression" }).first();

      // Fallback: if CSS module name is obfuscated, find by text inside a role=option
      const convAItem = page.getByRole("option").filter({ hasText: "Conv A — preset regression" });
      await convAItem.dblclick();

      // Rename input should be visible; type a new name and commit
      const renameInput = page.locator("input.conv-rename-input, input[class*='conv-rename']").first();
      const inputVisible = await renameInput.isVisible({ timeout: 2000 }).catch(() => false);
      if (inputVisible) {
        await renameInput.fill("Conv A — renamed");
        await page.keyboard.press("Enter");
      } else {
        // Fallback: use API rename which triggers setConversations in-app via star action
        // Star conv B to trigger setConversations
        const convBItem = page.getByRole("option").filter({ hasText: "Conv B — preset regression" });
        await convBItem.hover();
        const starBtn = convBItem.getByTitle(/star conversation/i);
        if (await starBtn.isVisible({ timeout: 1000 }).catch(() => false)) {
          await starBtn.click();
        }
      }

      // Allow React to process the state update
      await page.waitForTimeout(400);

      // Step 5: assert preset B is STILL selected and we are still on conv A
      await expect(
        page.getByRole("button", { name: presetB.name })
      ).toHaveCSS("font-weight", "600", { timeout: 3000 });
      await expect(
        page.getByRole("button", { name: presetA.name })
      ).not.toHaveCSS("font-weight", "600");

      // We must still be on conv A, not jumped back to conv B
      await expect(page).toHaveURL(new RegExp(`conv=${convAId}`));
    } finally {
      await deleteConversation(page, convAId);
      await deleteConversation(page, convBId);
      await deleteProject(page, projectId);
    }
  });

  // ── 2. Preset switch updates gateway + model immediately ───────────────────

  test("switching preset immediately updates gateway and model state", async ({ page }) => {
    const tenant  = await getMyratestTenant(page);
    const presets = tenant.chat_presets ?? [];

    if (presets.length < 2) {
      test.fail(true, `myratest must have ≥2 chat_presets, found ${presets.length}`);
      return;
    }

    const presetA = presets[0];
    const presetB = presets[1];
    const projectId = await createProject(page, tenant.id, `preset-state-test-${Date.now()}`);
    const gw = await getFirstGateway(page, tenant.id);
    let convId = "";

    try {
      convId = await createConversation(page, presetA.gateway_id, projectId, "Preset state test");
      await setChatPreferences(page, gw.id, tenant.id);
      await page.goto(`/chat?conv=${convId}&project_id=${projectId}`);

      // Wait for preset buttons
      await expect(page.getByRole("button", { name: presetA.name })).toBeVisible({ timeout: 10000 });
      await expect(page.getByRole("button", { name: presetB.name })).toBeVisible({ timeout: 5000 });

      // Preset A is selected initially
      await expect(
        page.getByRole("button", { name: presetA.name })
      ).toHaveCSS("font-weight", "600", { timeout: 3000 });

      // Switch to preset B
      await page.getByRole("button", { name: presetB.name }).click();

      // Preset B now selected, preset A deselected
      await expect(
        page.getByRole("button", { name: presetB.name })
      ).toHaveCSS("font-weight", "600", { timeout: 2000 });
      await expect(
        page.getByRole("button", { name: presetA.name })
      ).not.toHaveCSS("font-weight", "600");

      // Switch back to preset A
      await page.getByRole("button", { name: presetA.name }).click();
      await expect(
        page.getByRole("button", { name: presetA.name })
      ).toHaveCSS("font-weight", "600", { timeout: 2000 });
      await expect(
        page.getByRole("button", { name: presetB.name })
      ).not.toHaveCSS("font-weight", "600");
    } finally {
      await deleteConversation(page, convId);
      await deleteProject(page, projectId);
    }
  });

  // ── 3. Preset selection is preserved when navigating between conversations ─

  test("selected preset is preserved when navigating between conversations in sidebar", async ({ page }) => {
    const tenant  = await getMyratestTenant(page);
    const presets = tenant.chat_presets ?? [];

    if (presets.length < 2) {
      test.fail(true, `myratest must have ≥2 chat_presets, found ${presets.length}`);
      return;
    }

    const presetA = presets[0];
    const presetB = presets[1];
    const projectId = await createProject(page, tenant.id, `preset-nav-test-${Date.now()}`);
    const gw = await getFirstGateway(page, tenant.id);
    let convId1 = "";
    let convId2 = "";

    try {
      convId1 = await createConversation(page, presetA.gateway_id, projectId, "Nav test conv 1");
      convId2 = await createConversation(page, presetA.gateway_id, projectId, "Nav test conv 2");

      await setChatPreferences(page, gw.id, tenant.id);
      await page.goto(`/chat?conv=${convId1}&project_id=${projectId}`);

      await expect(page.getByRole("button", { name: presetA.name })).toBeVisible({ timeout: 10000 });

      // Switch to preset B while on conv 1
      await page.getByRole("button", { name: presetB.name }).click();
      await expect(
        page.getByRole("button", { name: presetB.name })
      ).toHaveCSS("font-weight", "600", { timeout: 2000 });

      // Navigate to conv 2 via sidebar
      const conv2Entry = page.getByRole("option").filter({ hasText: "Nav test conv 2" });
      await expect(conv2Entry).toBeVisible({ timeout: 5000 });
      await conv2Entry.click();
      await expect(page).toHaveURL(new RegExp(`conv=${convId2}`), { timeout: 5000 });

      // Preset B should still be selected (user chose it, sidebar nav should not reset it)
      // Note: navigating to a conversation that was created with presetA's gateway WILL
      // call loadConversation which syncs the gateway — but the preset button reflects
      // selectedPresetId, and only the preset-mode useEffect resets selectedPresetId.
      // Clicking the button explicitly set selectedPresetId = presetB.id so it stays.
      await expect(
        page.getByRole("button", { name: presetB.name })
      ).toHaveCSS("font-weight", "600", { timeout: 2000 });

      // Navigate back to conv 1
      const conv1Entry = page.getByRole("option").filter({ hasText: "Nav test conv 1" });
      await conv1Entry.click();
      await expect(page).toHaveURL(new RegExp(`conv=${convId1}`), { timeout: 5000 });

      // Preset B still selected
      await expect(
        page.getByRole("button", { name: presetB.name })
      ).toHaveCSS("font-weight", "600", { timeout: 2000 });
    } finally {
      await deleteConversation(page, convId1);
      await deleteConversation(page, convId2);
      await deleteProject(page, projectId);
    }
  });
});
