import { test, expect, Page } from "@playwright/test";

// ---------------------------------------------------------------------------
// Helpers
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

/** Select the first available gateway + model from the config bar.
 *  Handles both normal mode (gateway+model selects) and preset mode
 *  (tenant has chat_presets — gateway select is replaced by preset buttons). */
async function selectFirstGateway(page: Page): Promise<boolean> {
  // Tenant select
  const tenantSel = page.locator("select").first();
  await tenantSel.waitFor({ state: "visible", timeout: 5000 });
  const tenantOptions = await tenantSel.locator("option").count();
  if (tenantOptions <= 1) return false; // only placeholder
  await tenantSel.selectOption({ index: 1 });
  await page.waitForTimeout(400);

  // Determine mode: preset mode (only 1 select remains) vs normal mode (2+ selects)
  const selectCount = await page.locator("select").count();
  if (selectCount < 2) {
    // Preset mode — click the first preset button
    const presetBtn = page.locator("[data-testid='config-preset-btn']").first();
    const visible = await presetBtn.isVisible({ timeout: 3000 }).catch(() => false);
    if (!visible) return false;
    await presetBtn.click();
    await page.waitForTimeout(300);
    return true;
  }

  // Normal mode — Gateway select
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
// localStorage persistence helpers
// ---------------------------------------------------------------------------

const LS_TENANT  = "aig-chat-tenant";
const LS_GATEWAY = "aig-chat-gateway";
const LS_MODEL   = "aig-chat-model";

/** Clear all chat localStorage keys so tests start from a known blank state. */
async function clearChatStorage(page: Page) {
  // Must navigate somewhere first so we're on the right origin
  await page.evaluate(
    ([t, g, m]) => { localStorage.removeItem(t); localStorage.removeItem(g); localStorage.removeItem(m); },
    [LS_TENANT, LS_GATEWAY, LS_MODEL],
  );
}

/** Read all three chat localStorage keys at once. */
async function readChatStorage(page: Page) {
  return page.evaluate(
    ([t, g, m]) => ({
      tenant:  localStorage.getItem(t) ?? "",
      gateway: localStorage.getItem(g) ?? "",
      model:   localStorage.getItem(m) ?? "",
    }),
    [LS_TENANT, LS_GATEWAY, LS_MODEL],
  );
}

/** Return the selected option value for a <select> element. */
async function selectValue(page: Page, index: number): Promise<string> {
  return page.locator("select").nth(index).inputValue();
}

/** True when the chat UI is showing native select dropdowns (not preset mode). */
async function isNormalMode(page: Page): Promise<boolean> {
  return (await page.locator("select").count()) >= 2;
}

/** Return the model name shown by the ModelPicker button (strips the trailing dropdown arrow). */
async function modelPickerText(page: Page): Promise<string> {
  return (await page.locator("[aria-haspopup='listbox']").textContent() ?? "")
    .trim()
    .replace(/[▾▼▽⌄\s]+$/, "")
    .trim();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Chat page — localStorage persistence", () => {
  test.beforeEach(async ({ page }) => {
    // Navigate to / first so we're on the right origin before touching storage
    await page.goto("/");
    await clearChatStorage(page);
  });

  test("writes tenant, gateway and model to localStorage immediately after selection", async ({ page }) => {
    await gotoChatPage(page);
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    // Wait for effects to flush (they run after render)
    await page.waitForTimeout(200);

    const stored = await readChatStorage(page);
    expect(stored.tenant,  "tenant id should be written").toBeTruthy();
    expect(stored.gateway, "gateway id should be written").toBeTruthy();
    expect(stored.model,   "model should be written").toBeTruthy();

    // Stored values must match what the selects actually show
    expect(stored.tenant).toBe(await selectValue(page, 0));
    if (await isNormalMode(page)) {
      expect(stored.gateway).toBe(await selectValue(page, 1));
      expect(stored.model).toBe(await modelPickerText(page));
    }
  });

  test("restores tenant, gateway and model after SPA navigation away and back", async ({ page }) => {
    await gotoChatPage(page);
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    await page.waitForTimeout(200);

    // Capture what was selected (use localStorage for gateway/model in preset mode)
    const normalMode = await isNormalMode(page);
    const tenantBefore  = await selectValue(page, 0);
    const gatewayBefore = normalMode ? await selectValue(page, 1) : (await readChatStorage(page)).gateway;
    const modelBefore   = normalMode ? await modelPickerText(page) : (await readChatStorage(page)).model;
    expect(tenantBefore).toBeTruthy();
    expect(gatewayBefore).toBeTruthy();
    expect(modelBefore).toBeTruthy();

    // SPA navigate away then back (React Router unmounts / remounts Chat)
    await page.goto("/dashboard");
    await page.waitForTimeout(200);
    await page.goto("/chat");
    // Allow time for async API calls (tenants, gateways) + React effects to settle
    await page.waitForTimeout(1200);

    const tenantAfter  = await selectValue(page, 0);
    const gatewayAfter = normalMode ? await selectValue(page, 1) : (await readChatStorage(page)).gateway;
    const modelAfter   = normalMode ? await modelPickerText(page) : (await readChatStorage(page)).model;

    expect(tenantAfter,  `tenant should be restored to ${tenantBefore}`).toBe(tenantBefore);
    expect(gatewayAfter, `gateway should be restored to ${gatewayBefore}`).toBe(gatewayBefore);
    expect(modelAfter,   `model should be restored to ${modelBefore}`).toBe(modelBefore);
  });

  test("restores tenant, gateway and model after hard page reload", async ({ page }) => {
    await gotoChatPage(page);
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    await page.waitForTimeout(200);

    const normalMode = await isNormalMode(page);
    const tenantBefore  = await selectValue(page, 0);
    const gatewayBefore = normalMode ? await selectValue(page, 1) : (await readChatStorage(page)).gateway;
    const modelBefore   = normalMode ? await modelPickerText(page) : (await readChatStorage(page)).model;

    // Hard reload (equivalent to Ctrl+F5)
    await page.reload();
    await page.waitForTimeout(1200);

    const tenantAfter  = await selectValue(page, 0);
    const gatewayAfter = normalMode ? await selectValue(page, 1) : (await readChatStorage(page)).gateway;
    const modelAfter   = normalMode ? await modelPickerText(page) : (await readChatStorage(page)).model;

    expect(tenantAfter,  `tenant should survive reload (was ${tenantBefore})`).toBe(tenantBefore);
    expect(gatewayAfter, `gateway should survive reload (was ${gatewayBefore})`).toBe(gatewayBefore);
    expect(modelAfter,   `model should survive reload (was ${modelBefore})`).toBe(modelBefore);
  });

  test("does not reset gateway when only the model changes", async ({ page }) => {
    await gotoChatPage(page);
    const ok = await selectFirstGateway(page);
    if (!ok) { test.skip(); return; }

    await page.waitForTimeout(200);
    const normalMode = await isNormalMode(page);
    const gatewayBefore = normalMode ? await selectValue(page, 1) : (await readChatStorage(page)).gateway;

    // In preset mode the model is fixed — skip the model-change step
    if (!normalMode) { test.skip(); return; }

    // Change model (open picker, pick second option if available)
    const modelPickerBtn = page.locator("[aria-haspopup='listbox']");
    await modelPickerBtn.click();
    const options = page.locator("[role='listbox'] [role='option']");
    const count = await options.count();
    if (count > 1) {
      await options.nth(1).click();
    } else {
      await page.keyboard.press("Escape");
    }
    await page.waitForTimeout(200);

    // Gateway must not have changed
    const gatewayAfter = normalMode ? await selectValue(page, 1) : (await readChatStorage(page)).gateway;
    expect(gatewayAfter, "changing model must not reset the gateway").toBe(gatewayBefore);
  });
});

test.describe("Chat page", () => {
  let testStartTime: number;
  test.beforeEach(async () => { testStartTime = Date.now(); });
  test.afterEach(async ({ page }) => {
    await deleteAllConversations(page, testStartTime);
  });

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

    // Double-click to start inline rename.
    // Use dispatchEvent to bypass Playwright's mouse simulation which can
    // interfere with React's onDoubleClick when the sidebar is dense.
    const titleEl = item.locator("[class*='conv-item-title']").first();
    await titleEl.scrollIntoViewIfNeeded();
    await titleEl.dispatchEvent("dblclick");
    const input = page.locator("[class*='conv-rename-input']");
    await expect(input).toBeVisible({ timeout: 8000 });

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
