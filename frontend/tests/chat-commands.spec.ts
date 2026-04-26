/**
 * chat-commands.spec.ts — E2E tests for personal and tenant-level slash commands.
 *
 * Coverage:
 *   Group 1  — Personal commands: CRUD via REST API
 *   Group 2  — Personal commands: My Commands page UI
 *   Group 3  — Tenant commands: REST API (slash_commands on tenant)
 *   Group 4  — Chat picker: "/" trigger, keyboard navigation, direct insert
 *   Group 5  — Variable fill modal: placeholder substitution
 *   Group 6  — Picker merges tenant + personal commands
 *   Group 7  — Validation: empty name / template, form recovery
 *   Group 8  — Boundary values: whitespace, persistence on reload, clear optional field, special chars
 *   Group 9  — Cancel delete confirmation
 *   Group 10 — Navigation: direct URL, browser back button
 *   Group 11 — Tenants page UI: Shared Commands section CRUD
 */

import { test, expect, type Page, type BrowserContext } from "./base";

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

interface TenantRow  { id: string; slug: string; plan: string; chat_presets?: unknown[]; slash_commands?: SlashCommandRow[] }
interface GatewayRow { id: string; slug: string; config: unknown }
interface ModelPriceRow { provider: string; model: string }

interface SlashCommandRow {
  id: string;
  name: string;
  description: string;
  template: string;
  created_at: string;
  updated_at: string;
}

/** Returns first tenant id + gateway id available to the session. */
async function getFirstTenantAndGateway(page: Page): Promise<{ tenantId: string; gatewayId: string; gatewaySlug: string } | null> {
  const tr = await page.request.get(`${ADMIN_URL}/admin/v1/tenants`);
  if (!tr.ok()) return null;
  const tenants = await tr.json() as TenantRow[];
  for (const t of tenants) {
    const gr = await page.request.get(`${ADMIN_URL}/admin/v1/tenants/${t.id}/gateways`);
    if (!gr.ok()) continue;
    const gws = await gr.json() as GatewayRow[];
    if (gws.length) return { tenantId: t.id, gatewayId: gws[0].id, gatewaySlug: gws[0].slug };
  }
  return null;
}

/** Returns a model string suitable for chat (prefers anthropic claude). */
async function getAModel(page: Page): Promise<string | null> {
  const r = await page.request.get(`${ADMIN_URL}/admin/v1/models`);
  if (!r.ok()) return null;
  const rows = await r.json() as ModelPriceRow[];
  const claude = rows.find((m) => m.provider === "anthropic" && m.model.startsWith("claude"));
  if (claude) return `anthropic/${claude.model}`;
  if (rows.length) return `${rows[0].provider}/${rows[0].model}`;
  return null;
}

/** Creates a personal slash command via API. Returns the created id or null. */
async function createCommand(
  page: Page,
  cmd: { name: string; description?: string; template: string }
): Promise<string | null> {
  const r = await page.request.post(`${ADMIN_URL}/admin/v1/chat-commands`, { data: cmd });
  if (!r.ok()) return null;
  return ((await r.json()) as { id: string }).id;
}

/** Deletes a personal slash command via API (best-effort). */
async function deleteCommand(page: Page, id: string) {
  await page.request.delete(`${ADMIN_URL}/admin/v1/chat-commands/${id}`).catch(() => {});
}

/** Lists personal commands via API. */
async function listCommands(page: Page): Promise<SlashCommandRow[]> {
  const r = await page.request.get(`${ADMIN_URL}/admin/v1/chat-commands`);
  if (!r.ok()) return [];
  return r.json();
}

/** Sets localStorage so the chat page starts with a gateway + model pre-selected. */
async function setChatPreferences(page: Page, gatewayId: string, model: string, tenantId: string) {
  // Must be on the app domain before accessing localStorage
  const currentUrl = page.url();
  if (currentUrl === "about:blank" || currentUrl === "") {
    await page.goto("/dashboard");
    await page.waitForLoadState("domcontentloaded");
  }
  await page.evaluate(({ g, m, t }) => {
    localStorage.setItem("aig-chat-gateway", g);
    localStorage.setItem("aig-chat-model", m);
    localStorage.setItem("aig-chat-tenant", t);
  }, { g: gatewayId, m: model, t: tenantId });
}

/** Navigates to /chat and waits for the textarea to be enabled. */
async function openChat(page: Page) {
  await page.goto("/chat");
  // Wait for the textarea to be enabled (gatewayId + model in React state).
  // localStorage was pre-populated by setChatPreferences.
  await expect(page.locator("textarea[aria-label='Message input']"))
    .toBeEnabled({ timeout: 8000 });
}

// ---------------------------------------------------------------------------
// Group 1: Personal commands — API
// ---------------------------------------------------------------------------

test.describe("commands API: personal CRUD", () => {
  let createdId: string | null = null;

  test.afterEach(async ({ page }) => {
    if (createdId) {
      await deleteCommand(page, createdId);
      createdId = null;
    }
  });

  test("POST /chat-commands → 201 with id", async ({ page }) => {
    const r = await page.request.post(`${ADMIN_URL}/admin/v1/chat-commands`, {
      data: { name: "summarize", description: "Summarize text", template: "Summarize the following: {{text}}" },
    });
    expect(r.status()).toBe(201);
    const body = await r.json() as { id: string };
    expect(typeof body.id).toBe("string");
    expect(body.id.length).toBeGreaterThan(0);
    createdId = body.id;
  });

  test("GET /chat-commands → returns created command", async ({ page }) => {
    createdId = await createCommand(page, { name: "greet", description: "Greeting", template: "Hello, {{name}}!" });
    expect(createdId).not.toBeNull();

    const rows = await listCommands(page);
    const found = rows.find((c) => c.id === createdId);
    expect(found).toBeDefined();
    expect(found!.name).toBe("greet");
    expect(found!.template).toBe("Hello, {{name}}!");
    expect(found!.description).toBe("Greeting");
  });

  test("GET /chat-commands → returns empty array when none exist", async ({ page }) => {
    // Delete all first (may already be empty)
    const before = await listCommands(page);
    for (const c of before) await deleteCommand(page, c.id);

    const rows = await listCommands(page);
    expect(Array.isArray(rows)).toBe(true);
    expect(rows).toHaveLength(0);
  });

  test("PATCH /chat-commands/:id → 200, fields updated", async ({ page }) => {
    createdId = await createCommand(page, { name: "translate", template: "Translate: {{text}}" });
    expect(createdId).not.toBeNull();

    const patch = await page.request.patch(`${ADMIN_URL}/admin/v1/chat-commands/${createdId}`, {
      data: { description: "Translate text to target language", template: "Translate to {{language}}: {{text}}" },
    });
    expect(patch.status()).toBe(200);

    const rows = await listCommands(page);
    const found = rows.find((c) => c.id === createdId);
    expect(found!.description).toBe("Translate text to target language");
    expect(found!.template).toBe("Translate to {{language}}: {{text}}");
    expect(found!.name).toBe("translate"); // unchanged
  });

  test("DELETE /chat-commands/:id → 200, removed from list", async ({ page }) => {
    const id = await createCommand(page, { name: "todelete", template: "Delete me" });
    expect(id).not.toBeNull();

    const del = await page.request.delete(`${ADMIN_URL}/admin/v1/chat-commands/${id!}`);
    expect(del.status()).toBe(200);

    const rows = await listCommands(page);
    expect(rows.find((c) => c.id === id)).toBeUndefined();
    // No cleanup needed — already deleted
    createdId = null;
  });

  test("POST without name → 400", async ({ page }) => {
    const r = await page.request.post(`${ADMIN_URL}/admin/v1/chat-commands`, {
      data: { template: "some template" },
    });
    expect(r.status()).toBe(400);
  });

  test("POST without template → 400", async ({ page }) => {
    const r = await page.request.post(`${ADMIN_URL}/admin/v1/chat-commands`, {
      data: { name: "missing-template" },
    });
    expect(r.status()).toBe(400);
  });

  test("GET /chat-commands returns results ordered by name ASC", async ({ page }) => {
    const ids: string[] = [];
    try {
      ids.push((await createCommand(page, { name: "zebra", template: "Z" }))!);
      ids.push((await createCommand(page, { name: "apple", template: "A" }))!);
      ids.push((await createCommand(page, { name: "mango", template: "M" }))!);

      const rows = await listCommands(page);
      const names = rows.map((c) => c.name);
      const inRange = names.filter((n) => ["zebra", "apple", "mango"].includes(n));
      expect(inRange).toEqual(["apple", "mango", "zebra"]);
    } finally {
      for (const id of ids) if (id) await deleteCommand(page, id);
    }
  });
});

// ---------------------------------------------------------------------------
// Group 2: My Commands page UI
// ---------------------------------------------------------------------------

test.describe("My Commands page UI", () => {
  const createdIds: string[] = [];

  test.afterEach(async ({ page }) => {
    for (const id of createdIds) await deleteCommand(page, id);
    createdIds.length = 0;
  });

  test("page renders with title and empty state", async ({ page }) => {
    // Delete any existing commands first
    const existing = await listCommands(page);
    for (const c of existing) await deleteCommand(page, c.id);

    await page.goto("/commands");
    await expect(page.getByRole("heading", { name: "My Commands" })).toBeVisible({ timeout: 5000 });
    await expect(page.getByRole("button", { name: /\+ New command/i })).toBeVisible();
    // Empty state message
    await expect(page.getByText(/No commands yet/i)).toBeVisible();
  });

  test("creates a command via UI modal and it appears in the list", async ({ page }) => {
    // Delete any existing
    const existing = await listCommands(page);
    for (const c of existing) await deleteCommand(page, c.id);

    await page.goto("/commands");
    await page.getByRole("button", { name: /\+ New command/i }).click();

    // Modal opens
    await expect(page.getByRole("heading", { name: "New Command" })).toBeVisible({ timeout: 3000 });
    const nameInput = page.getByPlaceholder("command-name");
    await nameInput.waitFor({ state: "visible", timeout: 5000 });

    // Fill form
    await nameInput.fill("mytest");
    await page.getByPlaceholder(/Short description/i).fill("My test command");
    await page.getByPlaceholder(/Use \{\{variable\}\}/i).fill("Run test for {{topic}}");

    // Variable hint should appear
    await expect(page.getByText(/Variables detected/i)).toBeVisible();
    await expect(page.locator("code").filter({ hasText: "{{topic}}" })).toBeVisible();

    // Submit
    await page.getByRole("button", { name: "Create" }).click();

    // Modal closes and command appears in table
    await expect(page.getByRole("heading", { name: "New Command" })).not.toBeVisible({ timeout: 3000 });
    await expect(page.locator("code").filter({ hasText: "/mytest" })).toBeVisible({ timeout: 5000 });
    await expect(page.getByText("My test command")).toBeVisible();

    // Capture ID for cleanup
    const rows = await listCommands(page);
    const created = rows.find((c) => c.name === "mytest");
    if (created) createdIds.push(created.id);
  });

  test("edits a command via UI and changes are reflected", async ({ page }) => {
    const id = await createCommand(page, { name: "editme", description: "Old desc", template: "Old template" });
    expect(id).not.toBeNull();
    createdIds.push(id!);

    await page.goto("/commands");
    await expect(page.locator("code").filter({ hasText: "/editme" })).toBeVisible({ timeout: 5000 });

    // Click Edit
    await page.getByRole("row", { name: /editme/ }).getByRole("button", { name: "Edit" }).click();

    // Modal opens with pre-filled values
    await expect(page.getByText("Edit Command")).toBeVisible({ timeout: 3000 });
    const descInput = page.getByPlaceholder(/Short description/i);
    await expect(descInput).toHaveValue("Old desc");

    // Update description and template
    await descInput.fill("New description");
    await page.getByPlaceholder(/Use \{\{variable\}\}/i).fill("New template {{arg}}");

    await page.getByRole("button", { name: "Save" }).click();
    await expect(page.getByText("Edit Command")).not.toBeVisible({ timeout: 3000 });

    // Updated description visible in table
    await expect(page.getByText("New description")).toBeVisible();
    // Template column shows updated value
    await expect(page.getByText("New template {{arg}}")).toBeVisible();
  });

  test("deletes a command via UI", async ({ page }) => {
    const id = await createCommand(page, { name: "kilme", template: "Kill me" });
    expect(id).not.toBeNull();
    // Don't add to createdIds — we're deleting via UI

    await page.goto("/commands");
    await expect(page.locator("code").filter({ hasText: "/kilme" })).toBeVisible({ timeout: 5000 });

    // Intercept confirm dialog
    page.once("dialog", (d) => d.accept());
    await page.getByRole("row", { name: /kilme/ }).getByRole("button", { name: "Delete" }).click();

    // Row disappears
    await expect(page.locator("code").filter({ hasText: "/kilme" })).not.toBeVisible({ timeout: 5000 });
  });

  test("sidebar shows My Commands nav link", async ({ page }) => {
    await page.goto("/commands");
    // Nav item should exist and be active
    const link = page.getByRole("link", { name: "My Commands" });
    await expect(link).toBeVisible({ timeout: 5000 });
    await expect(link).toHaveClass(/active/);
  });
});

// ---------------------------------------------------------------------------
// Group 3: Tenant commands — API
// ---------------------------------------------------------------------------

test.describe("tenant commands API", () => {
  test.describe.configure({ mode: "serial" });
  let tenantId: string;

  test.beforeAll(async ({ browser }) => {
    const page = await browser.newPage();
    const result = await getFirstTenantAndGateway(page);
    await page.close();
    if (!result) throw new Error("No tenant/gateway found");
    tenantId = result.tenantId;
  });

  test.afterEach(async ({ page }) => {
    // Clear tenant slash_commands after each test
    await page.request.patch(`${ADMIN_URL}/admin/v1/tenants/${tenantId}`, {
      data: { slash_commands: [] },
    });
  });

  test("PATCH slash_commands → 200, GET returns array", async ({ page }) => {
    const cmds = [
      { id: "t-cmd-001", name: "help", description: "Get help", template: "Help me with {{topic}}" },
    ];

    const patch = await page.request.patch(`${ADMIN_URL}/admin/v1/tenants/${tenantId}`, {
      data: { slash_commands: cmds },
    });
    expect(patch.status()).toBe(200);

    const get = await page.request.get(`${ADMIN_URL}/admin/v1/tenants`);
    const tenants = await get.json() as TenantRow[];
    const t = tenants.find((x) => x.id === tenantId);
    expect(t).toBeDefined();
    expect(Array.isArray(t!.slash_commands)).toBe(true);
    expect(t!.slash_commands).toHaveLength(1);
    expect(t!.slash_commands![0].name).toBe("help");
    expect(t!.slash_commands![0].template).toBe("Help me with {{topic}}");
  });

  test("PATCH slash_commands does NOT null plan or chat_presets", async ({ page }) => {
    // Capture current plan
    const before = await page.request.get(`${ADMIN_URL}/admin/v1/tenants`);
    const tenantsBefore = await before.json() as TenantRow[];
    const planBefore = tenantsBefore.find((t) => t.id === tenantId)!.plan;
    expect(planBefore).toBeTruthy();

    // Patch only slash_commands
    await page.request.patch(`${ADMIN_URL}/admin/v1/tenants/${tenantId}`, {
      data: { slash_commands: [{ id: "t-cmd-002", name: "status", description: "", template: "Show status" }] },
    });

    const after = await page.request.get(`${ADMIN_URL}/admin/v1/tenants`);
    const tenantsAfter = await after.json() as TenantRow[];
    const planAfter = tenantsAfter.find((t) => t.id === tenantId)!.plan;
    expect(planAfter).toBe(planBefore);
  });

  test("PATCH empty array clears slash_commands → GET returns []", async ({ page }) => {
    // First set some commands
    await page.request.patch(`${ADMIN_URL}/admin/v1/tenants/${tenantId}`, {
      data: { slash_commands: [{ id: "t-cmd-003", name: "tmp", description: "", template: "tmp" }] },
    });

    // Now clear
    const patch = await page.request.patch(`${ADMIN_URL}/admin/v1/tenants/${tenantId}`, {
      data: { slash_commands: [] },
    });
    expect(patch.status()).toBe(200);

    const get = await page.request.get(`${ADMIN_URL}/admin/v1/tenants`);
    const tenants = await get.json() as TenantRow[];
    const t = tenants.find((x) => x.id === tenantId)!;
    expect(Array.isArray(t.slash_commands)).toBe(true);
    expect(t.slash_commands).toHaveLength(0);
  });

  test("multiple tenant commands stored and retrieved", async ({ page }) => {
    const cmds = [
      { id: "t-cmd-004", name: "analyze", description: "Analyze", template: "Analyze {{document}}" },
      { id: "t-cmd-005", name: "review",  description: "Review",  template: "Review {{code}} in {{language}}" },
    ];
    await page.request.patch(`${ADMIN_URL}/admin/v1/tenants/${tenantId}`, { data: { slash_commands: cmds } });

    const get = await page.request.get(`${ADMIN_URL}/admin/v1/tenants`);
    const tenants = await get.json() as TenantRow[];
    const t = tenants.find((x) => x.id === tenantId)!;
    expect(t.slash_commands).toHaveLength(2);
    expect(t.slash_commands!.find((c) => c.name === "analyze")).toBeDefined();
    expect(t.slash_commands!.find((c) => c.name === "review")!.template).toBe("Review {{code}} in {{language}}");
  });
});

// ---------------------------------------------------------------------------
// Group 4: Chat picker UI
// ---------------------------------------------------------------------------

test.describe("chat picker UI", () => {
  test.describe.configure({ mode: "serial" });
  let gatewayId: string;
  let tenantId: string;
  let model: string;
  const personalIds: string[] = [];

  test.beforeAll(async ({ browser }) => {
    const page = await browser.newPage();
    const result = await getFirstTenantAndGateway(page);
    const mdl = await getAModel(page);
    await page.close();
    if (!result) throw new Error("No tenant/gateway found");
    if (!mdl) throw new Error("No model found");
    gatewayId = result.gatewayId;
    tenantId = result.tenantId;
    model = mdl;
  });

  test.afterEach(async ({ page }) => {
    for (const id of personalIds) await deleteCommand(page, id);
    personalIds.length = 0;
    // Clear tenant commands
    await page.request.patch(`${ADMIN_URL}/admin/v1/tenants/${tenantId}`, {
      data: { slash_commands: [] },
    }).catch(() => {});
  });

  async function setupChatWithCommand(page: Page, cmd: { name: string; template: string; description?: string }) {
    const id = await createCommand(page, cmd);
    if (id) personalIds.push(id);
    await setChatPreferences(page, gatewayId, model, tenantId);
    await openChat(page);
    return id;
  }

  test("typing '/' shows command picker", async ({ page }) => {
    await setupChatWithCommand(page, { name: "testpick", template: "Test template" });

    const textarea = page.locator("textarea[aria-label='Message input']");
    await textarea.waitFor({ state: "visible", timeout: 5000 });
    await textarea.click();
    await textarea.fill("/");

    // Picker should appear showing the command
    await expect(page.locator("[class*='picker']").first()).toBeVisible({ timeout: 3000 });
    await expect(page.getByText("/testpick")).toBeVisible({ timeout: 3000 });
  });

  test("picker filters commands by query", async ({ page }) => {
    const id1 = await createCommand(page, { name: "translate", template: "Translate: {{text}}" });
    const id2 = await createCommand(page, { name: "summarize", template: "Summarize: {{text}}" });
    if (id1) personalIds.push(id1);
    if (id2) personalIds.push(id2);

    await setChatPreferences(page, gatewayId, model, tenantId);
    await openChat(page);

    const textarea = page.locator("textarea[aria-label='Message input']");
    await textarea.waitFor({ state: "visible", timeout: 5000 });
    await textarea.fill("/tr");

    await expect(page.getByText("/translate")).toBeVisible({ timeout: 3000 });
    await expect(page.getByText("/summarize")).not.toBeVisible();
  });

  test("pressing Escape dismisses picker and clears input", async ({ page }) => {
    await setupChatWithCommand(page, { name: "escapeme", template: "Escape test" });

    const textarea = page.locator("textarea[aria-label='Message input']");
    await textarea.waitFor({ state: "visible", timeout: 5000 });
    await textarea.fill("/");

    await expect(page.getByText("/escapeme")).toBeVisible({ timeout: 3000 });

    await textarea.press("Escape");

    await expect(page.getByText("/escapeme")).not.toBeVisible({ timeout: 2000 });
    await expect(textarea).toHaveValue("");
  });

  test("selecting a command with no variables fills input directly", async ({ page }) => {
    await setupChatWithCommand(page, { name: "direct", template: "This is the direct template text." });

    const textarea = page.locator("textarea[aria-label='Message input']");
    await textarea.waitFor({ state: "visible", timeout: 5000 });
    await textarea.fill("/dir");

    await expect(page.getByText("/direct")).toBeVisible({ timeout: 3000 });

    // Click the command row
    await page.getByText("/direct").click();

    // Input should be filled with template, no modal
    await expect(textarea).toHaveValue("This is the direct template text.", { timeout: 3000 });
    await expect(page.getByText(/Fill in/)).not.toBeVisible();
  });

  test("selecting a command with variables opens VariableFillModal", async ({ page }) => {
    await setupChatWithCommand(page, { name: "vartest", template: "Translate to {{language}}: {{text}}" });

    const textarea = page.locator("textarea[aria-label='Message input']");
    await textarea.waitFor({ state: "visible", timeout: 5000 });
    await textarea.fill("/var");

    await expect(page.getByText("/vartest")).toBeVisible({ timeout: 3000 });
    await page.getByText("/vartest").click();

    // Variable fill modal should open
    await expect(page.getByText(/Fill in \/vartest/i)).toBeVisible({ timeout: 3000 });
    await expect(page.getByLabel("language")).toBeVisible();
    await expect(page.getByLabel("text")).toBeVisible();
  });

  test("keyboard navigation in picker: arrow down/up + Enter selects", async ({ page }) => {
    const id1 = await createCommand(page, { name: "aardvark", template: "AAA" });
    const id2 = await createCommand(page, { name: "alligator", template: "BBB" });
    if (id1) personalIds.push(id1);
    if (id2) personalIds.push(id2);

    await setChatPreferences(page, gatewayId, model, tenantId);
    await openChat(page);

    const textarea = page.locator("textarea[aria-label='Message input']");
    await textarea.waitFor({ state: "visible", timeout: 5000 });
    await textarea.fill("/a");

    // Both should be visible
    await expect(page.getByText("/aardvark")).toBeVisible({ timeout: 3000 });
    await expect(page.getByText("/alligator")).toBeVisible({ timeout: 3000 });

    // Arrow down to second item
    await textarea.press("ArrowDown");

    // Enter to select (second item = alligator, template = "BBB")
    await textarea.press("Enter");

    // No variables in "BBB" → direct insert
    await expect(textarea).toHaveValue("BBB", { timeout: 3000 });
  });

  test("picker not shown when input has a space after slash", async ({ page }) => {
    await setupChatWithCommand(page, { name: "nopicker", template: "No picker" });

    const textarea = page.locator("textarea[aria-label='Message input']");
    await textarea.waitFor({ state: "visible", timeout: 5000 });
    await textarea.fill("/ nopicker");

    // Picker should NOT appear — space after slash means it's not a command
    await expect(page.getByText("/nopicker")).not.toBeVisible({ timeout: 1000 });
  });

  test("picker not shown when there are no commands", async ({ page }) => {
    // Ensure no commands exist
    const existing = await listCommands(page);
    for (const c of existing) await deleteCommand(page, c.id);

    await setChatPreferences(page, gatewayId, model, tenantId);
    await openChat(page);

    const textarea = page.locator("textarea[aria-label='Message input']");
    await textarea.waitFor({ state: "visible", timeout: 5000 });
    await textarea.fill("/");

    // No picker should appear (wait a moment for React to process the input)
    await expect(page.locator("[class*='picker']").first()).not.toBeVisible({ timeout: 2000 });
  });
});

// ---------------------------------------------------------------------------
// Group 5: Variable fill modal
// ---------------------------------------------------------------------------

test.describe("variable fill modal", () => {
  test.describe.configure({ mode: "serial" });
  let gatewayId: string;
  let tenantId: string;
  let model: string;
  const personalIds: string[] = [];

  test.beforeAll(async ({ browser }) => {
    const page = await browser.newPage();
    const result = await getFirstTenantAndGateway(page);
    const mdl = await getAModel(page);
    await page.close();
    if (!result) throw new Error("No tenant/gateway found");
    if (!mdl) throw new Error("No model found");
    gatewayId = result.gatewayId;
    tenantId = result.tenantId;
    model = mdl;
  });

  test.afterEach(async ({ page }) => {
    for (const id of personalIds) await deleteCommand(page, id);
    personalIds.length = 0;
  });

  async function openPickerAndSelectCommand(page: Page, cmdName: string) {
    const textarea = page.locator("textarea[aria-label='Message input']");
    await textarea.waitFor({ state: "visible", timeout: 5000 });
    await textarea.fill(`/${cmdName.slice(0, 3)}`);
    await expect(page.getByText(`/${cmdName}`)).toBeVisible({ timeout: 3000 });
    await page.getByText(`/${cmdName}`).click();
  }

  test("filling all variables and clicking Insert → expanded text in input", async ({ page }) => {
    const id = await createCommand(page, {
      name: "trnsl",
      template: "Translate to {{lang}}: {{content}}",
    });
    if (id) personalIds.push(id);

    await setChatPreferences(page, gatewayId, model, tenantId);
    await openChat(page);
    await openPickerAndSelectCommand(page, "trnsl");

    // Modal should be open
    await expect(page.getByText(/Fill in \/trnsl/i)).toBeVisible({ timeout: 3000 });

    // Fill variables
    await page.getByLabel("lang").fill("German");
    await page.getByLabel("content").fill("Hello world");

    // Preview should update in the modal (shows filled text)
    await expect(page.getByText(/\[German\].*\[Hello world\]/)).toBeVisible({ timeout: 2000 });

    // Click Insert
    await page.getByRole("button", { name: /Insert →/i }).click();

    // Modal closes, input has expanded text
    await expect(page.getByText(/Fill in/)).not.toBeVisible({ timeout: 2000 });
    const textarea = page.locator("textarea[aria-label='Message input']");
    await expect(textarea).toHaveValue("Translate to German: Hello world", { timeout: 3000 });
  });

  test("Cancel closes modal without inserting anything", async ({ page }) => {
    const id = await createCommand(page, {
      name: "canceltest",
      template: "Process {{item}} with {{method}}",
    });
    if (id) personalIds.push(id);

    await setChatPreferences(page, gatewayId, model, tenantId);
    await openChat(page);
    await openPickerAndSelectCommand(page, "canceltest");

    await expect(page.getByText(/Fill in \/canceltest/i)).toBeVisible({ timeout: 3000 });

    // Fill one field then cancel
    await page.getByLabel("item").fill("some value");
    await page.getByRole("button", { name: "Cancel" }).click();

    // Modal closed, input remains empty
    await expect(page.getByText(/Fill in/)).not.toBeVisible({ timeout: 2000 });
    const textarea = page.locator("textarea[aria-label='Message input']");
    await expect(textarea).toHaveValue("");
  });

  test("template with repeated placeholder uses same value for all occurrences", async ({ page }) => {
    const id = await createCommand(page, {
      name: "repeat",
      template: "{{word}} is {{word}} — indeed {{word}}",
    });
    if (id) personalIds.push(id);

    await setChatPreferences(page, gatewayId, model, tenantId);
    await openChat(page);
    await openPickerAndSelectCommand(page, "repeat");

    // Only one input field for the repeated variable
    await expect(page.getByLabel("word")).toHaveCount(1);
    await page.getByLabel("word").fill("great");

    await page.getByRole("button", { name: /Insert →/i }).click();

    const textarea = page.locator("textarea[aria-label='Message input']");
    await expect(textarea).toHaveValue("great is great — indeed great", { timeout: 3000 });
  });
});

// ---------------------------------------------------------------------------
// Group 6: Picker merges tenant + personal commands
// ---------------------------------------------------------------------------

test.describe("picker merges tenant and personal commands", () => {
  test.describe.configure({ mode: "serial" });
  let gatewayId: string;
  let tenantId: string;
  let model: string;
  const personalIds: string[] = [];

  test.beforeAll(async ({ browser }) => {
    const page = await browser.newPage();
    const result = await getFirstTenantAndGateway(page);
    const mdl = await getAModel(page);
    await page.close();
    if (!result) throw new Error("No tenant/gateway found");
    if (!mdl) throw new Error("No model found");
    gatewayId = result.gatewayId;
    tenantId = result.tenantId;
    model = mdl;
  });

  test.afterEach(async ({ page }) => {
    for (const id of personalIds) await deleteCommand(page, id);
    personalIds.length = 0;
    await page.request.patch(`${ADMIN_URL}/admin/v1/tenants/${tenantId}`, {
      data: { slash_commands: [] },
    }).catch(() => {});
  });

  test("both personal and tenant commands appear in picker", async ({ page }) => {
    // Create personal command
    const pid = await createCommand(page, { name: "personal-cmd", template: "Personal" });
    if (pid) personalIds.push(pid);

    // Set tenant command
    await page.request.patch(`${ADMIN_URL}/admin/v1/tenants/${tenantId}`, {
      data: {
        slash_commands: [{ id: "mix-t-001", name: "tenant-cmd", description: "", template: "Tenant" }],
      },
    });

    await setChatPreferences(page, gatewayId, model, tenantId);
    await openChat(page);

    const textarea = page.locator("textarea[aria-label='Message input']");
    await textarea.waitFor({ state: "visible", timeout: 5000 });
    await textarea.fill("/");

    await expect(page.getByText("/personal-cmd")).toBeVisible({ timeout: 3000 });
    await expect(page.getByText("/tenant-cmd")).toBeVisible({ timeout: 3000 });
  });

  test("picking tenant command (no variables) fills input directly", async ({ page }) => {
    await page.request.patch(`${ADMIN_URL}/admin/v1/tenants/${tenantId}`, {
      data: {
        slash_commands: [{ id: "mix-t-002", name: "tenantdirect", description: "Direct tenant", template: "Tenant direct content" }],
      },
    });

    await setChatPreferences(page, gatewayId, model, tenantId);
    await openChat(page);

    const textarea = page.locator("textarea[aria-label='Message input']");
    await textarea.waitFor({ state: "visible", timeout: 5000 });
    await textarea.fill("/ten");

    await expect(page.getByText("/tenantdirect")).toBeVisible({ timeout: 3000 });
    await page.getByText("/tenantdirect").click();

    await expect(textarea).toHaveValue("Tenant direct content", { timeout: 3000 });
  });
});

// ---------------------------------------------------------------------------
// Group 7: Commands page — validation
// ---------------------------------------------------------------------------

test.describe("Commands page — validation", () => {
  const createdIds: string[] = [];

  test.afterEach(async ({ page }) => {
    for (const id of createdIds) await deleteCommand(page, id);
    createdIds.length = 0;
  });

  test("submitting with empty name is prevented — modal stays open", async ({ page }) => {
    // The name input has `required`, so the browser's native constraint fires before
    // handleSubmit runs. The form does not close; the name input is marked invalid.
    await page.goto("/commands");
    await page.getByRole("button", { name: /\+ New command/i }).click();
    await expect(page.getByRole("heading", { name: "New Command" })).toBeVisible({ timeout: 3000 });

    // Fill template but leave name empty
    await page.getByPlaceholder(/Use \{\{variable\}\}/i).fill("Some template");
    await page.getByRole("button", { name: "Create" }).click();

    // Modal must still be open — browser prevented submission
    await expect(page.getByRole("heading", { name: "New Command" })).toBeVisible({ timeout: 2000 });

    // Name input reports a browser-level validity error
    const nameInput = page.getByPlaceholder("command-name");
    const valueMissing = await nameInput.evaluate((el) => (el as HTMLInputElement).validity.valueMissing);
    expect(valueMissing).toBe(true);
  });

  test("submitting with empty template is prevented — modal stays open", async ({ page }) => {
    await page.goto("/commands");
    await page.getByRole("button", { name: /\+ New command/i }).click();
    await expect(page.getByRole("heading", { name: "New Command" })).toBeVisible({ timeout: 3000 });
    const nameInput = page.getByPlaceholder("command-name");
    await nameInput.waitFor({ state: "visible", timeout: 5000 });

    // Fill name but leave template empty
    await nameInput.fill("validname");
    await page.getByRole("button", { name: "Create" }).click();

    // Modal must still be open
    await expect(page.getByRole("heading", { name: "New Command" })).toBeVisible({ timeout: 2000 });

    // Template textarea reports missing value
    const templateInput = page.getByPlaceholder(/Use \{\{variable\}\}/i);
    const valueMissing = await templateInput.evaluate((el) => (el as HTMLTextAreaElement).validity.valueMissing);
    expect(valueMissing).toBe(true);
  });

  test("form is still editable after failed validation and can be submitted successfully", async ({ page }) => {
    await page.goto("/commands");
    await page.getByRole("button", { name: /\+ New command/i }).click();
    await expect(page.getByRole("heading", { name: "New Command" })).toBeVisible({ timeout: 3000 });
    const nameInput = page.getByPlaceholder("command-name");
    await nameInput.waitFor({ state: "visible", timeout: 5000 });

    // Attempt submit with both fields empty — browser blocks it, modal stays open
    await page.getByRole("button", { name: "Create" }).click();
    await expect(page.getByRole("heading", { name: "New Command" })).toBeVisible({ timeout: 2000 });

    // Now fill both required fields and submit successfully
    await nameInput.fill("recoveredcmd");
    await page.getByPlaceholder(/Use \{\{variable\}\}/i).fill("Recovered template");
    await page.getByRole("button", { name: "Create" }).click();

    // Modal closes and command appears in the list
    await expect(page.getByRole("heading", { name: "New Command" })).not.toBeVisible({ timeout: 3000 });
    await expect(page.locator("code").filter({ hasText: "/recoveredcmd" })).toBeVisible({ timeout: 5000 });

    const rows = await listCommands(page);
    const created = rows.find((c) => c.name === "recoveredcmd");
    if (created) createdIds.push(created.id);
  });
});

// ---------------------------------------------------------------------------
// Group 8: Commands page — whitespace trimming, persistence on reload,
//           clearing optional fields
// ---------------------------------------------------------------------------

test.describe("Commands page — boundary values and persistence", () => {
  const createdIds: string[] = [];

  test.afterEach(async ({ page }) => {
    for (const id of createdIds) await deleteCommand(page, id);
    createdIds.length = 0;
  });

  test("spaces in name are replaced with hyphens", async ({ page }) => {
    await page.goto("/commands");
    await page.getByRole("button", { name: /\+ New command/i }).click();
    await expect(page.getByRole("heading", { name: "New Command" })).toBeVisible({ timeout: 3000 });
    const nameInput = page.getByPlaceholder("command-name");
    await nameInput.waitFor({ state: "visible", timeout: 5000 });

    // Type name with spaces — should auto-convert to hyphens via onChange
    await nameInput.fill("my spaced name");
    // The onChange replaces spaces with hyphens
    await expect(nameInput).toHaveValue("my-spaced-name");

    await page.getByPlaceholder(/Use \{\{variable\}\}/i).fill("Template text");
    await page.getByRole("button", { name: "Create" }).click();
    await expect(page.getByRole("heading", { name: "New Command" })).not.toBeVisible({ timeout: 3000 });

    // Table shows hyphenated name
    await expect(page.locator("code").filter({ hasText: "/my-spaced-name" })).toBeVisible({ timeout: 5000 });

    const rows = await listCommands(page);
    const created = rows.find((c) => c.name === "my-spaced-name");
    if (created) createdIds.push(created.id);
  });

  test("edited command values persist after page reload", async ({ page }) => {
    const id = await createCommand(page, { name: "persistme", description: "Before", template: "Before template" });
    expect(id).not.toBeNull();
    createdIds.push(id!);

    await page.goto("/commands");
    await expect(page.locator("code").filter({ hasText: "/persistme" })).toBeVisible({ timeout: 5000 });

    // Edit via UI
    await page.getByRole("row", { name: /persistme/ }).getByRole("button", { name: "Edit" }).click();
    await expect(page.getByRole("heading", { name: "Edit Command" })).toBeVisible({ timeout: 3000 });

    await page.getByPlaceholder(/Short description/i).fill("After");
    await page.getByRole("button", { name: "Save" }).click();
    await expect(page.getByRole("heading", { name: "Edit Command" })).not.toBeVisible({ timeout: 3000 });

    // Reload and confirm persisted
    await page.reload();
    await expect(page.locator("code").filter({ hasText: "/persistme" })).toBeVisible({ timeout: 5000 });
    await expect(page.getByText("After")).toBeVisible();
  });

  test("clearing optional description saves as empty, not retained", async ({ page }) => {
    const id = await createCommand(page, { name: "cleardesc", description: "Will be cleared", template: "Some template" });
    expect(id).not.toBeNull();
    createdIds.push(id!);

    await page.goto("/commands");
    await page.getByRole("row", { name: /cleardesc/ }).getByRole("button", { name: "Edit" }).click();
    await expect(page.getByRole("heading", { name: "Edit Command" })).toBeVisible({ timeout: 3000 });

    // Clear description
    await page.getByPlaceholder(/Short description/i).fill("");
    await page.getByRole("button", { name: "Save" }).click();
    await expect(page.getByRole("heading", { name: "Edit Command" })).not.toBeVisible({ timeout: 3000 });

    // Reload and verify description is gone
    await page.reload();
    await expect(page.locator("code").filter({ hasText: "/cleardesc" })).toBeVisible({ timeout: 5000 });
    await expect(page.getByText("Will be cleared")).not.toBeVisible();
  });

  test("special characters in template are stored and displayed correctly", async ({ page }) => {
    const template = "Analyze <input> & return \"result\" for {{topic}}";
    await page.goto("/commands");
    await page.getByRole("button", { name: /\+ New command/i }).click();
    await expect(page.getByRole("heading", { name: "New Command" })).toBeVisible({ timeout: 3000 });
    const nameInput = page.getByPlaceholder("command-name");
    await nameInput.waitFor({ state: "visible", timeout: 5000 });

    await nameInput.fill("specialchars");
    await page.getByPlaceholder(/Use \{\{variable\}\}/i).fill(template);
    await page.getByRole("button", { name: "Create" }).click();
    await expect(page.getByRole("heading", { name: "New Command" })).not.toBeVisible({ timeout: 3000 });

    // Verify API stored it correctly
    const rows = await listCommands(page);
    const created = rows.find((c) => c.name === "specialchars");
    expect(created).toBeDefined();
    expect(created!.template).toBe(template);
    if (created) createdIds.push(created.id);
  });
});

// ---------------------------------------------------------------------------
// Group 9: Commands page — cancel delete confirmation
// ---------------------------------------------------------------------------

test.describe("Commands page — cancel delete confirmation", () => {
  const createdIds: string[] = [];

  test.afterEach(async ({ page }) => {
    for (const id of createdIds) await deleteCommand(page, id);
    createdIds.length = 0;
  });

  test("cancelling the delete confirm dialog does NOT delete the command", async ({ page }) => {
    const id = await createCommand(page, { name: "nodelete", template: "Keep me" });
    expect(id).not.toBeNull();
    createdIds.push(id!);

    await page.goto("/commands");
    await expect(page.locator("code").filter({ hasText: "/nodelete" })).toBeVisible({ timeout: 5000 });

    // Dismiss the confirm dialog
    page.once("dialog", (d) => d.dismiss());
    await page.getByRole("row", { name: /nodelete/ }).getByRole("button", { name: "Delete" }).click();

    // Command still present
    await expect(page.locator("code").filter({ hasText: "/nodelete" })).toBeVisible({ timeout: 3000 });
  });
});

// ---------------------------------------------------------------------------
// Group 10: Navigation
// ---------------------------------------------------------------------------

test.describe("Commands page — navigation", () => {
  test("direct URL /commands renders without going through sidebar", async ({ page }) => {
    // Navigate directly without any prior navigation through sidebar
    await page.goto("/commands");
    await expect(page.getByRole("heading", { name: "My Commands" })).toBeVisible({ timeout: 5000 });
    await expect(page.getByRole("button", { name: /\+ New command/i })).toBeVisible();
  });

  test("browser back button returns to previous page", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page).toHaveURL(/\/dashboard/);

    await page.goto("/commands");
    await expect(page.getByRole("heading", { name: "My Commands" })).toBeVisible({ timeout: 5000 });

    await page.goBack();
    await expect(page).toHaveURL(/\/dashboard/, { timeout: 5000 });
  });
});

// ---------------------------------------------------------------------------
// Group 11: Tenants page UI — Shared Commands section
// ---------------------------------------------------------------------------

test.describe("Tenants page UI — Shared Commands", () => {
  test.describe.configure({ mode: "serial" });
  let tenantId: string;
  let tenantSlug: string;

  test.beforeAll(async ({ browser }) => {
    const page = await browser.newPage();
    const result = await getFirstTenantAndGateway(page);
    await page.close();
    if (!result) throw new Error("No tenant found");
    tenantId = result.tenantId;
    // Fetch slug for display assertions
    const page2 = await browser.newPage();
    const resp = await page2.request.get(`${ADMIN_URL}/admin/v1/tenants`);
    const tenants = await resp.json() as TenantRow[];
    const t = tenants.find((x) => x.id === tenantId);
    tenantSlug = t?.slug ?? "";
    await page2.close();
  });

  test.afterEach(async ({ page }) => {
    // Clear tenant slash_commands after each test
    await page.request.patch(`${ADMIN_URL}/admin/v1/tenants/${tenantId}`, {
      data: { slash_commands: [] },
    });
  });

  test("Shared Commands section is visible with empty-state message", async ({ page }) => {
    // Clear any existing commands
    await page.request.patch(`${ADMIN_URL}/admin/v1/tenants/${tenantId}`, {
      data: { slash_commands: [] },
    });

    await page.goto(`/tenants/${tenantId}`);
    await expect(page.getByRole("heading", { name: tenantSlug, exact: true })).toBeVisible({ timeout: 5000 });
    await expect(page.getByRole("heading", { name: "Shared Commands" })).toBeVisible();
    await expect(page.getByText(/No shared commands yet/i)).toBeVisible();
    await expect(page.getByRole("button", { name: /\+ Add Command/i })).toBeVisible();
  });

  test("adding a shared command via UI modal appears in the list", async ({ page }) => {
    await page.goto(`/tenants/${tenantId}`);
    await expect(page.getByRole("button", { name: /\+ Add Command/i })).toBeVisible({ timeout: 5000 });

    await page.getByRole("button", { name: /\+ Add Command/i }).click();
    await expect(page.getByRole("heading", { name: "Add Shared Command" })).toBeVisible({ timeout: 3000 });

    const nameInput = page.getByPlaceholder("command-name");
    await nameInput.waitFor({ state: "visible", timeout: 5000 });
    await nameInput.fill("sharedhelp");
    await page.getByPlaceholder(/Short description/i).fill("Help command");
    await page.getByPlaceholder(/Use \{\{variable\}\}/i).fill("Help me with {{topic}}");

    await page.getByRole("button", { name: "Add Command", exact: true }).click();
    await expect(page.getByRole("heading", { name: "Add Shared Command" })).not.toBeVisible({ timeout: 3000 });

    // Command appears in the tenant detail table
    await expect(page.getByRole("row").filter({ hasText: "/sharedhelp" })).toBeVisible({ timeout: 5000 });
    await expect(page.getByText("Help command")).toBeVisible();

    // API confirms it's saved
    const resp = await page.request.get(`${ADMIN_URL}/admin/v1/tenants`);
    const tenants = await resp.json() as TenantRow[];
    const t = tenants.find((x) => x.id === tenantId);
    expect(t?.slash_commands?.some((c) => c.name === "sharedhelp")).toBe(true);
  });

  test("editing a shared command updates the list", async ({ page }) => {
    // Seed via API
    await page.request.patch(`${ADMIN_URL}/admin/v1/tenants/${tenantId}`, {
      data: {
        slash_commands: [{ id: "ui-edit-001", name: "editshared", description: "Old desc", template: "Old template" }],
      },
    });

    await page.goto(`/tenants/${tenantId}`);
    await expect(page.getByRole("row").filter({ hasText: "/editshared" })).toBeVisible({ timeout: 5000 });

    // Click Edit
    await page.getByRole("row", { name: /editshared/ }).getByRole("button", { name: "Edit" }).click();
    await expect(page.getByRole("heading", { name: /Edit \/editshared/i })).toBeVisible({ timeout: 3000 });

    // Update description
    const descInput = page.getByPlaceholder(/Short description/i);
    await descInput.fill("New description");
    await page.getByRole("button", { name: "Save" }).click();
    await expect(page.getByRole("heading", { name: /Edit \/editshared/i })).not.toBeVisible({ timeout: 3000 });

    // Verify update in list
    await expect(page.getByText("New description")).toBeVisible();

    // Verify persisted via API
    const resp = await page.request.get(`${ADMIN_URL}/admin/v1/tenants`);
    const tenants = await resp.json() as TenantRow[];
    const t = tenants.find((x) => x.id === tenantId);
    const cmd = t?.slash_commands?.find((c) => c.name === "editshared");
    expect(cmd?.description).toBe("New description");
  });

  test("deleting a shared command removes it from the list", async ({ page }) => {
    await page.request.patch(`${ADMIN_URL}/admin/v1/tenants/${tenantId}`, {
      data: {
        slash_commands: [{ id: "ui-del-001", name: "deleteshared", description: "", template: "Delete me" }],
      },
    });

    await page.goto(`/tenants/${tenantId}`);
    await expect(page.getByRole("row").filter({ hasText: "/deleteshared" })).toBeVisible({ timeout: 5000 });

    page.once("dialog", (d) => d.accept());
    await page.getByRole("row", { name: /deleteshared/ }).getByRole("button", { name: "Delete" }).click();

    await expect(page.getByRole("row").filter({ hasText: "/deleteshared" })).not.toBeVisible({ timeout: 5000 });
    await expect(page.getByText(/No shared commands yet/i)).toBeVisible();
  });

  test("cancelling the delete confirm does NOT remove the shared command", async ({ page }) => {
    await page.request.patch(`${ADMIN_URL}/admin/v1/tenants/${tenantId}`, {
      data: {
        slash_commands: [{ id: "ui-nodelmatch-001", name: "keepshared", description: "", template: "Keep me" }],
      },
    });

    await page.goto(`/tenants/${tenantId}`);
    await expect(page.getByRole("row").filter({ hasText: "/keepshared" })).toBeVisible({ timeout: 5000 });

    page.once("dialog", (d) => d.dismiss());
    await page.getByRole("row", { name: /keepshared/ }).getByRole("button", { name: "Delete" }).click();

    // Still present
    await expect(page.getByRole("row").filter({ hasText: "/keepshared" })).toBeVisible({ timeout: 3000 });
  });

  test("Shared Commands section shows 'Add Command' only for admin users", async ({ page }) => {
    await page.goto(`/tenants/${tenantId}`);
    // Test user is admin — button should be visible
    await expect(page.getByRole("button", { name: /\+ Add Command/i })).toBeVisible({ timeout: 5000 });
  });
});
