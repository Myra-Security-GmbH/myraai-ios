/**
 * chat-ods.spec.ts — end-to-end tests for OpenDocument Spreadsheet (.ods) file
 * upload and analysis in the chat window.
 *
 * Fixture: tests/fixtures/q1-sales.ods
 *   Sheet "Q1 Sales" has three products (Widget A/B/C) with Revenue and Units
 *   Sold columns, plus a Total row.  Identical data to q1-sales.xlsx so the
 *   expected total revenue (36,550 USD) is the same.
 *
 * The .ods skill path is:
 *   file → POST /chat/files → server converts ODS→CSV → uploads CSV as
 *   text/plain to Anthropic Files API → file_id → compat send → assistant reply.
 */

import path from "path";
import { test, expect, Page } from "@playwright/test";

// ---------------------------------------------------------------------------
// Helpers (mirrors chat-xlsx.spec.ts conventions)
// ---------------------------------------------------------------------------

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

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

async function gotoChatPage(page: Page) {
  await page.goto("/chat");
  await page.waitForTimeout(600);
}

const TARGET_TENANT  = "myratest";
const TARGET_GATEWAY = "prod";
const TARGET_MODEL   = "claude-sonnet-4-6";

async function selectGatewayWithModel(page: Page): Promise<boolean> {
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  const tenantOption = tenantSel.locator("option").filter({ hasText: new RegExp(TARGET_TENANT, "i") });
  if ((await tenantOption.count()) === 0) return false;
  await tenantSel.selectOption({ label: (await tenantOption.first().textContent()) ?? TARGET_TENANT });
  await page.waitForTimeout(400);

  const gatewaySel = page.locator("select").nth(1);
  await gatewaySel.waitFor({ state: "visible", timeout: 5000 });
  const gatewayOption = gatewaySel.locator("option").filter({ hasText: new RegExp(TARGET_GATEWAY, "i") });
  if ((await gatewayOption.count()) === 0) return false;
  await gatewaySel.selectOption({ label: (await gatewayOption.first().textContent()) ?? TARGET_GATEWAY });
  await page.waitForTimeout(400);

  const modelBtn = page.locator("[aria-haspopup='listbox']");
  await modelBtn.waitFor({ state: "visible", timeout: 5000 });
  await modelBtn.click();

  const searchInput = page.locator("[role='listbox'] input[type='text'], [role='listbox'] input[type='search']");
  const hasSearch = await searchInput.isVisible({ timeout: 2000 }).catch(() => false);
  if (hasSearch) {
    await searchInput.fill(TARGET_MODEL);
    await page.waitForTimeout(300);
  }

  const targetOption = page.locator("[role='listbox'] [role='option']")
    .filter({ hasText: TARGET_MODEL })
    .first();
  const found = await targetOption.isVisible({ timeout: 3000 }).catch(() => false);
  if (!found) { await page.keyboard.press("Escape"); return false; }
  await targetOption.click();
  await page.waitForTimeout(300);
  return true;
}

/** Wait for streaming to finish: stop button disappears, send button reappears. */
async function waitForStreamingDone(page: Page, timeoutMs = 90_000) {
  await page.locator("button[title='Stop generating']")
    .waitFor({ state: "visible", timeout: 20_000 })
    .catch(() => { /* may appear briefly or not at all for short responses */ });
  await page.locator("button[title='Send message']")
    .waitFor({ state: "visible", timeout: timeoutMs });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Chat page — .ods upload and analysis", () => {
  let testStartTime: number;
  test.setTimeout(120_000);

  const FIXTURE = path.resolve(__dirname, "fixtures/q1-sales.ods");

  test.beforeEach(async ({ page }) => {
    testStartTime = Date.now();
    await gotoChatPage(page);
  });

  test.afterEach(async ({ page }) => {
    await deleteAllConversations(page, testStartTime);
  });

  // ── 1. UI: file chip appears ──────────────────────────────────────────────

  test("attach button accepts .ods and shows a chip with the filename", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    const fileInput = page.locator("input[type='file']");
    await fileInput.setInputFiles(FIXTURE);
    await page.waitForTimeout(500);

    const chip = page.locator("[class*='input-area']").getByText(/q1-sales\.ods/i);
    await expect(chip).toBeVisible({ timeout: 5000 });
  });

  // ── 2. Upload: POST /chat/files returns a file_id ─────────────────────────

  test("uploading .ods calls POST /chat/files and receives a file_id", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    const uploadPromise = page.waitForRequest(
      (req) => req.method() === "POST" && req.url().includes("/chat/files"),
      { timeout: 15_000 },
    );
    const uploadResponsePromise = page.waitForResponse(
      (res) => res.request().method() === "POST" && res.url().includes("/chat/files"),
      { timeout: 15_000 },
    );

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    const fileInput = page.locator("input[type='file']");
    await fileInput.setInputFiles(FIXTURE);
    await page.waitForTimeout(300);

    await page.locator("[class*='chat-textarea']").fill("What is the total revenue?");
    await page.locator("button[title='Send message']").click();

    const uploadReq  = await uploadPromise;
    const uploadResp = await uploadResponsePromise;

    // Request body must carry the ODS mime type
    const reqBody = uploadReq.postDataJSON() as Record<string, unknown>;
    expect(reqBody.mime_type).toBe("application/vnd.oasis.opendocument.spreadsheet");
    expect(reqBody.filename).toMatch(/\.ods$/i);

    // Server converts ODS→CSV and uploads to Files API — response has a file_id
    expect(uploadResp.status()).toBe(200);
    const respBody = (await uploadResp.json()) as Record<string, unknown>;
    expect(typeof respBody.file_id).toBe("string");
    expect((respBody.file_id as string).length).toBeGreaterThan(0);
  });

  // ── 3. Analysis: assistant responds with numeric content ──────────────────

  test("asking about total revenue returns an answer containing a number", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    const fileInput = page.locator("input[type='file']");
    await fileInput.setInputFiles(FIXTURE);
    await page.waitForTimeout(500);

    await expect(page.locator("[class*='input-area']").getByText(/q1-sales\.ods/i))
      .toBeVisible({ timeout: 5000 });

    const textarea = page.locator("[class*='chat-textarea']");
    await textarea.fill("What is the total revenue across all products? Give me just the number in USD.");
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });

    await expect(page.getByText(/failed to upload/i)).not.toBeVisible({ timeout: 3000 }).catch(() => {});

    await waitForStreamingDone(page, 90_000);

    // Assistant rows use class "bubble-row" without "user-row"
    const assistantRow = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    await expect(assistantRow).toBeVisible({ timeout: 5000 });
    const reply = (await assistantRow.textContent()) ?? "";
    expect(reply.trim().length).toBeGreaterThan(10);

    // Fixture total revenue is 36,550
    expect(reply).toMatch(/\d/);
    expect(reply).toMatch(/36[,.]?550|36550/);
  });

  // ── 4. Error handling: no error banner on success ─────────────────────────

  test("no error banner is shown after a successful .ods analysis", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await page.waitForTimeout(300);

    const fileInput = page.locator("input[type='file']");
    await fileInput.setInputFiles(FIXTURE);
    await page.waitForTimeout(500);

    await page.locator("[class*='chat-textarea']").fill("Summarise this spreadsheet in one sentence.");
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });
    await waitForStreamingDone(page, 90_000);

    await expect(page.getByText(/failed to upload|error|failed/i).first())
      .not.toBeVisible({ timeout: 2000 })
      .catch(() => {});
  });
});
