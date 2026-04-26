import path from "path";
import { test, expect } from "./base";
import { deleteConversations, captureConvId } from "./helpers";
import type {  Page  } from "./base";

// ---------------------------------------------------------------------------
// Helpers (mirrors chat.spec.ts conventions)
// ---------------------------------------------------------------------------

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

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
  await expect(tenantSel).toContainText(TARGET_TENANT, { timeout: 10_000 });
  await tenantSel.selectOption({ label: TARGET_TENANT });
  await page.waitForTimeout(400);

  // Gateway — native select OR preset mode
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
    const presetBtn = page.locator("button").filter({ hasText: new RegExp(`^\\s*${preset.name}\\s*$`) });
    if (!(await presetBtn.isVisible({ timeout: 3000 }).catch(() => false))) return false;
    await presetBtn.click();
    await page.waitForTimeout(400);
    return true;
  }

  // Open the ModelPicker and search for target model (non-preset mode only)
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
  let convIds: string[] = [];

  test.beforeEach(async ({ page }) => {
    await gotoChatPage(page);
  });

  test.afterEach(async ({ page }) => {
    const id = captureConvId(page);
    if (id) convIds.push(id);
    await deleteConversations(page, convIds);
    convIds = [];
  });

  test("attach button accepts a .docx file and shows it as a chip", async ({ page }) => {
    const ok = await selectGatewayWithModel(page);
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

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
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

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
    if (!ok) { test.skip(true, "Required gateway or model not available in this environment"); return; }

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
