import { test, expect } from "./base";

const ADMIN_BASE = (process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173") + "/admin/v1";

async function apiGetCommands(page: import("@playwright/test").Page) {
  const r = await page.context().request.get(`${ADMIN_BASE}/chat-commands`);
  if (!r.ok()) return [];
  return r.json() as Promise<Array<{ id: string; name: string; template: string; description: string }>>;
}

async function apiDeleteCommand(page: import("@playwright/test").Page, id: string) {
  await page.context().request.delete(`${ADMIN_BASE}/chat-commands/${id}`).catch(() => {});
}

// ---------------------------------------------------------------------------
// Commands — My Commands
// ---------------------------------------------------------------------------

test.describe("Commands — My Commands", () => {
  test("shows page title and New command button", async ({ page }) => {
    await page.goto("/commands");
    await expect(page.getByRole("heading", { name: "My Commands" })).toBeVisible();
    await expect(page.getByRole("button", { name: /\+ New command/i })).toBeVisible();
  });

  test("shows empty state when no commands exist", async ({ page }) => {
    await page.goto("/commands");
    await page.waitForLoadState("networkidle");
    // Only assert empty state if the table is absent — don't fail if commands already exist
    const hasTable = await page.locator("table").isVisible().catch(() => false);
    if (!hasTable) {
      await expect(page.getByText(/No commands yet/i)).toBeVisible();
    }
  });

  test("New command modal opens with all fields", async ({ page }) => {
    await page.goto("/commands");
    await page.getByRole("button", { name: /\+ New command/i }).click();
    await expect(page.getByRole("heading", { name: "New Command" })).toBeVisible();
    // Scope to label elements to avoid matching table column headers
    await expect(page.locator("label", { hasText: "Name *" })).toBeVisible();
    await expect(page.locator("label", { hasText: "Description" })).toBeVisible();
    await expect(page.locator("label", { hasText: "Template *" })).toBeVisible();
  });

  test("modal closes on Cancel", async ({ page }) => {
    await page.goto("/commands");
    await page.getByRole("button", { name: /\+ New command/i }).click();
    await page.getByRole("button", { name: /Cancel/i }).click();
    await expect(page.getByRole("heading", { name: "New Command" })).not.toBeVisible();
  });

  test("creates a command and it appears in the table", async ({ page, workerSuffix }) => {
    const name = `e2e-cmd-${workerSuffix}`;
    const template = "Translate to English: {{text}}";
    let createdId: string | null = null;
    try {
      await page.goto("/commands");
      await page.waitForLoadState("networkidle");

      await page.getByRole("button", { name: /\+ New command/i }).click();
      await page.getByText("Name *").locator("xpath=following-sibling::*[1]//input").fill(name);
      await page.locator("textarea").fill(template);
      await page.getByRole("button", { name: /^Create$/i }).click();

      await expect(page.getByRole("heading", { name: "New Command" })).not.toBeVisible({ timeout: 5000 });
      await expect(page.getByText(`/${name}`)).toBeVisible();

      // No error banner
      await expect(page.getByText(/failed/i).first()).not.toBeVisible();

      const cmds = await apiGetCommands(page);
      createdId = cmds.find((c) => c.name === name)?.id ?? null;
    } finally {
      if (createdId) await apiDeleteCommand(page, createdId);
    }
  });

  test("spaces in name are replaced with dashes", async ({ page, workerSuffix }) => {
    const baseName = `e2e-space-${workerSuffix}`;
    let createdId: string | null = null;
    try {
      await page.goto("/commands");
      await page.getByRole("button", { name: /\+ New command/i }).click();

      const nameInput = page.getByText("Name *").locator("xpath=following-sibling::*[1]//input");
      await nameInput.fill("my test cmd");
      // Input should auto-convert spaces to dashes
      await expect(nameInput).toHaveValue("my-test-cmd");
      await nameInput.fill(baseName);

      await page.locator("textarea").fill("test template");
      await page.getByRole("button", { name: /^Create$/i }).click();
      await expect(page.getByRole("heading", { name: "New Command" })).not.toBeVisible({ timeout: 5000 });

      const cmds = await apiGetCommands(page);
      createdId = cmds.find((c) => c.name === baseName)?.id ?? null;
    } finally {
      if (createdId) await apiDeleteCommand(page, createdId);
    }
  });

  test("variable detection shows hint when {{var}} used in template", async ({ page }) => {
    await page.goto("/commands");
    await page.getByRole("button", { name: /\+ New command/i }).click();

    await page.locator("textarea").fill("Say {{greeting}} to {{name}}");
    await expect(page.getByText("Variables detected")).toBeVisible();
    // Match only the <code> hint elements, not the textarea value
    await expect(page.locator("code").filter({ hasText: "{{greeting}}" })).toBeVisible();
    await expect(page.locator("code").filter({ hasText: "{{name}}" })).toBeVisible();
  });

  test("edits a command and changes are reflected in the table", async ({ page, workerSuffix }) => {
    const origName = `e2e-edit-${workerSuffix}`;
    const origTemplate = "Original template";
    const newTemplate = "Updated template {{var}}";
    let createdId: string | null = null;
    try {
      // Create via API for isolation
      const r = await page.context().request.post(`${ADMIN_BASE}/chat-commands`, {
        data: { name: origName, template: origTemplate, description: "" },
      });
      expect(r.ok(), `POST chat-commands: ${await r.text()}`).toBeTruthy();
      const created = await r.json() as { id: string };
      createdId = created.id;

      await page.goto("/commands");
      await page.waitForLoadState("networkidle");
      await expect(page.getByText(`/${origName}`)).toBeVisible();

      // Click Edit for this command
      await page.getByText(`/${origName}`)
        .locator("xpath=ancestor::tr//button[contains(text(),'Edit')]").click();
      await expect(page.getByRole("heading", { name: "Edit Command" })).toBeVisible();

      // Verify existing values pre-filled
      await expect(page.locator("textarea")).toHaveValue(origTemplate);

      // Update template
      await page.locator("textarea").fill(newTemplate);
      await page.getByRole("button", { name: /^Save$/i }).click();
      await expect(page.getByRole("heading", { name: "Edit Command" })).not.toBeVisible({ timeout: 5000 });

      // Updated template truncated in table
      await expect(page.getByText("Updated template")).toBeVisible();
    } finally {
      if (createdId) await apiDeleteCommand(page, createdId);
    }
  });

  test("cancelling edit keeps original values", async ({ page, workerSuffix }) => {
    const name = `e2e-cancel-edit-${workerSuffix}`;
    const template = "Original stays put";
    let createdId: string | null = null;
    try {
      const r = await page.context().request.post(`${ADMIN_BASE}/chat-commands`, {
        data: { name, template, description: "" },
      });
      expect(r.ok()).toBeTruthy();
      createdId = (await r.json() as { id: string }).id;

      await page.goto("/commands");
      await page.waitForLoadState("networkidle");

      await page.getByText(`/${name}`)
        .locator("xpath=ancestor::tr//button[contains(text(),'Edit')]").click();
      await page.locator("textarea").fill("This change should be discarded");
      await page.getByRole("button", { name: /Cancel/i }).click();

      // Original template still in table
      await expect(page.getByText("Original stays put")).toBeVisible();
    } finally {
      if (createdId) await apiDeleteCommand(page, createdId);
    }
  });

  test("deletes a command after confirmation", async ({ page, workerSuffix }) => {
    const name = `e2e-delete-${workerSuffix}`;
    const r = await page.context().request.post(`${ADMIN_BASE}/chat-commands`, {
      data: { name, template: "delete me", description: "" },
    });
    expect(r.ok()).toBeTruthy();

    await page.goto("/commands");
    await page.waitForLoadState("networkidle");
    await expect(page.getByText(`/${name}`)).toBeVisible();

    page.on("dialog", (d) => d.accept());
    await page.getByText(`/${name}`)
      .locator("xpath=ancestor::tr//button[contains(text(),'Delete')]").click();
    await expect(page.getByText(`/${name}`)).not.toBeVisible({ timeout: 5000 });
  });

  test("cancelling delete keeps the command", async ({ page, workerSuffix }) => {
    const name = `e2e-nodelete-${workerSuffix}`;
    let createdId: string | null = null;
    try {
      const r = await page.context().request.post(`${ADMIN_BASE}/chat-commands`, {
        data: { name, template: "keep me", description: "" },
      });
      expect(r.ok()).toBeTruthy();
      createdId = (await r.json() as { id: string }).id;

      await page.goto("/commands");
      await page.waitForLoadState("networkidle");
      await expect(page.getByText(`/${name}`)).toBeVisible();

      page.once("dialog", (d) => d.dismiss());
      await page.getByText(`/${name}`)
        .locator("xpath=ancestor::tr//button[contains(text(),'Delete')]").click();

      await expect(page.getByText(`/${name}`)).toBeVisible();
    } finally {
      if (createdId) await apiDeleteCommand(page, createdId);
    }
  });

  test("required fields prevent submission when empty", async ({ page }) => {
    await page.goto("/commands");
    await page.getByRole("button", { name: /\+ New command/i }).click();

    // Leave name and template empty — HTML5 required blocks form submission
    const submitBtn = page.getByRole("button", { name: /^Create$/i });
    await submitBtn.click();

    // Modal must still be visible — form did not submit
    await expect(page.getByRole("heading", { name: "New Command" })).toBeVisible();
  });

  test("direct URL /commands loads the page", async ({ page }) => {
    await page.goto("/commands");
    await expect(page.getByRole("heading", { name: "My Commands" })).toBeVisible();
  });
});
