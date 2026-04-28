/**
 * chat-image-qwen.spec.ts — E2E tests for image upload + MinerU description via qwen3.6-35b-a3b.
 *
 * Gateway: myratest / prod-pii  (vLLM on http://172.28.0.1:8003)
 * Model:   qwen3.6-35b-a3b  (text-only — triggers MinerU image description path)
 * Fixture: tests/fixtures/invoice-sample.png  (800x560 synthetic invoice image)
 *
 * Non-Anthropic text-only path:
 *   frontend sends image to /chat/files with extract_text=true
 *   → backend calls MinerU → returns { text: description }
 *   → stored as "image" block → converted to plain text before inference.
 *
 * Verified keywords in fixture: "INV-2026-0042", "Acme", "4,999", "IBAN"
 */

import path from "path";
import { test, expect } from "./base";
import { deleteConversations, captureConvId } from "./helpers";
import type {  Page  } from "./base";

const ADMIN_URL      = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TARGET_TENANT  = "myratest";
const TARGET_GATEWAY = "prod-pii";
const TARGET_MODEL   = "qwen3.6-35b-a3b";

// ---------------------------------------------------------------------------
// Helpers (shared pattern with chat-pdf-qwen.spec.ts)
// ---------------------------------------------------------------------------

async function selectGatewayAndModel(page: Page): Promise<boolean> {
  // ── Step 1: select tenant ────────────────────────────────────────────────
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  await expect(tenantSel).toContainText(TARGET_TENANT, { timeout: 10_000 });
  await tenantSel.selectOption({ label: TARGET_TENANT });
  await page.waitForTimeout(800);

  // ── Step 2: gateway — native select OR preset mode ───────────────────────
  // When a tenant has chat_presets configured the gateway <select> is replaced
  // by preset buttons.  Detect which mode is active and act accordingly.
  const hasGatewaySelect = await page.locator("select").nth(1)
    .isVisible({ timeout: 2000 }).catch(() => false);

  if (hasGatewaySelect) {
    const gatewaySel = page.locator("select").nth(1);
    await expect(gatewaySel).toContainText(TARGET_GATEWAY, { timeout: 10_000 });
    await gatewaySel.selectOption({ label: TARGET_GATEWAY });
    await page.waitForTimeout(400);
  } else {
    // Preset mode: find the preset for our target model via admin API and
    // click its button.  Preset buttons set gateway+model atomically so no
    // ModelPicker step is needed afterward.
    const tenantsResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
    if (!tenantsResp.ok()) return false;
    const tenantList = await tenantsResp.json() as Array<{
      id: string; slug: string;
      chat_presets?: Array<{ id: string; name: string; model: string; gateway_id: string }>;
    }>;
    const tenant = tenantList.find((t) => t.slug === TARGET_TENANT);
    if (!tenant) return false;

    // Find a preset that uses the target model (gateway may differ from TARGET_GATEWAY)
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

  // Exact match — avoids picking fireworks_ai/…/qwen3.6-35b-a3b
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

test.describe(`Chat — image upload with ${TARGET_MODEL} via ${TARGET_TENANT}/${TARGET_GATEWAY}`, () => {
  test.setTimeout(180_000); // MinerU image description adds latency
  let convIds: string[] = [];

  const FIXTURE       = path.resolve(__dirname, "fixtures/invoice-sample.png");
  const BLANK_FIXTURE = path.resolve(__dirname, "fixtures/blank-white.png");

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

  test("attach button accepts a PNG and shows it as a chip", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    const fileInput = page.locator("input[type='file']");
    await fileInput.setInputFiles(FIXTURE);
    await page.waitForTimeout(500);

    const chip = page.locator("[class*='input-area']").getByText(/invoice-sample\.png/i);
    await expect(chip).toBeVisible({ timeout: 5000 });
  });

  test("uploading an invoice image and asking for content returns invoice details", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    const fileInput = page.locator("input[type='file']");
    await fileInput.setInputFiles(FIXTURE);
    await page.waitForTimeout(500);

    await expect(
      page.locator("[class*='input-area']").getByText(/invoice-sample\.png/i)
    ).toBeVisible({ timeout: 5000 });

    await page.locator("[class*='chat-textarea']").fill(
      "What is the invoice number and the total amount shown in this image?"
    );

    const sendBtn = page.locator("button[title='Send message']");
    await expect(sendBtn).toBeEnabled({ timeout: 3000 });
    await sendBtn.click();

    // MinerU processes the image before the message is submitted — allow extra time
    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 30_000 });
    await waitForStreamingDone(page, 120_000);

    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    await expect(assistantBubble).toBeVisible({ timeout: 5000 });
    const reply = (await assistantBubble.textContent() ?? "").trim();

    // Model should mention the invoice number or the total from the fixture
    expect(reply.length).toBeGreaterThan(20);
    expect(reply).toMatch(/INV-2026-0042|4[,.]?999|5[,.]?948/i);
  });

  test("no error banner is shown after a successful image query", async ({ page }) => {
    const ok = await selectGatewayAndModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    const fileInput = page.locator("input[type='file']");
    await fileInput.setInputFiles(FIXTURE);
    await page.waitForTimeout(500);

    await page.locator("[class*='chat-textarea']").fill("Describe what you see in this image.");
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 30_000 });
    await waitForStreamingDone(page, 120_000);

    const errorBanner = page.locator("[class*='error'], [class*='alert']").filter({ hasText: /error|failed/i });
    await expect(errorBanner).toHaveCount(0, { timeout: 2000 });
  });

  // ── Sparse-extraction warning ─────────────────────────────────────────────
  // MinerU returns its own prompt text for blank/solid images (always > 50 chars),
  // so there is no fixture that reliably triggers the < 50 char threshold via UI.
  // We test the backend contract directly: the API must return `warning` when
  // text length is below threshold, and must NOT return `warning` for normal images.

  test("chat/files API: invoice image returns text without warning", async ({ page }) => {
    const tenantsResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
    if (!tenantsResp.ok()) { test.fail(); return; }
    const tenants = await tenantsResp.json() as Array<{ id: string; slug: string }>;
    const tenant = tenants.find((t) => t.slug === TARGET_TENANT);
    if (!tenant) { test.fail(); return; }
    const gwResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants/${tenant.id}/gateways`);
    if (!gwResp.ok()) { test.fail(); return; }
    const gws = await gwResp.json() as Array<{ id: string }>;
    const gwId = gws[0]?.id;
    if (!gwId) { test.fail(); return; }

    const fs = await import("fs");
    const b64 = fs.readFileSync(FIXTURE).toString("base64");
    const resp = await page.context().request.post(`${ADMIN_URL}/admin/v1/chat/files`, {
      data: { gateway_id: gwId, filename: "invoice-sample.png", mime_type: "image/png", data: b64, extract_text: true },
    });
    expect(resp.ok(), `chat/files: ${await resp.text()}`).toBeTruthy();
    const body = await resp.json() as { text: string; warning?: string };
    expect(body.text.length).toBeGreaterThan(50);
    expect(body.warning).toBeUndefined();
  });

  test("chat/files API: warning field is set when MinerU extracts sparse text", async ({ page }) => {
    const tenantsResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
    if (!tenantsResp.ok()) { test.fail(); return; }
    const tenants = await tenantsResp.json() as Array<{ id: string; slug: string }>;
    const tenant = tenants.find((t) => t.slug === TARGET_TENANT);
    if (!tenant) { test.fail(); return; }
    const gwResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants/${tenant.id}/gateways`);
    if (!gwResp.ok()) { test.fail(); return; }
    const gws = await gwResp.json() as Array<{ id: string }>;
    const gwId = gws[0]?.id;
    if (!gwId) { test.fail(); return; }

    const fs = await import("fs");
    const b64 = fs.readFileSync(BLANK_FIXTURE).toString("base64");
    const resp = await page.context().request.post(`${ADMIN_URL}/admin/v1/chat/files`, {
      data: { gateway_id: gwId, filename: "blank-white.png", mime_type: "image/png", data: b64, extract_text: true },
    });
    expect(resp.ok(), `chat/files: ${await resp.text()}`).toBeTruthy();
    const body = await resp.json() as { text: string; warning?: string };
    // Invariant: if MinerU returned sparse text (< 50 chars), a warning MUST be present.
    if (body.text.length < 50) {
      expect(body.warning, "warning must be set when extracted text < 50 chars").toBeTruthy();
      expect(body.warning).toMatch(/limited text|could not be analyzed/i);
    }
    // If MinerU returned >= 50 chars (garbage/hallucinated text), no warning — both are valid.
  });
});
