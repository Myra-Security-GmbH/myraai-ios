import { test, expect, Page } from "@playwright/test";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function gotoChatPage(page: Page) {
  await page.goto("/chat");
  // Wait for the page to settle (config bar or empty state)
  await page.waitForTimeout(600);
}

/** Click the "+ New Chat" button (or equivalent) in the conversation sidebar. */
async function clickNewChat(page: Page) {
  const btn = page.getByRole("button", { name: /new chat/i });
  await btn.waitFor({ state: "visible", timeout: 5000 });
  await btn.click();
  await page.waitForTimeout(300);
}

/** Select the first available gateway + model from the config bar. */
async function selectFirstGateway(page: Page): Promise<boolean> {
  // Tenant select
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  const tenantOptions = await tenantSel.locator("option").count();
  if (tenantOptions <= 1) return false; // only placeholder
  await tenantSel.selectOption({ index: 1 });
  await page.waitForTimeout(400);

  // Gateway select
  const gatewaySel = page.locator("select").nth(1);
  await gatewaySel.waitFor({ state: "visible", timeout: 5000 });
  const gwOptions = await gatewaySel.locator("option").count();
  if (gwOptions <= 1) return false;
  await gatewaySel.selectOption({ index: 1 });
  await page.waitForTimeout(400);

  // Model picker — open the dropdown and click the first option
  const modelPickerBtn = page.locator("[aria-haspopup='listbox']");
  await modelPickerBtn.waitFor({ state: "visible", timeout: 5000 });
  await modelPickerBtn.click();
  const firstOption = page.locator("[role='listbox'] [role='option']").first();
  const hasOptions = await firstOption.isVisible({ timeout: 3000 }).catch(() => false);
  if (!hasOptions) {
    // Close and skip model selection — tests requiring model will be skipped downstream
    await page.keyboard.press("Escape");
    return false;
  }
  await firstOption.click();
  await page.waitForTimeout(300);
  return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Chat page", () => {
  test("page loads at /chat", async ({ page }) => {
    await gotoChatPage(page);
    // Sidebar nav link exists and is active
    const nav = page.locator("[data-cy*='nav-chat']");
    await expect(nav).toBeVisible();
  });

  test("shows empty state before any conversation is selected", async ({ page }) => {
    await gotoChatPage(page);
    // Either "Start a conversation" empty state or the conversation list sidebar
    const emptyMsg = page.getByText(/start a conversation/i);
    const sidebar = page.locator("[class*='conv-sidebar']");
    const eitherVisible = (await emptyMsg.isVisible().catch(() => false)) ||
                          (await sidebar.isVisible().catch(() => false));
    expect(eitherVisible).toBe(true);
  });

  test("New Chat button is visible in the conversation sidebar", async ({ page }) => {
    await gotoChatPage(page);
    const btn = page.getByRole("button", { name: /new chat/i });
    await expect(btn).toBeVisible({ timeout: 5000 });
  });

  test("clicking New Chat creates a conversation entry in the sidebar", async ({ page }) => {
    await gotoChatPage(page);
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    await clickNewChat(page);
    // A conversation item should appear
    const items = page.locator("[class*='conv-item']");
    await expect(items.first()).toBeVisible({ timeout: 5000 });
  });

  test("conversation sidebar shows search/filter input", async ({ page }) => {
    await gotoChatPage(page);
    const searchInput = page.getByPlaceholder(/search/i);
    await expect(searchInput).toBeVisible({ timeout: 5000 });
  });

  test("can rename a conversation inline", async ({ page }) => {
    await gotoChatPage(page);
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    await clickNewChat(page);
    const item = page.locator("[class*='conv-item']").first();
    await expect(item).toBeVisible({ timeout: 5000 });

    // Double-click to start inline rename
    const titleEl = item.locator("[class*='conv-item-title']").first();
    await titleEl.dblclick();
    const input = page.locator("[class*='conv-rename-input']");
    await expect(input).toBeVisible({ timeout: 3000 });

    // Type new name and confirm with Enter
    await input.fill("My renamed chat");
    await input.press("Enter");
    await page.waitForTimeout(400);

    await expect(page.getByText("My renamed chat").first()).toBeVisible({ timeout: 3000 });
  });

  test("can delete a conversation from the sidebar", async ({ page }) => {
    await gotoChatPage(page);
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    await clickNewChat(page);
    // Use role="option" (each conv-item has role="option") to count only conversation rows
    const items = page.locator("[role='listbox'][aria-label='Conversations'] [role='option']");
    await expect(items.first()).toBeVisible({ timeout: 5000 });
    const countBefore = await items.count();

    // Accept the window.confirm("Delete this conversation?") dialog
    page.once("dialog", (dialog) => dialog.accept());

    // The delete button is display:none until CSS :hover — use dispatchEvent to fire it
    const firstItem = items.first();
    const deleteBtn = firstItem.locator("button[title='Delete conversation']");
    await deleteBtn.waitFor({ state: "attached", timeout: 3000 });
    await deleteBtn.dispatchEvent("click");
    await page.waitForTimeout(600);

    // List should have one fewer item
    await expect(items).toHaveCount(countBefore - 1, { timeout: 3000 });
  });

  test("config bar shows tenant and gateway selects", async ({ page }) => {
    await gotoChatPage(page);
    // Two selects: tenant and gateway
    const selects = page.locator("[class*='config-bar'] select");
    await expect(selects.first()).toBeVisible({ timeout: 5000 });
  });

  test("settings gear button opens the settings drawer", async ({ page }) => {
    await gotoChatPage(page);
    const gearBtn = page.getByTitle(/settings/i).first();
    await expect(gearBtn).toBeVisible({ timeout: 5000 });
    await gearBtn.click();

    // Settings drawer should appear with system prompt, temperature, max tokens
    const drawer = page.locator("[class*='settings-drawer']");
    await expect(drawer).toBeVisible({ timeout: 3000 });
    await expect(page.getByText(/system prompt/i)).toBeVisible();
    await expect(page.getByText(/temperature/i)).toBeVisible();
    await expect(page.getByText(/max tokens/i)).toBeVisible();
  });

  test("settings drawer can be closed", async ({ page }) => {
    await gotoChatPage(page);
    const gearBtn = page.getByTitle(/settings/i).first();
    await gearBtn.click();

    const drawer = page.locator("[class*='settings-drawer']");
    await expect(drawer).toBeVisible({ timeout: 3000 });

    // Close via the X button
    const closeBtn = drawer.locator("button[title='Close']");
    await closeBtn.click();
    await expect(drawer).not.toBeVisible({ timeout: 2000 });
  });

  test("message input area is present with send button", async ({ page }) => {
    await gotoChatPage(page);
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    await clickNewChat(page);

    const textarea = page.locator("[class*='chat-textarea']");
    await expect(textarea).toBeVisible({ timeout: 5000 });

    const sendBtn = page.locator("button[title='Send message']");
    await expect(sendBtn).toBeVisible({ timeout: 3000 });
  });

  test("send button is disabled when textarea is empty", async ({ page }) => {
    await gotoChatPage(page);
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    await clickNewChat(page);

    const sendBtn = page.locator("button[title='Send message']");
    await expect(sendBtn).toBeDisabled({ timeout: 3000 });
  });

  test("send button enables when text is typed", async ({ page }) => {
    await gotoChatPage(page);
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    await clickNewChat(page);

    const textarea = page.locator("[class*='chat-textarea']");
    await textarea.fill("Hello");
    const sendBtn = page.locator("button[title='Send message']");
    await expect(sendBtn).toBeEnabled({ timeout: 2000 });
  });

  test("sending a message appends a user bubble to the thread", async ({ page }) => {
    await gotoChatPage(page);
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    await clickNewChat(page);

    const textarea = page.locator("[class*='chat-textarea']");
    await textarea.fill("Hello from the test");
    const sendBtn = page.locator("button[title='Send message']");
    await sendBtn.click();
    await page.waitForTimeout(500);

    // The user bubble should contain the text we typed
    const userBubble = page.locator("[class*='user-row']").first();
    await expect(userBubble).toBeVisible({ timeout: 5000 });
    await expect(userBubble.getByText("Hello from the test")).toBeVisible();
  });

  test("attach button is visible in the input area", async ({ page }) => {
    await gotoChatPage(page);
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    await clickNewChat(page);

    const attachBtn = page.locator("button[title*='Attach'], button[title*='attach']").first();
    await expect(attachBtn).toBeVisible({ timeout: 5000 });
  });

  test("presets section is shown in settings drawer", async ({ page }) => {
    await gotoChatPage(page);
    const gearBtn = page.getByTitle(/settings/i).first();
    await gearBtn.click();

    await expect(page.getByText("Presets", { exact: true })).toBeVisible({ timeout: 3000 });
    await expect(page.getByRole("button", { name: /save current/i })).toBeVisible();
  });
});
