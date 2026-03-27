import path from "path";
import { test, expect, Page } from "@playwright/test";

// ---------------------------------------------------------------------------
// Helpers (mirrors chat.spec.ts conventions)
// ---------------------------------------------------------------------------

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

/** Delete conversations created during this test run (best-effort cleanup). */
async function deleteAllConversations(page: Page, createdAfter?: number) {
  try {
    const resp = await page.context().request.get(`${ADMIN_URL}/admin/v1/conversations`);
    if (!resp.ok()) return;
    const convs = (await resp.json()) as Array<{ id: string; created_at?: string }>;
    for (const conv of convs) {
      if (createdAfter && conv.created_at && new Date(conv.created_at).getTime() < createdAfter) continue;
      await page.context().request.delete(`${ADMIN_URL}/admin/v1/conversations/${conv.id}`).catch(() => {});
    }
  } catch {
    // best-effort — don't fail the test on cleanup errors
  }
}

async function gotoChatPage(page: Page) {
  await page.goto("/chat");
  await page.waitForTimeout(600);
}

const TARGET_TENANT  = "myratest";
const TARGET_GATEWAY = "prod";
const TARGET_MODEL   = "claude-sonnet-4-6";

/** Select tenant "myratest", gateway "prod", then pick claude-sonnet-4-6 from the ModelPicker.
 *  Returns false if any of these are not found (test should skip). */
async function selectGatewayWithModel(page: Page): Promise<boolean> {
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  const tenantOption = tenantSel.locator(`option`).filter({ hasText: new RegExp(TARGET_TENANT, "i") });
  if ((await tenantOption.count()) === 0) return false;
  await tenantSel.selectOption({ label: await tenantOption.first().textContent() ?? TARGET_TENANT });
  await page.waitForTimeout(400);

  const gatewaySel = page.locator("select").nth(1);
  await gatewaySel.waitFor({ state: "visible", timeout: 5000 });
  const gatewayOption = gatewaySel.locator(`option`).filter({ hasText: new RegExp(TARGET_GATEWAY, "i") });
  if ((await gatewayOption.count()) === 0) return false;
  await gatewaySel.selectOption({ label: await gatewayOption.first().textContent() ?? TARGET_GATEWAY });
  await page.waitForTimeout(400);

  // Open the ModelPicker and search for claude-sonnet-4-6
  const modelBtn = page.locator("[aria-haspopup='listbox']");
  await modelBtn.waitFor({ state: "visible", timeout: 5000 });
  await modelBtn.click();

  // Type into the search box to filter
  const searchInput = page.locator("[role='listbox'] input[type='text'], [role='listbox'] input[type='search']");
  const hasSearch = await searchInput.isVisible({ timeout: 2000 }).catch(() => false);
  if (hasSearch) {
    await searchInput.fill(TARGET_MODEL);
    await page.waitForTimeout(300);
  }

  // Click the option whose text matches
  const targetOption = page.locator("[role='listbox'] [role='option']")
    .filter({ hasText: TARGET_MODEL })
    .first();
  const found = await targetOption.isVisible({ timeout: 3000 }).catch(() => false);
  if (!found) {
    await page.keyboard.press("Escape");
    return false;
  }
  await targetOption.click();
  await page.waitForTimeout(300);
  return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Chat page — .docx upload and summarisation", () => {
  test.setTimeout(90000); // allow up to 90 s for streaming responses
  const FIXTURE = path.resolve(__dirname, "fixtures/eiffel-tower.docx");
  let testStartTime: number;

  test.beforeEach(async ({ page }) => {
    testStartTime = Date.now();
    await gotoChatPage(page);
  });

  test.afterEach(async ({ page }) => {
    await deleteAllConversations(page, testStartTime);
  });

  test("attach button accepts a .docx file and shows it as a chip", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    // Start a new conversation so the input area is visible
    const newChatBtn = page.getByRole("button", { name: /new chat/i });
    await newChatBtn.waitFor({ state: "visible", timeout: 5000 });
    await newChatBtn.click();
    await page.waitForTimeout(300);

    // Upload the fixture via the hidden file input
    const fileInput = page.locator("input[type='file']");
    await fileInput.setInputFiles(FIXTURE);
    await page.waitForTimeout(500);

    // An attachment chip with the filename should appear in the input area
    const chip = page.locator("[class*='input-area']")
      .getByText(/eiffel-tower\.docx/i);
    await expect(chip).toBeVisible({ timeout: 5000 });
  });

  test("uploading a .docx and asking for a summary returns an assistant response", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    const newChatBtn = page.getByRole("button", { name: /new chat/i });
    await newChatBtn.waitFor({ state: "visible", timeout: 5000 });
    await newChatBtn.click();
    await page.waitForTimeout(300);

    // Attach the fixture
    const fileInput = page.locator("input[type='file']");
    await fileInput.setInputFiles(FIXTURE);
    await page.waitForTimeout(500);

    // Confirm chip is present before typing
    const chip = page.locator("[class*='input-area']").getByText(/eiffel-tower\.docx/i);
    await expect(chip).toBeVisible({ timeout: 5000 });

    // Type the summarisation prompt
    const textarea = page.locator("[class*='chat-textarea']");
    await textarea.fill("Please summarise this document in one sentence.");

    // Send
    const sendBtn = page.locator("button[title='Send message']");
    await expect(sendBtn).toBeEnabled({ timeout: 3000 });
    await sendBtn.click();

    // User bubble should appear with our text
    const userBubble = page.locator("[class*='user-row']").first();
    await expect(userBubble).toBeVisible({ timeout: 10000 });

    // Wait for streaming to finish — send button returns when done
    await expect(page.locator("button[title='Stop generation']")).toBeVisible({ timeout: 15000 }).catch(() => {});
    await expect(page.locator("button[title='Send message']")).toBeVisible({ timeout: 60000 });

    // Assistant bubble should now have a substantive response
    // Assistant messages use bubble-row without user-row
    const assistantBubble = page.locator("[class*='bubble-row']:not([class*='user-row'])").first();
    await expect(assistantBubble).toBeVisible({ timeout: 5000 });
    const responseText = (await assistantBubble.textContent()) ?? "";
    expect(responseText.trim().length).toBeGreaterThan(20);
  });

  test("no error banner is shown after a successful .docx summarisation", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(); return; }

    const newChatBtn = page.getByRole("button", { name: /new chat/i });
    await newChatBtn.waitFor({ state: "visible", timeout: 5000 });
    await newChatBtn.click();
    await page.waitForTimeout(300);

    const fileInput = page.locator("input[type='file']");
    await fileInput.setInputFiles(FIXTURE);
    await page.waitForTimeout(500);

    const textarea = page.locator("[class*='chat-textarea']");
    await textarea.fill("Summarise in one sentence.");

    await page.locator("button[title='Send message']").click();

    // Wait for streaming to finish — send button returns when done
    await expect(page.locator("button[title='Stop generation']")).toBeVisible({ timeout: 15000 }).catch(() => {});
    await expect(page.locator("button[title='Send message']")).toBeVisible({ timeout: 60000 });

    // No error banner should be visible
    const errorBanner = page.locator("[class*='error'], [class*='alert']").filter({ hasText: /error|failed|failed to/i });
    await expect(errorBanner).toHaveCount(0, { timeout: 2000 });
  });
});
