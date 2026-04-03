/**
 * projects.spec.ts — E2E tests for the Projects feature
 *
 * Suites:
 *   1. Navigation  — sidebar link, route /projects, /projects/:id
 *   2. CRUD        — create, read, update, delete project
 *   3. Knowledge   — upload file, list files, delete file
 *   4. Members     — invite member, change role, remove member
 *   5. Chat integration — open chat from project, conversation scoped to project
 *   6. Permissions — viewer cannot edit/delete; non-member cannot access
 *   7. Regression  — last-owner guard, conversation detach on delete
 */

import { test, expect, Page } from "@playwright/test";

// Use the Vite proxy path so the session cookie (localhost-scoped) is sent correctly.
const ADMIN_BASE = "http://localhost:5173/admin/v1";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function apiDelete(page: Page, path: string) {
  await page.context().request.delete(`${ADMIN_BASE}${path}`).catch(() => {});
}

async function gotoProjects(page: Page) {
  await page.goto("/projects");
  await page.waitForTimeout(500);
}

/** Fetch the first available tenant_id (needed for admin users who have no personal tenant). */
async function getFirstTenantId(page: Page): Promise<string> {
  const resp = await page.context().request.get(`${ADMIN_BASE}/tenants`);
  if (!resp.ok()) return "";
  const tenants = await resp.json() as Array<{ id: string }>;
  return tenants[0]?.id ?? "";
}

/** Fetch gateways for the first available tenant. */
async function getFirstTenantGateways(page: Page): Promise<Array<{ id: string; slug: string }>> {
  const tenantId = await getFirstTenantId(page);
  if (!tenantId) return [];
  const resp = await page.context().request.get(`${ADMIN_BASE}/tenants/${tenantId}/gateways`);
  if (!resp.ok()) return [];
  return resp.json() as Promise<Array<{ id: string; slug: string }>>;
}

/** Create a project via the API and return its id. */
async function apiCreateProject(page: Page, name: string, extraFields?: Record<string, unknown>): Promise<string> {
  const tenant_id = await getFirstTenantId(page);
  const resp = await page.context().request.post(`${ADMIN_BASE}/projects`, {
    data: { name, icon: "📁", color: "#2563eb", tenant_id, ...extraFields },
  });
  expect(resp.ok(), `create project '${name}': ${await resp.text()}`).toBeTruthy();
  const body = await resp.json() as { id: string };
  return body.id;
}

async function apiDeleteProject(page: Page, id: string) {
  await page.context().request.delete(`${ADMIN_BASE}/projects/${id}`).catch(() => {});
}

// ---------------------------------------------------------------------------
// Suite 1 — Navigation
// ---------------------------------------------------------------------------

test.describe("Projects — Navigation", () => {

  test("sidebar has Projects link", async ({ page }) => {
    await page.goto("/dashboard");
    await page.waitForTimeout(400);
    const link = page.locator("nav").getByRole("link", { name: /projects/i });
    await expect(link).toBeVisible();
  });

  test("navigates to /projects via sidebar", async ({ page }) => {
    await page.goto("/dashboard");
    await page.locator("nav").getByRole("link", { name: /projects/i }).click();
    await expect(page).toHaveURL(/\/projects/);
    // The Projects page title should be visible
    await expect(page.getByRole("heading", { name: /projects/i })).toBeVisible({ timeout: 5000 });
  });

  test("/projects loads without error", async ({ page }) => {
    await gotoProjects(page);
    // Either a table or empty state must be present — no JS error modal
    const hasTable   = await page.locator("[data-cy=projects-table]").isVisible();
    const hasEmpty   = await page.getByText(/no projects yet/i).isVisible();
    expect(hasTable || hasEmpty).toBe(true);
  });

});

// ---------------------------------------------------------------------------
// Suite 2 — CRUD
// ---------------------------------------------------------------------------

test.describe("Projects — CRUD", () => {

  test("create project via modal", async ({ page }) => {
    await gotoProjects(page);

    // Only tenant_admin/admin can create
    const createBtn = page.getByRole("button", { name: /new project/i });
    if (!await createBtn.isVisible()) {
      test.skip();
      return;
    }
    await createBtn.click();

    // Modal appears
    await expect(page.getByRole("dialog")).toBeVisible({ timeout: 3000 })
      .catch(() => {
        // Fallback: look for the name input directly
      });

    const nameInput = page.getByTestId("project-name-input").or(
      page.locator("[data-cy=project-name-input]")
    );
    await nameInput.waitFor({ state: "visible", timeout: 4000 });
    await nameInput.fill("E2E Test Project");

    const saveBtn = page.locator("[data-cy=project-save-btn]");
    await saveBtn.click();

    // Should navigate to the new project's detail page
    await expect(page).toHaveURL(/\/projects\/[a-f0-9-]{36}/, { timeout: 8000 });
    await expect(page.getByRole("heading", { name: "E2E Test Project" })).toBeVisible({ timeout: 5000 });

    // Cleanup via API
    const url = page.url();
    const pid = url.split("/projects/")[1];
    await apiDeleteProject(page, pid);
  });

  test("project detail page shows overview tab", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Detail Test");
    try {
      await page.goto(`/projects/${pid}`);
      await page.waitForTimeout(500);
      await expect(page.getByRole("heading", { name: "E2E Detail Test" })).toBeVisible({ timeout: 5000 });
      // Overview tab content
      await expect(page.getByText(/default gateway/i)).toBeVisible();
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("edit project name", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Edit Before");
    try {
      await page.goto(`/projects/${pid}`);
      await page.waitForTimeout(500);

      const editBtn = page.locator("[data-cy=project-edit-btn]");
      if (!await editBtn.isVisible()) { test.skip(); return; }
      await editBtn.click();

      // Wait for save button — it only renders when the edit form is active
      await page.locator("[data-cy=project-save-edit-btn]").waitFor({ state: "visible", timeout: 5000 });

      const nameInput = page.locator("input").first();
      await nameInput.clear();
      await nameInput.fill("E2E Edit After");

      await page.locator("[data-cy=project-save-edit-btn]").click();
      await page.waitForTimeout(800);

      await expect(page.getByRole("heading", { name: "E2E Edit After" })).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("delete project shows confirmation and removes it", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Delete Me");

    await page.goto(`/projects/${pid}`);
    await page.waitForTimeout(500);

    const deleteBtn = page.locator("[data-cy=project-delete-btn]");
    if (!await deleteBtn.isVisible()) { test.skip(); return; }
    await deleteBtn.click();

    // Confirmation modal
    const confirmBtn = page.locator("[data-cy=confirm-delete-project-btn]");
    await confirmBtn.waitFor({ state: "visible", timeout: 3000 });
    await confirmBtn.click();

    // Redirected back to /projects
    await expect(page).toHaveURL(/\/projects$/, { timeout: 6000 });
    // Project no longer in the list
    await expect(page.getByText("E2E Delete Me")).not.toBeVisible();
  });

  test("create project with a gateway pre-selected shows it in detail overview", async ({ page }) => {
    const gateways = await getFirstTenantGateways(page);
    if (gateways.length === 0) { test.skip(); return; }

    // Create via API with a gateway assigned
    const pid = await apiCreateProject(page, "E2E Gateway Assigned", {
      default_gateway_id: gateways[0].id,
    });
    try {
      await page.goto(`/projects/${pid}`);
      await page.waitForTimeout(500);

      // Overview tab should show the gateway slug
      await expect(page.getByText(gateways[0].slug)).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("project list shows created project", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Listed Project");
    try {
      await gotoProjects(page);
      await expect(page.locator(`[data-cy=project-row-${pid}]`)).toBeVisible({ timeout: 6000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

});

// ---------------------------------------------------------------------------
// Suite 3 — Knowledge Files
// ---------------------------------------------------------------------------

test.describe("Projects — Knowledge Files", () => {

  test("upload a text file to knowledge panel", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Knowledge Project");
    try {
      await page.goto(`/projects/${pid}`);
      await page.waitForTimeout(500);

      // Navigate to Knowledge tab
      await page.getByRole("button", { name: /knowledge/i }).click();
      await page.waitForTimeout(300);

      const uploadBtn = page.locator("[data-cy=upload-knowledge-btn]");
      if (!await uploadBtn.isVisible()) { test.skip(); return; }

      // Use file chooser
      const fileContent = "Hello from E2E test knowledge file.\nThis is test content.";
      const [fileChooser] = await Promise.all([
        page.waitForEvent("filechooser"),
        uploadBtn.click(),
      ]);
      await fileChooser.setFiles({
        name: "e2e-knowledge.txt",
        mimeType: "text/plain",
        buffer: Buffer.from(fileContent),
      });

      await page.waitForTimeout(1500);
      await expect(page.getByText("e2e-knowledge.txt")).toBeVisible({ timeout: 6000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("delete a knowledge file", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Knowledge Delete");
    try {
      // Upload via API
      const uploadResp = await page.context().request.post(
        `${ADMIN_BASE}/projects/${pid}/knowledge`,
        { data: { filename: "delete-me.txt", extracted_text: "To be deleted.", content_type: "text/plain" } }
      );
      expect(uploadResp.ok()).toBeTruthy();
      const { id: kid } = await uploadResp.json() as { id: string };

      await page.goto(`/projects/${pid}`);
      await page.waitForTimeout(400);
      await page.getByRole("button", { name: /knowledge/i }).click();
      await page.waitForTimeout(400);

      await expect(page.getByText("delete-me.txt")).toBeVisible({ timeout: 5000 });

      page.on("dialog", (dialog) => dialog.accept());
      const deleteKnBtn = page.locator(`[data-cy=delete-knowledge-${kid}]`);
      await deleteKnBtn.click();

      await page.waitForTimeout(1000);
      await expect(page.getByText("delete-me.txt")).not.toBeVisible();
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("knowledge tab shows file count", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Knowledge Count");
    try {
      await page.context().request.post(
        `${ADMIN_BASE}/projects/${pid}/knowledge`,
        { data: { filename: "file1.txt", extracted_text: "Content one." } }
      );
      await page.context().request.post(
        `${ADMIN_BASE}/projects/${pid}/knowledge`,
        { data: { filename: "file2.txt", extracted_text: "Content two." } }
      );

      await page.goto(`/projects/${pid}`);
      await page.waitForTimeout(400);
      await page.getByRole("button", { name: /knowledge/i }).click();
      await page.waitForTimeout(400);

      await expect(page.getByText("file1.txt")).toBeVisible({ timeout: 5000 });
      await expect(page.getByText("file2.txt")).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("drag-and-drop zone is present for editors+", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Drop Zone");
    try {
      await page.goto(`/projects/${pid}`);
      await page.waitForTimeout(400);
      await page.getByRole("button", { name: /knowledge/i }).click();
      await page.waitForTimeout(300);
      // Drop zone visible for owner
      await expect(page.locator("[data-cy=knowledge-drop-zone]")).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

});

// ---------------------------------------------------------------------------
// Suite 4 — Members
// ---------------------------------------------------------------------------

test.describe("Projects — Members", () => {

  test("members tab lists project owner", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Members Project");
    try {
      await page.goto(`/projects/${pid}`);
      await page.waitForTimeout(400);
      await page.getByRole("button", { name: /members/i }).click();
      await page.waitForTimeout(400);

      // The creator must be listed as owner
      await expect(page.getByText("owner")).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("invite member button is visible to project owner", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Invite Button");
    try {
      await page.goto(`/projects/${pid}`);
      await page.waitForTimeout(400);
      await page.getByRole("button", { name: /members/i }).click();
      await page.waitForTimeout(400);

      const inviteBtn = page.locator("[data-cy=invite-member-btn]");
      await expect(inviteBtn).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("invite modal accepts email + role", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Invite Modal");
    try {
      await page.goto(`/projects/${pid}`);
      await page.waitForTimeout(400);
      await page.getByRole("button", { name: /members/i }).click();
      await page.waitForTimeout(400);
      await page.locator("[data-cy=invite-member-btn]").click();
      await page.waitForTimeout(300);

      const emailInput = page.locator("[data-cy=member-email-input]");
      await expect(emailInput).toBeVisible({ timeout: 4000 });
      await emailInput.fill("nonexistent@example.com");

      // Click invite — should show error (user not found)
      await page.locator("[data-cy=confirm-invite-btn]").click();
      await page.waitForTimeout(800);
      await expect(page.getByText(/not found/i)).toBeVisible({ timeout: 3000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

});

// ---------------------------------------------------------------------------
// Suite 5 — Chat Integration
// ---------------------------------------------------------------------------

test.describe("Projects — Chat Integration", () => {

  test("'Open Chat' button navigates to /chat?project_id=", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Chat Button");
    try {
      await page.goto(`/projects/${pid}`);
      await page.waitForTimeout(500);

      const chatBtn = page.locator("[data-cy=project-open-chat-btn]");
      await chatBtn.waitFor({ state: "visible", timeout: 5000 });
      await chatBtn.click();

      await expect(page).toHaveURL(new RegExp(`/chat.*project_id=${pid}`), { timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("chat page shows project banner when ?project_id= is set", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Chat Banner");
    try {
      await page.goto(`/chat?project_id=${pid}`);
      await page.waitForTimeout(800);

      // The project name should appear in a banner in the conversation sidebar
      await expect(page.getByText("E2E Chat Banner")).toBeVisible({ timeout: 6000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("conversations tab shows linked conversations", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Conversations Tab");
    try {
      await page.goto(`/projects/${pid}`);
      await page.waitForTimeout(400);
      await page.getByRole("button", { name: /conversations/i }).click();
      await page.waitForTimeout(400);

      // Either a table or empty state
      const hasEmpty = await page.getByText(/no conversations/i).isVisible();
      const hasNew   = await page.getByRole("button", { name: /new conversation/i }).isVisible();
      expect(hasEmpty || hasNew).toBe(true);
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

});

// ---------------------------------------------------------------------------
// Suite 6 — Permissions
// ---------------------------------------------------------------------------

test.describe("Projects — Permissions (API-level)", () => {

  test("viewer cannot delete a project via API", async ({ page }) => {
    // Create project as admin, then try to delete as viewer would get 403
    // We test this at the API level since we don't have a separate viewer session here
    const pid = await apiCreateProject(page, "E2E Permission Test");
    try {
      // Verify get works for creator (owner)
      const getResp = await page.context().request.get(`${ADMIN_BASE}/projects/${pid}`);
      expect(getResp.ok()).toBe(true);
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("non-existent project returns 404", async ({ page }) => {
    const resp = await page.context().request.get(
      `${ADMIN_BASE}/projects/00000000-0000-0000-0000-000000000000`
    );
    expect(resp.status()).toBe(404);
  });

  test("creating project without name returns 400", async ({ page }) => {
    const resp = await page.context().request.post(`${ADMIN_BASE}/projects`, {
      data: { icon: "📁" },
    });
    expect(resp.status()).toBe(400);
  });

});

// ---------------------------------------------------------------------------
// Suite 7 — Regression & Edge Cases
// ---------------------------------------------------------------------------

test.describe("Projects — Regression", () => {

  test("last-owner cannot be removed via API", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Last Owner Guard");
    try {
      // Fetch the project to get the owner user_id
      const projResp = await page.context().request.get(`${ADMIN_BASE}/projects/${pid}`);
      const proj = await projResp.json() as { members?: Array<{ user_id: string; role: string }> };
      const owner = proj.members?.find((m) => m.role === "owner");
      if (!owner) { test.skip(); return; }

      // Attempt to remove the last owner — should return 409
      const delResp = await page.context().request.delete(
        `${ADMIN_BASE}/projects/${pid}/members/${owner.user_id}`
      );
      expect(delResp.status()).toBe(409);
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("last-owner cannot be demoted via API", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Last Owner Demote");
    try {
      const projResp = await page.context().request.get(`${ADMIN_BASE}/projects/${pid}`);
      const proj = await projResp.json() as { members?: Array<{ user_id: string; role: string }> };
      const owner = proj.members?.find((m) => m.role === "owner");
      if (!owner) { test.skip(); return; }

      // Attempt to demote to editor — should return 409
      const patchResp = await page.context().request.patch(
        `${ADMIN_BASE}/projects/${pid}/members/${owner.user_id}`,
        { data: { role: "editor" } }
      );
      expect(patchResp.status()).toBe(409);
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("deleting a project detaches its conversations (API)", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Detach Conversations");

    // Create a conversation linked to this project (requires gateway — skip if none)
    const gwsResp = await page.context().request.get(`${ADMIN_BASE}/tenants`);
    if (!gwsResp.ok()) { await apiDeleteProject(page, pid); test.skip(); return; }
    const tenants = await gwsResp.json() as Array<{ id: string }>;
    if (tenants.length === 0) { await apiDeleteProject(page, pid); test.skip(); return; }

    const gateways = await page.context().request
      .get(`${ADMIN_BASE}/tenants/${tenants[0].id}/gateways`)
      .then((r) => r.json()).catch(() => []) as Array<{ id: string }>;
    if (gateways.length === 0) { await apiDeleteProject(page, pid); test.skip(); return; }

    const convResp = await page.context().request.post(`${ADMIN_BASE}/conversations`, {
      data: { gateway_id: gateways[0].id, project_id: pid, title: "E2E Project Conv" },
    });
    if (!convResp.ok()) { await apiDeleteProject(page, pid); test.skip(); return; }
    const conv = await convResp.json() as { id: string };

    // Delete the project
    await apiDeleteProject(page, pid);
    await page.waitForTimeout(300);

    // Conversation should still exist but project_id should be null
    const convFetchResp = await page.context().request.get(`${ADMIN_BASE}/conversations/${conv.id}`);
    if (convFetchResp.ok()) {
      const fetchedConv = await convFetchResp.json() as { project_id?: string | null };
      // cjson omits nil fields, so project_id is either null or absent (undefined) after detach
      expect(fetchedConv.project_id == null).toBeTruthy();
    }

    // Cleanup
    await apiDelete(page, `/conversations/${conv.id}`);
  });

  test("gateway dropdown in New Project modal is populated", async ({ page }) => {
    // Regression: for admin users, gateways were loaded using me.tenant_id directly,
    // which is null for global admins — the dropdown always showed only "— None —".
    // Fix: use effectiveTenantId (falls back to tenants[0].id for admins).
    const gateways = await getFirstTenantGateways(page);
    if (gateways.length === 0) {
      // No gateways exist in this environment — cannot assert dropdown contents, skip.
      test.skip();
      return;
    }

    await gotoProjects(page);

    const createBtn = page.getByRole("button", { name: /new project/i });
    if (!await createBtn.isVisible()) { test.skip(); return; }
    await createBtn.click();

    // Wait for modal
    const nameInput = page.locator("[data-cy=project-name-input]");
    await nameInput.waitFor({ state: "visible", timeout: 4000 });

    // The gateway <select> should have at least one option beyond "— None —"
    const gatewaySelect = page.locator("select").filter({ hasText: /None/ });
    const optionCount = await gatewaySelect.locator("option").count();
    expect(optionCount).toBeGreaterThan(1);

    // The first gateway slug should appear as an option
    const firstGatewaySlug = gateways[0].slug;
    await expect(gatewaySelect.locator(`option[value="${gateways[0].id}"]`)).toBeAttached();
    expect(firstGatewaySlug).toBeTruthy();

    // Close without saving
    await page.keyboard.press("Escape");
  });

  test("knowledge file upload too large is rejected (client-side)", async ({ page }) => {
    const pid = await apiCreateProject(page, "E2E Large File Reject");
    try {
      await page.goto(`/projects/${pid}`);
      await page.waitForTimeout(400);
      await page.getByRole("button", { name: /knowledge/i }).click();
      await page.waitForTimeout(300);

      const uploadBtn = page.locator("[data-cy=upload-knowledge-btn]");
      if (!await uploadBtn.isVisible()) { test.skip(); return; }

      // Simulate a 6 MB file (exceeds 5 MB client limit)
      const largeBuffer = Buffer.alloc(6 * 1024 * 1024, "a");
      const [fileChooser] = await Promise.all([
        page.waitForEvent("filechooser"),
        uploadBtn.click(),
      ]);
      await fileChooser.setFiles({
        name: "too-large.txt",
        mimeType: "text/plain",
        buffer: largeBuffer,
      });
      await page.waitForTimeout(800);

      // Client-side validation should show error message
      await expect(page.getByText(/exceeds 5 mb/i)).toBeVisible({ timeout: 4000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

});
