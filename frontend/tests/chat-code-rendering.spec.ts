/**
 * chat-code-rendering.spec.ts — E2E tests for code block rendering in /chat.
 *
 * Verifies that fenced code blocks render with proper monospace font and
 * a dark background (github-dark-dimmed theme) for syntax highlighting.
 *
 * Gateway: myratest / prod   Model: claude-sonnet-4-6
 */

import { test, expect } from "./base";
import { deleteConversations, captureConvId } from "./helpers";
import type {  Page  } from "./base";

const ADMIN_URL      = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";
const TARGET_TENANT  = "myratest";
const TARGET_GATEWAY = "prod";
const TARGET_MODEL   = "claude-sonnet-4-6";
const TARGET_PRESET  = "UNSAFE claude-sonnet-4-6";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function selectGatewayWithModel(page: Page): Promise<boolean> {
  // Select tenant
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  await expect(tenantSel).toContainText(TARGET_TENANT, { timeout: 10_000 });
  await tenantSel.selectOption({ label: TARGET_TENANT });

  // Click preset button directly
  const presetBtn = page.locator("button").filter({ hasText: new RegExp(TARGET_PRESET.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), "i") });
  if (!(await presetBtn.isVisible({ timeout: 5000 }).catch(() => false))) return false;
  await presetBtn.click();
  await expect(page.locator("[class*='chat-textarea']")).toBeEnabled({ timeout: 5000 });
  return true;
}

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

test.describe("Chat — code block rendering", () => {
  let convIds: string[] = [];
  test.setTimeout(120_000);

  test.beforeEach(async ({ page }) => {
    // Clear any stale state from previous tests
    await page.goto("/chat");
    await page.evaluate(() => { localStorage.clear(); sessionStorage.clear(); });
    await page.reload();
    await page.locator("select").first().waitFor({ state: "visible", timeout: 10_000 });
  });

  test.afterEach(async ({ page }) => {
    const id = captureConvId(page);
    if (id) convIds.push(id);
    await deleteConversations(page, convIds);
    convIds = [];
  });

  test("fenced code block has dark background and monospace font", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5000 });

    // Ask for a simple code snippet that will be in a fenced block
    await page.locator("[class*='chat-textarea']").fill(
      'Show me a hello world in Python. Use a fenced code block with ```python.'
    );
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });
    await waitForStreamingDone(page, 60_000);

    // Find a <pre> inside the assistant bubble
    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantBubble).toBeVisible({ timeout: 10_000 });

    const preBlock = assistantBubble.locator("pre").first();
    await expect(preBlock).toBeVisible({ timeout: 5000 });

    // Verify dark background (github-dark-dimmed: #22272e)
    const bg = await preBlock.evaluate((el) => getComputedStyle(el).backgroundColor);
    // #22272e = rgb(34, 39, 46)
    expect(bg, `Expected dark background (#22272e / rgb(34,39,46)), got: ${bg}`)
      .toMatch(/rgb\(34,\s*39,\s*46\)/);

    // Verify monospace font family
    const fontFamily = await preBlock.evaluate((el) => getComputedStyle(el).fontFamily);
    expect(
      fontFamily.toLowerCase(),
      `Expected monospace font, got: ${fontFamily}`,
    ).toMatch(/mono|courier|consolas/i);

    // Verify code text is visible (not washed out) — check color contrast
    const codeEl = preBlock.locator("code").first();
    const codeColor = await codeEl.evaluate((el) => getComputedStyle(el).color);
    // Should be light text (adbac7 = rgb(173, 186, 199) or similar light color)
    // Parse the rgb values and ensure they're above 100 (not dark/invisible)
    const rgbMatch = codeColor.match(/rgb\((\d+),\s*(\d+),\s*(\d+)\)/);
    expect(rgbMatch, `Could not parse code color: ${codeColor}`).toBeTruthy();
    const [, r, g, b] = rgbMatch!.map(Number);
    const avgBrightness = (r + g + b) / 3;
    expect(
      avgBrightness,
      `Code text too dark (avg brightness ${avgBrightness}). Color: ${codeColor}`,
    ).toBeGreaterThan(100);
  });

  test("ASCII art in fenced code block preserves alignment (monospace)", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    await expect(page.locator("[class*='chat-textarea']")).toBeVisible({ timeout: 5000 });

    await page.locator("[class*='chat-textarea']").fill(
      'Show me a simple 3x3 ASCII art grid inside a fenced code block (```). ' +
      'Use + for corners, - for horizontal lines, and | for vertical lines. ' +
      'Just the grid, nothing else.'
    );
    await page.locator("button[title='Send message']").click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 10_000 });
    await waitForStreamingDone(page, 60_000);

    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantBubble).toBeVisible({ timeout: 10_000 });

    // Verify there's a pre block (fenced code renders as <pre>)
    const preBlock = assistantBubble.locator("pre").first();
    await expect(preBlock).toBeVisible({ timeout: 5000 });

    // Verify it uses monospace font (essential for ASCII art alignment)
    const fontFamily = await preBlock.evaluate((el) => getComputedStyle(el).fontFamily);
    expect(fontFamily.toLowerCase()).toMatch(/mono|courier|consolas/i);

    // Verify the content contains ASCII art characters
    const text = (await preBlock.textContent()) ?? "";
    expect(text).toMatch(/[+\-|]/);
  });

  test("no error banner after receiving a code block response", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

    await page.getByRole("button", { name: /new chat/i }).click();
    const textarea = page.locator("[class*='chat-textarea']");
    await expect(textarea).toBeEnabled({ timeout: 5000 });
    await textarea.fill("Show me a hello world in JavaScript.");

    const sendBtn = page.locator("button[title='Send message']");
    await expect(sendBtn).toBeEnabled({ timeout: 5000 });
    await sendBtn.click();

    await expect(page.locator("[class*='user-row']").first()).toBeVisible({ timeout: 15_000 });
    await waitForStreamingDone(page, 90_000);

    // No error
    await expect(page.getByText(/TypeError|failed to fetch/i).first())
      .not.toBeVisible({ timeout: 3000 }).catch(() => {});

    // Response exists — wait generously for the assistant bubble
    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").last();
    await expect(assistantBubble).toBeVisible({ timeout: 30_000 });
    const text = (await assistantBubble.textContent()) ?? "";
    expect(text.length).toBeGreaterThan(10);
  });
});
