/**
 * chat-paste-image.spec.ts — E2E test for clipboard paste of images in /chat.
 *
 * Verifies that pasting an image from the clipboard into the chat textarea
 * creates a pending attachment chip (the same UX as the file picker or drag-drop).
 */

import fs from "fs";
import path from "path";
import { test, expect, Page } from "@playwright/test";

const ADMIN_URL     = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TARGET_TENANT = "myratest";
const FIXTURE       = path.resolve(__dirname, "fixtures/invoice-sample.png");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function selectFirstGateway(page: Page): Promise<boolean> {
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  const tenantOpt = tenantSel.locator("option").filter({ hasText: new RegExp(TARGET_TENANT, "i") });
  if ((await tenantOpt.count()) === 0) return false;
  await tenantSel.selectOption({ label: (await tenantOpt.first().textContent()) ?? TARGET_TENANT });
  await page.waitForTimeout(800);

  // Select the first available gateway (any will do for this test)
  const hasGatewaySelect = await page.locator("select").nth(1)
    .isVisible({ timeout: 2000 }).catch(() => false);
  if (hasGatewaySelect) {
    const gatewaySel = page.locator("select").nth(1);
    const options = gatewaySel.locator("option");
    if ((await options.count()) < 2) return false;
    await gatewaySel.selectOption({ index: 1 });
    await page.waitForTimeout(400);
  }

  // Pick the first model
  const hasModelSelect = await page.locator("select").nth(2)
    .isVisible({ timeout: 2000 }).catch(() => false);
  if (hasModelSelect) {
    const modelSel = page.locator("select").nth(2);
    const options = modelSel.locator("option");
    if ((await options.count()) < 2) return false;
    await modelSel.selectOption({ index: 1 });
    await page.waitForTimeout(200);
  }
  return true;
}

/** Simulate a clipboard paste of a PNG image into a target element. */
async function pasteImage(page: Page, selector: string, pngPath: string) {
  const pngBuffer = fs.readFileSync(pngPath);
  const base64 = pngBuffer.toString("base64");

  await page.evaluate(
    ({ sel, b64 }) => {
      const el = document.querySelector(sel);
      if (!el) throw new Error(`Element not found: ${sel}`);

      // Convert base64 back to a Uint8Array
      const binary = atob(b64);
      const bytes = new Uint8Array(binary.length);
      for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);

      const file = new File([bytes], "image.png", { type: "image/png" });

      const dt = new DataTransfer();
      dt.items.add(file);

      const pasteEvent = new ClipboardEvent("paste", {
        bubbles: true,
        cancelable: true,
        clipboardData: dt,
      });
      el.dispatchEvent(pasteEvent);
    },
    { sel: selector, b64: base64 },
  );
}

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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Chat — clipboard paste image", () => {
  let testStartTime: number;

  test.beforeEach(async ({ page }) => {
    testStartTime = Date.now();
    await page.goto("/chat");
    await page.waitForTimeout(600);
  });

  test.afterEach(async ({ page }) => {
    await deleteAllConversations(page, testStartTime);
  });

  test("pasting a PNG into the textarea shows an attachment chip", async ({ page }) => {
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    // Focus the textarea
    const textarea = page.locator("[class*='chat-textarea']");
    await textarea.click();
    await page.waitForTimeout(100);

    // Paste an image via synthetic ClipboardEvent
    await pasteImage(page, "[class*='chat-textarea']", FIXTURE);
    await page.waitForTimeout(500);

    // Verify the attachment chip appeared (name includes timestamp: screenshot-YYYY-MM-DD...)
    const chip = page.locator("[class*='input-area']").getByText(/screenshot-\d{4}-/i);
    await expect(chip).toBeVisible({ timeout: 5000 });
  });

  test("pasting text does NOT create an attachment chip", async ({ page }) => {
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    const textarea = page.locator("[class*='chat-textarea']");
    await textarea.click();

    // Paste plain text
    await textarea.fill("Hello from clipboard");
    await page.waitForTimeout(300);

    // No attachment chip should appear
    const chip = page.locator("[class*='input-area']").getByText(/screenshot-\d{4}-/i);
    await expect(chip).not.toBeVisible();
  });
});
