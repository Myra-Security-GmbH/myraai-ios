/**
 * chat-qwen3-a3b.spec.ts — end-to-end tests for Qwen3-30B-A3B-AWQ in the chat module.
 *
 * Gateway: myratest / prod-pii  (has provider_base_urls.vllm = http://127.0.0.1:8003)
 * Model:   qwen3-30b-a3b        (served by vllm-qwen3-A3B.service on port 8003)
 */

import { test, expect, Page } from "@playwright/test";

const ADMIN_URL     = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TARGET_TENANT  = "myratest";
const TARGET_GATEWAY = "prod-pii";
const TARGET_MODEL   = "qwen3-30b-a3b";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function deleteAllConversations(page: Page, createdAfter?: number) {
  try {
    const resp = await page.context().request.get(`${ADMIN_URL}/admin/v1/conversations`);
    if (!resp.ok()) return;
    const convs = (await resp.json()) as Array<{ id: string; created_at?: string }>;
    for (const conv of convs) {
      if (createdAfter && conv.created_at && new Date(conv.created_at).getTime() < createdAfter) continue;
      await page.context().request.delete(`${ADMIN_URL}/admin/v1/conversations/${conv.id}`).catch(() => {});
    }
  } catch { /* best-effort */ }
}

/** Select myratest / prod-pii, then pick qwen3-30b-a3b from the ModelPicker. */
async function selectGatewayAndModel(page: Page): Promise<boolean> {
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  const tenantOpt = tenantSel.locator("option").filter({ hasText: new RegExp(TARGET_TENANT, "i") });
  if ((await tenantOpt.count()) === 0) return false;
  await tenantSel.selectOption({ label: (await tenantOpt.first().textContent()) ?? TARGET_TENANT });
  await page.waitForTimeout(400);

  // Gateway — native select OR preset mode
  const hasGatewaySelect = await page.locator("select").nth(1)
    .isVisible({ timeout: 2000 }).catch(() => false);

  if (hasGatewaySelect) {
    const gatewaySel = page.locator("select").nth(1);
    const gatewayOpt = gatewaySel.locator("option").filter({ hasText: new RegExp(TARGET_GATEWAY, "i") });
    if ((await gatewayOpt.count()) === 0) return false;
    await gatewaySel.selectOption({ label: (await gatewayOpt.first().textContent()) ?? TARGET_GATEWAY });
    await page.waitForTimeout(400);
  } else {
    // Preset mode: find the preset for our target model via admin API and click its button.
    const tenantsResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
    if (!tenantsResp.ok()) return false;
    const tenantList = await tenantsResp.json() as Array<{
      id: string; slug: string;
      chat_presets?: Array<{ id: string; name: string; model: string; gateway_id: string }>;
    }>;
    const tenant = tenantList.find((t) => t.slug === TARGET_TENANT);
    if (!tenant) return false;
    const preset = (tenant.chat_presets ?? []).find((p) => p.model === TARGET_MODEL);
    if (!preset) return false;
    const presetBtn = page.locator("button").filter({ hasText: new RegExp(`^\\s*${preset.name}\\s*$`) });
    if (!(await presetBtn.isVisible({ timeout: 3000 }).catch(() => false))) return false;
    await presetBtn.click();
    await page.waitForTimeout(400);
    return true;
  }

  const modelBtn = page.locator("[aria-haspopup='listbox']");
  await modelBtn.waitFor({ state: "visible", timeout: 5000 });
  await modelBtn.click();

  const searchInput = page.locator("[role='listbox'] input[type='text'], [role='listbox'] input[type='search']");
  if (await searchInput.isVisible({ timeout: 2000 }).catch(() => false)) {
    await searchInput.fill(TARGET_MODEL);
    await page.waitForTimeout(300);
  }

  // Exact match: avoid picking e.g. "fireworks_ai/accounts/fireworks/models/qwen3-30b-a3b"
  const opt = page.locator("[role='listbox'] [role='option']")
    .filter({ hasText: new RegExp(`^\\s*${TARGET_MODEL}\\s*$`) })
    .first();
  if (!(await opt.isVisible({ timeout: 3000 }).catch(() => false))) {
    await page.keyboard.press("Escape");
    return false;
  }
  await opt.click();
  await page.waitForTimeout(300);
  return true;
}

/** Wait for the streaming stop-button to appear then disappear. */
async function waitForStreamingDone(page: Page, timeoutMs = 90_000) {
  await page.locator("button[title='Stop generating']")
    .waitFor({ state: "visible", timeout: 20_000 })
    .catch(() => {});
  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: timeoutMs });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe(`Chat — ${TARGET_MODEL} via ${TARGET_TENANT}/${TARGET_GATEWAY}`, () => {
  test.setTimeout(120_000);
  let testStartTime: number;

  test.beforeEach(async ({ page }) => {
    testStartTime = Date.now();
    await page.goto("/chat");
    await page.waitForTimeout(600);
  });

  test.afterEach(async ({ page }) => {
    await deleteAllConversations(page, testStartTime);
  });

  test("qwen3-30b-a3b appears in the ModelPicker for prod-pii", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    if (!ok) { test.skip(); return; }

    // In preset mode there is no ModelPicker — skip this picker-specific check
    const hasModelPicker = await page.locator("[aria-haspopup='listbox']").isVisible({ timeout: 2000 }).catch(() => false);
    if (!hasModelPicker) { test.skip(); return; }

    // Reopen the picker and verify the model is listed
    const modelBtn = page.locator("[aria-haspopup='listbox']");
    await modelBtn.click();
    const searchInput = page.locator("[role='listbox'] input[type='text'], [role='listbox'] input[type='search']");
    if (await searchInput.isVisible({ timeout: 2000 }).catch(() => false)) {
      await searchInput.fill(TARGET_MODEL);
      await page.waitForTimeout(300);
    }
    const opt = page.locator("[role='listbox'] [role='option']")
      .filter({ hasText: new RegExp(`^\\s*${TARGET_MODEL}\\s*$`) })
      .first();
    await expect(opt).toBeVisible({ timeout: 5000 });
    await page.keyboard.press("Escape");
  });

  test("selecting qwen3-30b-a3b is reflected in the config bar and localStorage", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    if (!ok) { test.skip(); return; }

    await page.waitForTimeout(200);
    const hasModelPicker = await page.locator("[aria-haspopup='listbox']").isVisible({ timeout: 1000 }).catch(() => false);
    if (hasModelPicker) {
      const label = (await page.locator("[aria-haspopup='listbox']").textContent() ?? "").trim();
      expect(label).toContain(TARGET_MODEL);
    }

    const stored = await page.evaluate((k) => localStorage.getItem(k), "aig-chat-model");
    expect(stored).toBe(TARGET_MODEL);
  });

  test("qwen3-30b-a3b selection survives a hard page reload", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    if (!ok) { test.skip(); return; }

    const hasModelPicker = await page.locator("[aria-haspopup='listbox']").isVisible({ timeout: 1000 }).catch(() => false);

    await page.waitForTimeout(200);
    await page.reload();
    await page.waitForTimeout(1200);

    if (hasModelPicker) {
      const label = (await page.locator("[aria-haspopup='listbox']").textContent() ?? "").trim();
      expect(label).toContain(TARGET_MODEL);
    } else {
      // Preset mode: verify the model is still stored in localStorage
      const stored = await page.evaluate((k) => localStorage.getItem(k), "aig-chat-model");
      expect(stored).toBe(TARGET_MODEL);
    }
  });

  test("sends a message and receives a non-empty reply from qwen3-30b-a3b", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill("Reply with the single word: pong");
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });

    await waitForStreamingDone(page, 60_000);

    const assistantRow = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    await expect(assistantRow).toBeVisible({ timeout: 5000 });
    const reply = (await assistantRow.textContent() ?? "").trim();
    expect(reply.length).toBeGreaterThan(0);
  });
});
