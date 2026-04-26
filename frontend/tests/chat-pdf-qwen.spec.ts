/**
 * chat-pdf-qwen.spec.ts — E2E tests for PDF upload + MinerU extraction via qwen3-30b-a3b.
 *
 * Gateway: myratest / prod-pii  (vLLM on http://172.28.0.1:8003)
 * Model:   qwen3-30b-a3b
 * Fixture: tests/fixtures/eiffel-tower.pdf  (2-page text PDF)
 *
 * Non-Anthropic path: frontend sends PDF to /chat/files with extract_text=true,
 * backend renders pages via MinerU (http://172.28.0.1:8084) and returns { text: markdown },
 * frontend stores as a "pdf" block which is converted to plain text before inference.
 */

import path from "path";
import { test, expect } from "./base";
import type {  Page  } from "./base";
import { deleteConversations, captureConvId } from "./helpers";

const ADMIN_URL      = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TARGET_TENANT  = "myratest";
const TARGET_GATEWAY = "prod-pii";
const TARGET_MODEL   = "qwen3-30b-a3b";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function selectGatewayAndModel(page: Page): Promise<boolean> {
  // ── Step 1: select tenant ────────────────────────────────────────────────
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  await expect(tenantSel).toContainText(TARGET_TENANT, { timeout: 10_000 });
  await tenantSel.selectOption({ label: TARGET_TENANT });
  await page.waitForTimeout(800);

  // ── Step 2: gateway — native select OR preset mode ───────────────────────
  const hasGatewaySelect = await page.locator("select").nth(1)
    .isVisible({ timeout: 2000 }).catch(() => false);

  if (hasGatewaySelect) {
    const gatewaySel = page.locator("select").nth(1);
    await expect(gatewaySel).toContainText(TARGET_GATEWAY, { timeout: 10_000 });
    await gatewaySel.selectOption({ label: TARGET_GATEWAY });
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

    const presetBtn = page.locator(`button`).filter({ hasText: new RegExp(`^\\s*${preset.name}\\s*$`) });
    if (!(await presetBtn.isVisible({ timeout: 3000 }).catch(() => false))) return false;
    await presetBtn.click();
    await page.waitForTimeout(400);
    return true;
  }

  // ── Step 3: select model via ModelPicker (non-preset mode only) ──────────
  const modelBtn = page.locator("[aria-haspopup='listbox']");
  await modelBtn.waitFor({ state: "visible", timeout: 5000 });
  await modelBtn.click();

  const searchInput = page.locator("[role='listbox'] input[type='text'], [role='listbox'] input[type='search']");
  if (await searchInput.isVisible({ timeout: 2000 }).catch(() => false)) {
    await searchInput.fill(TARGET_MODEL);
    await page.waitForTimeout(300);
  }

  // Exact match — avoids picking fireworks_ai/…/qwen3-30b-a3b
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

async function waitForStreamingDone(page: Page, timeoutMs = 120_000) {
  await page.locator("button[title='Stop generating']")
    .waitFor({ state: "visible", timeout: 30_000 })
    .catch(() => {});
  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: timeoutMs });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe(`Chat — PDF upload with ${TARGET_MODEL} via ${TARGET_TENANT}/${TARGET_GATEWAY}`, () => {
  test.setTimeout(180_000); // MinerU page rendering adds latency
  let convIds: string[] = [];
  const FIXTURE = path.resolve(__dirname, "fixtures/eiffel-tower.pdf");

  test.beforeEach(async ({ page }) => {
    await page.goto("/chat");
    await page.waitForTimeout(600);
  });

  test.afterEach(async ({ page }) => {
    const id = captureConvId(page);
    if (id) convIds.push(id);
    await deleteConversations(page, convIds);
    convIds = [];
  });

  test("attach button accepts a PDF and shows it as a chip", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    const fileInput = page.locator("input[type='file']");
    await fileInput.setInputFiles(FIXTURE);
    await page.waitForTimeout(500);

    const chip = page.locator("[class*='input-area']").getByText(/eiffel-tower\.pdf/i);
    await expect(chip).toBeVisible({ timeout: 5000 });
  });

  test("uploading a PDF and asking for a summary returns an assistant response", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    const fileInput = page.locator("input[type='file']");
    await fileInput.setInputFiles(FIXTURE);
    await page.waitForTimeout(500);

    const chip = page.locator("[class*='input-area']").getByText(/eiffel-tower\.pdf/i);
    await expect(chip).toBeVisible({ timeout: 5000 });

    await page.locator("[class*='chat-textarea']").fill("Please summarise this document in one sentence.");

    const sendBtn = page.locator("button[title='Send message']");
    await expect(sendBtn).toBeEnabled({ timeout: 3000 });
    await sendBtn.click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 30_000 });

    await waitForStreamingDone(page, 120_000);

    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    await expect(assistantBubble).toBeVisible({ timeout: 5000 });
    const reply = (await assistantBubble.textContent() ?? "").trim();
    expect(reply.length).toBeGreaterThan(20);
  });

  test("no error banner is shown after a successful PDF summarisation", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    const fileInput = page.locator("input[type='file']");
    await fileInput.setInputFiles(FIXTURE);
    await page.waitForTimeout(500);

    await page.locator("[class*='chat-textarea']").fill("Summarise in one sentence.");
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 30_000 });

    await waitForStreamingDone(page, 120_000);

    const errorBanner = page.locator("[class*='error'], [class*='alert']").filter({ hasText: /error|failed/i });
    await expect(errorBanner).toHaveCount(0, { timeout: 2000 });
  });
});
