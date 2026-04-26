/**
 * projects.spec.ts — E2E tests for the Projects feature
 *
 * Suites:
 *   1. Navigation         — sidebar link, route /projects, /projects/:id
 *   2. CRUD               — create, read, update, delete project
 *   3. Knowledge Files    — upload, list, delete, count
 *   4. Members            — invite, role display
 *   5. Chat Integration   — open chat, project banner, conversation linking (bugs fixed)
 *   6. Permissions        — API-level checks
 *   7. Regression         — last-owner guard, detach on delete, gateway dropdown
 *   8. Counts (Bug fixes) — member_count / knowledge_count in list (was always 0)
 *   9. Search/Filter/Sort toolbar — search bar, role filter buttons, sort select
 */

import { test, expect, type Page, type Browser } from "./base";
import { execSync } from "child_process";

const ADMIN_BASE = (process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173") + "/admin/v1";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function apiDelete(page: Page, path: string) {
  await page.context().request.delete(`${ADMIN_BASE}${path}`).catch(() => {});
}

/** Fetch gateways for the given tenant. Fails loudly if none found. */
async function getFirstGateway(page: Page, tenantId: string): Promise<{ id: string; slug: string }> {
  const resp = await page.context().request.get(`${ADMIN_BASE}/tenants/${tenantId}/gateways`);
  expect(resp.ok(), "GET /gateways must succeed").toBeTruthy();
  const gateways = await resp.json() as Array<{ id: string; slug: string }>;
  expect(gateways.length, "at least one gateway must exist in test environment").toBeGreaterThan(0);
  return gateways[0];
}

/** Fetch gateways for the given tenant. Returns empty array if none. */
async function getFirstTenantGateways(page: Page, tenantId: string): Promise<Array<{ id: string; slug: string }>> {
  const resp = await page.context().request.get(`${ADMIN_BASE}/tenants/${tenantId}/gateways`);
  if (!resp.ok()) return [];
  return resp.json() as Promise<Array<{ id: string; slug: string }>>;
}

/** Create a project via API in the given tenant and return its id. Always succeeds or throws. */
async function apiCreateProject(page: Page, name: string, tenantId: string, extra?: Record<string, unknown>): Promise<string> {
  const resp = await page.context().request.post(`${ADMIN_BASE}/projects`, {
    data: { name, icon: "📁", color: "#2563eb", tenant_id: tenantId, ...extra },
  });
  expect(resp.ok(), `create project '${name}': ${await resp.text()}`).toBeTruthy();
  const body = await resp.json() as { id: string };
  return body.id;
}

async function apiDeleteProject(page: Page, id: string) {
  await page.context().request.delete(`${ADMIN_BASE}/projects/${id}`).catch(() => {});
}

// ---------------------------------------------------------------------------
// Helpers for multi-role permission tests
// ---------------------------------------------------------------------------

const DB_HOST = process.env.E2E_DB_HOST ?? "172.17.0.1";
const DB_USER = process.env.E2E_DB_USER ?? "gateway";
const DB_PASS = process.env.E2E_DB_PASS ?? "gateway";
const DB_NAME = process.env.E2E_DB_NAME ?? "ai_gateway";
const PERM_OTP_CODE = "887766";
const AUTH_BASE_PERM = (process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173") + "/admin/auth";

function sql(query: string) {
  execSync(
    `mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} ${DB_NAME}`,
    { input: query, stdio: ["pipe", "pipe", "pipe"] }
  );
}

/** Create a throwaway user via the admin API with a specific role; returns their id. */
async function createTempUserWithRole(
  page: Page,
  tenantId: string,
  email: string,
  role: "member" | "viewer",
): Promise<string> {
  const r = await page.context().request.post(`${ADMIN_BASE}/tenants/${tenantId}/users`, {
    data: { email, role },
  });
  expect(r.ok(), `create temp ${role} user ${email}: ${await r.text()}`).toBeTruthy();
  return ((await r.json()) as { id: string }).id;
}

/** Delete a user via the admin API; silently ignores errors. */
async function deleteTempUserById(page: Page, userId: string) {
  await page.context().request.delete(`${ADMIN_BASE}/users/${userId}`).catch(() => {});
}

/**
 * Authenticate as `email` via the OTP API (no browser UI interaction).
 * Inserts the OTP into MySQL, calls /admin/auth/otp/verify, and returns a new
 * browser context whose cookies contain the resulting session token.
 * Caller must close the context when done.
 */
async function loginAsViaOtp(browser: Browser, email: string) {
  const hash   = execSync(`echo -n '${PERM_OTP_CODE}' | sha256sum | awk '{print $1}'`).toString().trim();
  const expiry = Math.floor(Date.now() / 1000) + 900;
  const otpId  = execSync("cat /proc/sys/kernel/random/uuid").toString().trim();

  sql(`DELETE FROM email_otp WHERE email='${email}' AND used_at IS NULL`);
  sql(`INSERT INTO email_otp (id, email, code_hash, expires_at, ip_addr) VALUES ('${otpId}', '${email}', '${hash}', ${expiry}, '127.0.0.1')`);

  // Exchange OTP for a session cookie via the API — no browser login flow needed
  const authBase = (process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173") + "/admin/auth";
  const tempCtx  = await browser.newContext({ ignoreHTTPSErrors: true });
  try {
    const resp = await tempCtx.request.post(`${authBase}/otp/verify`, {
      data: { email, code: PERM_OTP_CODE },
    });
    expect(resp.ok(), `OTP verify for ${email}: ${await resp.text()}`).toBeTruthy();
  } finally {
    // Save the cookies from the temp context into a new context that we return
  }

  // The session cookie is now in tempCtx — carry it into a proper page context
  const cookies   = await tempCtx.cookies();
  await tempCtx.close();

  const baseURL = process.env.PLAYWRIGHT_BASE_URL ?? "http://localhost:5173";
  const ctx  = await browser.newContext({ baseURL, ignoreHTTPSErrors: true });
  await ctx.addCookies(cookies);
  const page = await ctx.newPage();

  return { page, ctx };
}

/** Navigate to /projects and wait for the page heading to appear. */
async function gotoProjects(page: Page) {
  await page.goto("/projects");
  await expect(page.getByRole("heading", { name: /projects/i })).toBeVisible({ timeout: 8000 });
}

// ---------------------------------------------------------------------------
// Suite 1 — Navigation
// ---------------------------------------------------------------------------

test.describe("Projects — Navigation", () => {

  test("sidebar has Projects link", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page.locator("nav").getByRole("link", { name: /projects/i })).toBeVisible({ timeout: 8000 });
  });

  test("navigates to /projects via sidebar", async ({ page }) => {
    await page.goto("/dashboard");
    await page.locator("nav").getByRole("link", { name: /projects/i }).click();
    await expect(page).toHaveURL(/\/projects/);
    await expect(page.getByRole("heading", { name: /projects/i })).toBeVisible({ timeout: 8000 });
  });

  test("/projects loads without error", async ({ page }) => {
    await page.goto("/projects");
    // Admin users need two async steps: tenants load → then projects load.
    // Use expect() which retries properly, unlike isVisible() which resolves immediately.
    await expect(
      page.locator("[data-cy=projects-table]").or(page.getByText("No projects yet."))
    ).toBeVisible({ timeout: 15000 });
  });

  test("direct URL /projects/:id loads project detail", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Direct URL", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Direct URL" })).toBeVisible({ timeout: 8000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

});

// ---------------------------------------------------------------------------
// Suite 2 — CRUD
// ---------------------------------------------------------------------------

test.describe("Projects — CRUD", () => {

  test("create project via modal", async ({ page }) => {
    await gotoProjects(page);

    const createBtn = page.locator("[data-cy=create-project-btn]");
    await expect(createBtn, "create project button must be visible for admin").toBeVisible({ timeout: 6000 });
    await createBtn.click();

    const nameInput = page.locator("[data-cy=project-name-input]");
    await expect(nameInput).toBeVisible({ timeout: 5000 });
    await nameInput.fill("E2E Created Via Modal");

    await page.locator("[data-cy=project-save-btn]").click();

    // Navigates to the new project's detail page
    await expect(page).toHaveURL(/\/projects\/[a-f0-9-]{36}/, { timeout: 8000 });
    await expect(page.getByRole("heading", { name: "E2E Created Via Modal" })).toBeVisible({ timeout: 5000 });

    const pid = page.url().split("/projects/")[1];
    await apiDeleteProject(page, pid);
  });

  test("project detail page shows overview tab with default gateway field", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Detail Test", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Detail Test" })).toBeVisible({ timeout: 8000 });
      await expect(page.getByText(/default gateway/i)).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("edit project name", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Edit Before", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Edit Before" })).toBeVisible({ timeout: 8000 });

      const editBtn = page.locator("[data-cy=project-edit-btn]");
      await expect(editBtn, "edit button must be visible for owner").toBeVisible({ timeout: 5000 });
      await editBtn.click();

      const saveEditBtn = page.locator("[data-cy=project-save-edit-btn]");
      await expect(saveEditBtn).toBeVisible({ timeout: 5000 });

      const nameInput = page.locator("input").first();
      await nameInput.clear();
      await nameInput.fill("E2E Edit After");

      await saveEditBtn.click();
      await expect(page.getByRole("heading", { name: "E2E Edit After" })).toBeVisible({ timeout: 6000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("delete project shows confirmation and removes it", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Delete Me", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Delete Me" })).toBeVisible({ timeout: 8000 });

      const deleteBtn = page.locator("[data-cy=project-delete-btn]");
      await expect(deleteBtn, "delete button must be visible for owner").toBeVisible({ timeout: 5000 });
      await deleteBtn.click();

      const confirmBtn = page.locator("[data-cy=confirm-delete-project-btn]");
      await expect(confirmBtn).toBeVisible({ timeout: 5000 });
      await confirmBtn.click();

      await expect(page).toHaveURL(/\/projects$/, { timeout: 8000 });
      await expect(page.getByText("E2E Delete Me")).not.toBeVisible({ timeout: 3000 });
    } finally {
      // Already deleted — no-op
    }
  });

  test("create project with gateway pre-selected shows it in detail overview", async ({ page, workerTenantId }) => {
    const gw = await getFirstGateway(page, workerTenantId);
    const pid = await apiCreateProject(page, "E2E Gateway Assigned", workerTenantId, { default_gateway_id: gw.id });
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Gateway Assigned" })).toBeVisible({ timeout: 8000 });
      await expect(page.getByText(gw.slug)).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("project list shows created project in table", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Listed Project", workerTenantId);
    try {
      await gotoProjects(page);
      await expect(page.locator(`[data-cy=project-row-${pid}]`)).toBeVisible({ timeout: 8000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

});

// ---------------------------------------------------------------------------
// Suite 3 — Knowledge Files
// ---------------------------------------------------------------------------

test.describe("Projects — Knowledge Files", () => {

  test("upload a text file to knowledge panel", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Knowledge Upload", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Knowledge Upload" })).toBeVisible({ timeout: 8000 });

      await page.getByRole("button", { name: /files/i }).click();

      const uploadBtn = page.locator("[data-cy=upload-knowledge-btn]");
      await expect(uploadBtn, "upload button must be visible for owner").toBeVisible({ timeout: 5000 });

      const [fileChooser] = await Promise.all([
        page.waitForEvent("filechooser"),
        uploadBtn.click(),
      ]);
      await fileChooser.setFiles({
        name: "e2e-knowledge.txt",
        mimeType: "text/plain",
        buffer: Buffer.from("Hello from E2E test knowledge file.\nThis is test content."),
      });

      await expect(page.getByText("e2e-knowledge.txt")).toBeVisible({ timeout: 10000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("delete a knowledge file removes it from the list", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Knowledge Delete", workerTenantId);
    try {
      const uploadResp = await page.context().request.post(
        `${ADMIN_BASE}/projects/${pid}/knowledge`,
        { data: { filename: "delete-me.txt", extracted_text: "To be deleted.", content_type: "text/plain" } }
      );
      expect(uploadResp.ok(), "knowledge upload must succeed").toBeTruthy();
      const { id: kid } = await uploadResp.json() as { id: string };

      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Knowledge Delete" })).toBeVisible({ timeout: 8000 });
      await page.getByRole("button", { name: /files/i }).click();
      await expect(page.getByText("delete-me.txt")).toBeVisible({ timeout: 5000 });

      page.on("dialog", (dialog) => dialog.accept());
      await page.locator(`[data-cy=delete-knowledge-${kid}]`).click();
      await expect(page.getByText("delete-me.txt")).not.toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("knowledge tab lists multiple uploaded files", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Knowledge List", workerTenantId);
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
      await expect(page.getByRole("heading", { name: "E2E Knowledge List" })).toBeVisible({ timeout: 8000 });
      await page.getByRole("button", { name: /files/i }).click();

      await expect(page.getByText("file1.txt")).toBeVisible({ timeout: 5000 });
      await expect(page.getByText("file2.txt")).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("drag-and-drop zone is present for owners", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Drop Zone", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Drop Zone" })).toBeVisible({ timeout: 8000 });
      await page.getByRole("button", { name: /files/i }).click();
      await expect(page.locator("[data-cy=knowledge-drop-zone]")).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("knowledge file too large is rejected client-side", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Large File Reject", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Large File Reject" })).toBeVisible({ timeout: 8000 });
      await page.getByRole("button", { name: /files/i }).click();

      const uploadBtn = page.locator("[data-cy=upload-knowledge-btn]");
      await expect(uploadBtn, "upload button must be visible for owner").toBeVisible({ timeout: 5000 });

      // 6 MB exceeds the 5 MB client limit
      const [fileChooser] = await Promise.all([
        page.waitForEvent("filechooser"),
        uploadBtn.click(),
      ]);
      await fileChooser.setFiles({
        name: "too-large.txt",
        mimeType: "text/plain",
        buffer: Buffer.alloc(6 * 1024 * 1024, "a"),
      });

      await expect(page.getByText(/exceeds 5 mb/i)).toBeVisible({ timeout: 6000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

});

// ---------------------------------------------------------------------------
// Suite 4 — Members
// ---------------------------------------------------------------------------

test.describe("Projects — Members", () => {

  test("members tab lists project owner", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Members List", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Members List" })).toBeVisible({ timeout: 8000 });
      await page.getByRole("button", { name: /members/i }).click();
      await expect(page.getByText("owner")).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("invite member button is visible to project owner", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Invite Button", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Invite Button" })).toBeVisible({ timeout: 8000 });
      await page.getByRole("button", { name: /members/i }).click();
      await expect(page.locator("[data-cy=invite-member-btn]")).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("invite modal shows error for unknown email", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Invite Modal", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Invite Modal" })).toBeVisible({ timeout: 8000 });
      await page.getByRole("button", { name: /members/i }).click();
      await page.locator("[data-cy=invite-member-btn]").click();

      const emailInput = page.locator("[data-cy=member-email-input]");
      await expect(emailInput).toBeVisible({ timeout: 5000 });
      await emailInput.fill("nonexistent@example.com");
      await page.locator("[data-cy=confirm-invite-btn]").click();

      await expect(page.getByText(/not found/i)).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("invite rejected for empty email", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Invite Empty", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Invite Empty" })).toBeVisible({ timeout: 8000 });
      await page.getByRole("button", { name: /members/i }).click();
      await page.locator("[data-cy=invite-member-btn]").click();

      const emailInput = page.locator("[data-cy=member-email-input]");
      await expect(emailInput).toBeVisible({ timeout: 5000 });
      // Leave email empty and click Invite
      await page.locator("[data-cy=confirm-invite-btn]").click();

      await expect(page.getByText(/email is required/i)).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("successfully invite a member via UI", async ({ page, workerTenantId }) => {
    // The /users/search endpoint searches within the caller's tenant. Use a temp
    // user in workerTenantId so the search can find them (sascha@schumann.net is a
    // global admin with tenant_id=NULL and is not visible from worker tenants).
    const tempEmail = `e2e-invite-${Date.now()}@example.invalid`;
    const tempUserId = await createTempUser(page, workerTenantId, tempEmail);
    const pid = await apiCreateProject(page, "E2E Invite Success", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Invite Success" })).toBeVisible({ timeout: 8000 });
      await page.getByRole("button", { name: /members/i }).click();
      await page.locator("[data-cy=invite-member-btn]").click();

      const emailInput = page.locator("[data-cy=member-email-input]");
      await expect(emailInput).toBeVisible({ timeout: 5000 });
      await emailInput.fill(tempEmail);
      // Change role to editor — the select is the only combobox inside the invite modal
      const roleSelect = page.locator("dialog select, [class*='modal'] select").first();
      await roleSelect.selectOption("editor");
      await page.locator("[data-cy=confirm-invite-btn]").click();

      // Success message appears
      await expect(page.getByText(/added as editor/i)).toBeVisible({ timeout: 5000 });

      // Close modal and verify member appears in the table
      await page.getByRole("button", { name: /close/i }).click();
      await expect(page.getByRole("cell", { name: tempEmail })).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
      await deleteTempUser(page, tempUserId);
    }
  });

  test("invited member appears with correct role badge", async ({ page, workerTenantId }) => {
    // Use a temp user in workerTenantId — the /users/search endpoint only returns
    // users within the caller's own tenant, so sascha@schumann.net (global admin)
    // would not be found from a worker tenant context.
    const tempEmail = `e2e-badge-${Date.now()}@example.invalid`;
    const tempUserId = await createTempUser(page, workerTenantId, tempEmail);
    const pid = await apiCreateProject(page, "E2E Invite Role Badge", workerTenantId);
    try {
      const addResp = await page.context().request.post(`${ADMIN_BASE}/projects/${pid}/members`, {
        data: { user_id: tempUserId, role: "viewer" },
      });
      expect(addResp.ok(), `add member: ${await addResp.text()}`).toBeTruthy();

      // Navigate and verify
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Invite Role Badge" })).toBeVisible({ timeout: 8000 });
      await page.getByRole("button", { name: /members/i }).click();

      await expect(page.getByRole("cell", { name: tempEmail })).toBeVisible({ timeout: 5000 });
      // The viewer badge should be present in the row
      const row = page.locator("tr", { has: page.getByRole("cell", { name: tempEmail }) });
      await expect(row.getByText("viewer")).toBeVisible();
    } finally {
      await apiDeleteProject(page, pid);
      await deleteTempUser(page, tempUserId);
    }
  });

  test("re-inviting existing member updates their role", async ({ page, workerTenantId }) => {
    // Use a temp user in workerTenantId — sascha@schumann.net is a global admin with
    // tenant_id=NULL and cannot be found via /users/search from a worker tenant context.
    const tempEmail = `e2e-reinvite-${Date.now()}@example.invalid`;
    const tempUserId = await createTempUser(page, workerTenantId, tempEmail);
    const pid = await apiCreateProject(page, "E2E Re-invite Role", workerTenantId);
    try {
      // Invite as viewer first
      await page.context().request.post(`${ADMIN_BASE}/projects/${pid}/members`, {
        data: { user_id: tempUserId, role: "viewer" },
      });
      // Re-invite as editor (ON DUPLICATE KEY UPDATE)
      const reInvite = await page.context().request.post(`${ADMIN_BASE}/projects/${pid}/members`, {
        data: { user_id: tempUserId, role: "editor" },
      });
      expect(reInvite.ok(), `re-invite: ${await reInvite.text()}`).toBeTruthy();

      // Navigate and verify role is editor, not viewer
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Re-invite Role" })).toBeVisible({ timeout: 8000 });
      await page.getByRole("button", { name: /members/i }).click();

      const row = page.locator("tr", { has: page.getByRole("cell", { name: tempEmail }) });
      await expect(row.getByText("editor")).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
      await deleteTempUser(page, tempUserId);
    }
  });

});

// ---------------------------------------------------------------------------
// Suite 5 — Chat Integration
// ---------------------------------------------------------------------------

test.describe("Projects — Chat Integration", () => {

  test("'Open Chat' button navigates to /chat?project_id=", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Chat Button", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Chat Button" })).toBeVisible({ timeout: 8000 });

      const chatBtn = page.locator("[data-cy=project-open-chat-btn]");
      await expect(chatBtn).toBeVisible({ timeout: 5000 });
      await chatBtn.click();

      await expect(page).toHaveURL(new RegExp(`/chat.*project_id=${pid}`), { timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("chat page shows project banner when ?project_id= is set", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Chat Banner", workerTenantId);
    try {
      await page.goto(`/chat?project_id=${pid}`);
      await expect(page.getByText("E2E Chat Banner").first()).toBeVisible({ timeout: 8000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("conversations tab shows 'New Conversation' button and empty state or list", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Conv Tab Empty", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Conv Tab Empty" })).toBeVisible({ timeout: 8000 });
      await page.getByRole("button", { name: /conversations/i }).click();

      // Must have either an empty state or the "New Conversation" button
      await expect(
        page.getByRole("button", { name: /new conversation/i })
      ).toBeVisible({ timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("conversation created via API with project_id appears in conversations tab", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Conv Tab Linked", workerTenantId);
    const gw = await getFirstGateway(page, workerTenantId);
    let convId: string | null = null;
    try {
      const convResp = await page.context().request.post(`${ADMIN_BASE}/conversations`, {
        data: { gateway_id: gw.id, project_id: pid, title: "E2E Linked Conv" },
      });
      expect(convResp.ok(), `POST /conversations: ${await convResp.text()}`).toBeTruthy();
      convId = (await convResp.json() as { id: string }).id;

      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Conv Tab Linked" })).toBeVisible({ timeout: 8000 });
      await page.getByRole("button", { name: /conversations/i }).click();

      await expect(page.getByText("E2E Linked Conv")).toBeVisible({ timeout: 5000 });
    } finally {
      if (convId) await apiDelete(page, `/conversations/${convId}`);
      await apiDeleteProject(page, pid);
    }
  });

  test("clicking conversation row navigates to /chat?project_id=&conv= (Bug fix)", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Conv Row Click", workerTenantId);
    const gw = await getFirstGateway(page, workerTenantId);
    let convId: string | null = null;
    try {
      const convResp = await page.context().request.post(`${ADMIN_BASE}/conversations`, {
        data: { gateway_id: gw.id, project_id: pid, title: "E2E Click Me" },
      });
      expect(convResp.ok(), `POST /conversations: ${await convResp.text()}`).toBeTruthy();
      convId = (await convResp.json() as { id: string }).id;

      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Conv Row Click" })).toBeVisible({ timeout: 8000 });
      await page.getByRole("button", { name: /conversations/i }).click();

      await expect(page.getByText("E2E Click Me")).toBeVisible({ timeout: 5000 });
      await page.getByText("E2E Click Me").click();

      // URL must include both project_id and conv
      await expect(page).toHaveURL(
        new RegExp(`/chat.*project_id=${pid}.*conv=${convId}`),
        { timeout: 5000 }
      );
    } finally {
      if (convId) await apiDelete(page, `/conversations/${convId}`);
      await apiDeleteProject(page, pid);
    }
  });

  test("'New conversation' button click creates conversation linked to project (Bug fix: send-path)", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Conv Send Project", workerTenantId);

    // Pre-set gateway+model in localStorage so chat input is immediately active.
    // We fetch the first preset from myratest to get a valid gateway+model pair.
    const tr = await page.context().request.get(`${ADMIN_BASE}/tenants`);
    const tenants = await tr.json() as Array<{ id: string; slug: string; chat_presets?: Array<{ gateway_id: string; model: string }> }>;
    const myratest = tenants.find((t) => t.slug === "myratest");
    const firstPreset = myratest?.chat_presets?.[0];

    await page.goto("/dashboard");
    if (firstPreset) {
      await page.evaluate(({ gwId, model, tenantId }) => {
        localStorage.setItem("aig-chat-gateway", gwId);
        localStorage.setItem("aig-chat-model",   model);
        localStorage.setItem("aig-chat-tenant",  tenantId);
      }, { gwId: firstPreset.gateway_id, model: firstPreset.model, tenantId: myratest!.id });
    } else {
      const gw = await getFirstGateway(page, workerTenantId);
      await page.evaluate((gwId) => { localStorage.setItem("aig-chat-gateway", gwId); }, gw.id);
    }

    try {
      await page.goto(`/chat?project_id=${pid}`);
      await expect(page.getByText("E2E Conv Send Project").first()).toBeVisible({ timeout: 8000 });

      // Intercept the POST /conversations to verify project_id is included
      const convRequestPromise = page.waitForRequest(
        (req) => req.url().includes("/admin/v1/conversations") && req.method() === "POST" && !req.url().includes("/messages")
      );

      // The text input area must be present and enabled for typing
      const textarea = page.locator("[data-cy=chat-input]").or(page.locator("textarea[placeholder]")).first();
      await expect(textarea).toBeEnabled({ timeout: 8000 });

      await textarea.fill("Hello from E2E test");
      await page.keyboard.press("Enter");

      const convRequest = await convRequestPromise;
      const body = convRequest.postDataJSON() as Record<string, unknown>;
      expect(body.project_id, "POST /conversations must include project_id").toBe(pid);

      // Also verify via API that the conversation appears in the project
      const listResp = await page.context().request.get(`${ADMIN_BASE}/projects/${pid}/conversations`);
      expect(listResp.ok()).toBeTruthy();
      const convs = await listResp.json() as Array<{ id: string; project_id: string }>;
      expect(convs.length, "project must have at least one linked conversation").toBeGreaterThan(0);
      expect(convs[0].project_id).toBe(pid);

      // Cleanup conversations
      for (const c of convs) await apiDelete(page, `/conversations/${c.id}`);
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

});

// ---------------------------------------------------------------------------
// Suite 6 — Permissions
// ---------------------------------------------------------------------------

test.describe("Projects — Permissions (API-level)", () => {

  test("owner can read their own project", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Permission Read", workerTenantId);
    try {
      const getResp = await page.context().request.get(`${ADMIN_BASE}/projects/${pid}`);
      expect(getResp.ok()).toBeTruthy();
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

  test("member user can create a project via API (returns 201)", async ({ page, browser, workerTenantId }) => {
    // Regression guard: previously only admin/tenant_admin could create projects.
    const tenantId = workerTenantId;
    const email    = `perm-member-create-${Date.now()}@local.test`;
    const userId   = await createTempUserWithRole(page, tenantId, email, "member");
    let   pid: string | undefined;

    const { page: memberPage, ctx } = await loginAsViaOtp(browser, email);
    try {
      const resp = await memberPage.context().request.post(
        `${AUTH_BASE_PERM.replace("/admin/auth", "/admin/v1")}/projects`,
        { data: { name: `E2E Member Create ${Date.now()}`, tenant_id: tenantId } },
      );
      expect(resp.status(), `member POST /projects: ${await resp.text()}`).toBe(201);
      pid = ((await resp.json()) as { id: string }).id;
    } finally {
      await ctx.close();
      if (pid) await apiDeleteProject(page, pid);
      await deleteTempUserById(page, userId);
    }
  });

  test("member user sees + New Project button in UI", async ({ page, browser, workerTenantId }) => {
    const tenantId = workerTenantId;
    const email    = `perm-member-ui-${Date.now()}@local.test`;
    const userId   = await createTempUserWithRole(page, tenantId, email, "member");

    const { page: memberPage, ctx } = await loginAsViaOtp(browser, email);
    try {
      await memberPage.goto("/projects");
      await expect(memberPage.locator("[data-cy=create-project-btn]")).toBeVisible({ timeout: 8000 });
    } finally {
      await ctx.close();
      await deleteTempUserById(page, userId);
    }
  });

  test("viewer user cannot create a project via API (returns 403)", async ({ page, browser, workerTenantId }) => {
    const tenantId = workerTenantId;
    const email    = `perm-viewer-create-${Date.now()}@local.test`;
    const userId   = await createTempUserWithRole(page, tenantId, email, "viewer");

    const { page: viewerPage, ctx } = await loginAsViaOtp(browser, email);
    try {
      const resp = await viewerPage.context().request.post(
        `${AUTH_BASE_PERM.replace("/admin/auth", "/admin/v1")}/projects`,
        { data: { name: `E2E Viewer Forbidden ${Date.now()}`, tenant_id: tenantId } },
      );
      expect(resp.status(), "viewer must receive 403").toBe(403);
    } finally {
      await ctx.close();
      await deleteTempUserById(page, userId);
    }
  });

  test("viewer user does not see + New Project button in UI", async ({ page, browser, workerTenantId }) => {
    const tenantId = workerTenantId;
    const email    = `perm-viewer-ui-${Date.now()}@local.test`;
    const userId   = await createTempUserWithRole(page, tenantId, email, "viewer");

    const { page: viewerPage, ctx } = await loginAsViaOtp(browser, email);
    try {
      await viewerPage.goto("/projects");
      await expect(viewerPage.getByRole("heading", { name: /projects/i })).toBeVisible({ timeout: 8000 });
      await expect(viewerPage.locator("[data-cy=create-project-btn]")).not.toBeVisible();
    } finally {
      await ctx.close();
      await deleteTempUserById(page, userId);
    }
  });

});

// ---------------------------------------------------------------------------
// Suite 7 — Regression
// ---------------------------------------------------------------------------

test.describe("Projects — Regression", () => {

  test("last-owner cannot be removed via API (409)", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Last Owner Remove", workerTenantId);
    try {
      const projResp = await page.context().request.get(`${ADMIN_BASE}/projects/${pid}`);
      const proj = await projResp.json() as { members?: Array<{ user_id: string; role: string }> };
      const owner = proj.members?.find((m) => m.role === "owner");
      expect(owner, "project must have an owner member after creation").toBeTruthy();

      const delResp = await page.context().request.delete(
        `${ADMIN_BASE}/projects/${pid}/members/${owner!.user_id}`
      );
      expect(delResp.status()).toBe(409);
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("last-owner cannot be demoted via API (409)", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Last Owner Demote", workerTenantId);
    try {
      const projResp = await page.context().request.get(`${ADMIN_BASE}/projects/${pid}`);
      const proj = await projResp.json() as { members?: Array<{ user_id: string; role: string }> };
      const owner = proj.members?.find((m) => m.role === "owner");
      expect(owner, "project must have an owner member after creation").toBeTruthy();

      const patchResp = await page.context().request.patch(
        `${ADMIN_BASE}/projects/${pid}/members/${owner!.user_id}`,
        { data: { role: "editor" } }
      );
      expect(patchResp.status()).toBe(409);
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("deleting a project detaches its conversations", async ({ page, workerTenantId }) => {
    const gw = await getFirstGateway(page, workerTenantId);
    const pid = await apiCreateProject(page, "E2E Detach Conv", workerTenantId);

    const convResp = await page.context().request.post(`${ADMIN_BASE}/conversations`, {
      data: { gateway_id: gw.id, project_id: pid, title: "E2E Detach Me" },
    });
    expect(convResp.ok(), `POST /conversations: ${await convResp.text()}`).toBeTruthy();
    const conv = await convResp.json() as { id: string };

    await apiDeleteProject(page, pid);

    // Conversation must still exist, project_id must be null/absent
    const fetchResp = await page.context().request.get(`${ADMIN_BASE}/conversations/${conv.id}`);
    expect(fetchResp.ok(), "detached conversation must still be readable").toBeTruthy();
    const fetched = await fetchResp.json() as { project_id?: string | null };
    // cjson omits nil fields, so project_id is absent (undefined) or null after detach
    expect(fetched.project_id == null, "project_id must be null/absent after project deletion").toBeTruthy();

    await apiDelete(page, `/conversations/${conv.id}`);
  });

  test("gateway dropdown in New Project modal is populated", async ({ page, workerTenantId }) => {
    const gw = await getFirstGateway(page, workerTenantId);

    await gotoProjects(page);

    const createBtn = page.locator("[data-cy=create-project-btn]");
    await expect(createBtn).toBeVisible({ timeout: 6000 });
    await createBtn.click();

    const nameInput = page.locator("[data-cy=project-name-input]");
    await expect(nameInput).toBeVisible({ timeout: 5000 });

    // Gateway <select> should have the first gateway's id as an option
    await expect(page.locator(`select option[value="${gw.id}"]`)).toBeAttached({ timeout: 5000 });

    await page.keyboard.press("Escape");
  });

});

// ---------------------------------------------------------------------------
// Suite 8 — member_count / knowledge_count Bug Fixes
// ---------------------------------------------------------------------------

test.describe("Projects — Counts (Bug fixes)", () => {

  test("API: GET /projects list returns member_count = 1 for newly created project", async ({ page, workerTenantId }) => {
    // Bug: list_projects() SQL did not aggregate member counts → always returned undefined (shown as 0)
    const pid = await apiCreateProject(page, "E2E Member Count API", workerTenantId);
    try {
      const listResp = await page.context().request.get(`${ADMIN_BASE}/projects?tenant_id=${workerTenantId}`);
      expect(listResp.ok()).toBeTruthy();
      const list = await listResp.json() as Array<{ id: string; member_count?: number; knowledge_count?: number }>;

      const proj = list.find((p) => p.id === pid);
      expect(proj, "created project must appear in list").toBeTruthy();
      expect(proj!.member_count, "member_count must be 1 (creator auto-added as owner)").toBe(1);
      expect(proj!.knowledge_count, "knowledge_count must be 0 for new project").toBe(0);
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("API: GET /projects list returns knowledge_count = 1 after upload", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Knowledge Count API", workerTenantId);
    try {
      const uploadResp = await page.context().request.post(
        `${ADMIN_BASE}/projects/${pid}/knowledge`,
        { data: { filename: "count-test.txt", extracted_text: "Count this file." } }
      );
      expect(uploadResp.ok(), "knowledge upload must succeed").toBeTruthy();

      const listResp = await page.context().request.get(`${ADMIN_BASE}/projects?tenant_id=${workerTenantId}`);
      const list = await listResp.json() as Array<{ id: string; knowledge_count?: number }>;

      const proj = list.find((p) => p.id === pid);
      expect(proj, "created project must appear in list").toBeTruthy();
      expect(proj!.knowledge_count, "knowledge_count must be 1 after one upload").toBe(1);
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("UI: projects list table shows member_count = 1 (not 0) for new project", async ({ page, workerTenantId }) => {
    // Bug: projects table always showed 0 members even when creator was added as owner
    const pid = await apiCreateProject(page, "E2E Member Count UI", workerTenantId);
    try {
      await gotoProjects(page);

      const row = page.locator(`[data-cy=project-row-${pid}]`);
      await expect(row).toBeVisible({ timeout: 8000 });

      // Members column is the 3rd cell (after Name and Description)
      const memberCell = row.locator("td").nth(2);
      await expect(memberCell).toHaveText("1", { timeout: 3000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("UI: member_count in list matches member_count in detail overview", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Count Consistency", workerTenantId);
    try {
      // Check list view count
      await gotoProjects(page);
      const row = page.locator(`[data-cy=project-row-${pid}]`);
      await expect(row).toBeVisible({ timeout: 8000 });
      const listMemberText = await row.locator("td").nth(2).textContent();

      // Check detail view count
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Count Consistency" })).toBeVisible({ timeout: 8000 });

      // Overview shows members stat card — should match list count
      const detailMemberText = await page.getByText(/\d+/).first().textContent();

      // Both should show "1"
      expect(listMemberText?.trim()).toBe("1");
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("API: conversation created with project_id appears in /projects/:id/conversations", async ({ page, workerTenantId }) => {
    // Bug: conversations created via handleSend() lacked project_id
    const pid = await apiCreateProject(page, "E2E Conv Link API", workerTenantId);
    const gw = await getFirstGateway(page, workerTenantId);
    let convId: string | null = null;
    try {
      const convResp = await page.context().request.post(`${ADMIN_BASE}/conversations`, {
        data: { gateway_id: gw.id, project_id: pid, title: "E2E Project Conv" },
      });
      expect(convResp.ok(), `POST /conversations: ${await convResp.text()}`).toBeTruthy();
      const conv = await convResp.json() as { id: string; project_id?: string };
      convId = conv.id;

      // Returned conversation must have project_id set
      expect(conv.project_id, "POST /conversations response must include project_id").toBe(pid);

      // Project conversations list must include this conversation
      const listResp = await page.context().request.get(`${ADMIN_BASE}/projects/${pid}/conversations`);
      expect(listResp.ok()).toBeTruthy();
      const convs = await listResp.json() as Array<{ id: string }>;
      expect(convs.find((c) => c.id === convId), "conversation must appear in project conversations").toBeTruthy();
    } finally {
      if (convId) await apiDelete(page, `/conversations/${convId}`);
      await apiDeleteProject(page, pid);
    }
  });

});

// ---------------------------------------------------------------------------
// Tab URL routing
// ---------------------------------------------------------------------------

test.describe("Projects — Tab URL routing", () => {

  test("direct URL with ?tab=files renders the Files tab", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Tab URL Files", workerTenantId);
    try {
      await page.goto(`/projects/${pid}?tab=files`);
      await expect(page.getByRole("heading", { name: "E2E Tab URL Files" })).toBeVisible({ timeout: 8000 });
      // Files tab button must be active
      const knowledgeTab = page.getByRole("button", { name: /^files$/i });
      await expect(knowledgeTab).toHaveClass(/tab--active/, { timeout: 5000 });
      // Overview tab must not be active
      const overviewTab = page.getByRole("button", { name: /overview/i });
      await expect(overviewTab).not.toHaveClass(/tab--active/);
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("clicking a tab updates the URL", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Tab Click URL", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Tab Click URL" })).toBeVisible({ timeout: 8000 });

      await page.getByRole("button", { name: /members/i }).click();
      await expect(page).toHaveURL(/\?tab=members/, { timeout: 5000 });

      await page.getByRole("button", { name: /conversations/i }).click();
      await expect(page).toHaveURL(/\?tab=conversations/, { timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("reload preserves the active tab", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Tab Reload", workerTenantId);
    try {
      await page.goto(`/projects/${pid}?tab=conversations`);
      await expect(page.getByRole("heading", { name: "E2E Tab Reload" })).toBeVisible({ timeout: 8000 });
      const convTab = page.getByRole("button", { name: /conversations/i });
      await expect(convTab).toHaveClass(/tab--active/, { timeout: 5000 });

      await page.reload();
      await expect(page.getByRole("heading", { name: "E2E Tab Reload" })).toBeVisible({ timeout: 8000 });
      await expect(page.getByRole("button", { name: /conversations/i })).toHaveClass(/tab--active/, { timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("invalid ?tab= value falls back to Overview tab", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Tab Invalid", workerTenantId);
    try {
      await page.goto(`/projects/${pid}?tab=bogus`);
      await expect(page.getByRole("heading", { name: "E2E Tab Invalid" })).toBeVisible({ timeout: 8000 });
      const overviewTab = page.getByRole("button", { name: /overview/i });
      await expect(overviewTab).toHaveClass(/tab--active/, { timeout: 5000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("clicking Overview tab removes ?tab= from URL", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Tab Overview Clean", workerTenantId);
    try {
      await page.goto(`/projects/${pid}?tab=members`);
      await expect(page.getByRole("heading", { name: "E2E Tab Overview Clean" })).toBeVisible({ timeout: 8000 });
      await expect(page).toHaveURL(/\?tab=members/, { timeout: 5000 });

      await page.getByRole("button", { name: /overview/i }).click();
      await expect(page).not.toHaveURL(/\?tab=/, { timeout: 5000 });
      await expect(page.getByRole("button", { name: /overview/i })).toHaveClass(/tab--active/);
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

});

// ---------------------------------------------------------------------------
// Clickable stat cards
// ---------------------------------------------------------------------------

test.describe("Projects — Clickable stat cards", () => {

  test("clicking Members card navigates to members tab", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Card Members", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Card Members" })).toBeVisible({ timeout: 8000 });
      // Must be on overview (no ?tab=)
      await expect(page).not.toHaveURL(/\?tab=/);
      await page.locator("[data-cy=stat-card-members]").click();
      await expect(page).toHaveURL(/\?tab=members/, { timeout: 5000 });
      await expect(page.getByRole("button", { name: /members/i })).toHaveClass(/tab--active/);
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("clicking Files card navigates to files tab", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Card Files", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Card Files" })).toBeVisible({ timeout: 8000 });
      await page.locator("[data-cy=stat-card-files]").click();
      await expect(page).toHaveURL(/\?tab=files/, { timeout: 5000 });
      await expect(page.getByRole("button", { name: /^files$/i })).toHaveClass(/tab--active/);
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("clicking Conversations card navigates to conversations tab", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Card Convs", workerTenantId);
    try {
      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Card Convs" })).toBeVisible({ timeout: 8000 });
      await page.locator("[data-cy=stat-card-conversations]").click();
      await expect(page).toHaveURL(/\?tab=conversations/, { timeout: 5000 });
      await expect(page.getByRole("button", { name: /conversations/i })).toHaveClass(/tab--active/);
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("Conversations card shows correct count", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, "E2E Card Conv Count", workerTenantId);
    const gw = await getFirstGateway(page, workerTenantId);
    const convIds: string[] = [];
    try {
      // Create 2 conversations linked to this project
      for (let i = 0; i < 2; i++) {
        const r = await page.context().request.post(`${ADMIN_BASE}/conversations`, {
          data: { gateway_id: gw.id, project_id: pid, title: `E2E Conv ${i}` },
        });
        expect(r.ok()).toBeTruthy();
        convIds.push(((await r.json()) as { id: string }).id);
      }

      await page.goto(`/projects/${pid}`);
      await expect(page.getByRole("heading", { name: "E2E Card Conv Count" })).toBeVisible({ timeout: 8000 });
      // The Conversations stat card value should be 2
      await expect(page.locator("[data-cy=stat-card-conversations-value]")).toHaveText("2", { timeout: 5000 });
    } finally {
      for (const cid of convIds) await apiDelete(page, `/conversations/${cid}`);
      await apiDeleteProject(page, pid);
    }
  });

});

// ---------------------------------------------------------------------------
// Knowledge download & URL
// ---------------------------------------------------------------------------

test.describe("Projects — Knowledge download & URL", () => {

  async function uploadKnowledgeEntry(page: Page, projectId: string, filename: string, text: string): Promise<string> {
    const r = await page.context().request.post(`${ADMIN_BASE}/projects/${projectId}/knowledge`, {
      data: { filename, content_type: "text/plain", extracted_text: text, size_bytes: text.length },
    });
    expect(r.ok(), `upload knowledge: ${await r.text()}`).toBeTruthy();
    const row = await r.json() as { id: string };
    return row.id;
  }

  async function deleteKnowledgeEntry(page: Page, projectId: string, kid: string) {
    await page.context().request.delete(`${ADMIN_BASE}/projects/${projectId}/knowledge/${kid}`).catch(() => {});
  }

  test("Download button is present and single-item API returns extracted_text", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, `E2E KnowDownload-${Date.now()}`, workerTenantId);
    const filename = `download-test-${Date.now()}.txt`;
    const content = "Hello from knowledge download test";
    const kid = await uploadKnowledgeEntry(page, pid, filename, content);
    try {
      await page.goto(`/projects/${pid}?tab=files`);
      await expect(page.getByText(filename)).toBeVisible({ timeout: 8000 });

      // Verify the single-item API endpoint returns extracted_text
      const r = await page.context().request.get(`${ADMIN_BASE}/projects/${pid}/knowledge/${kid}`);
      expect(r.ok(), `GET /knowledge/:kid: ${await r.text()}`).toBeTruthy();
      const item = await r.json() as { filename: string; extracted_text: string };
      expect(item.filename).toBe(filename);
      expect(item.extracted_text).toBe(content);

      // Download button must be present in the row
      await expect(page.locator(`[data-cy="download-knowledge-${kid}"]`)).toBeVisible({ timeout: 5000 });
    } finally {
      await deleteKnowledgeEntry(page, pid, kid);
      await apiDeleteProject(page, pid);
    }
  });

  test("Copy URL button copies the correct reference URL to clipboard", async ({ page, context, workerTenantId }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    const pid = await apiCreateProject(page, `E2E KnowCopyUrl-${Date.now()}`, workerTenantId);
    const filename = `url-test-${Date.now()}.md`;
    const kid = await uploadKnowledgeEntry(page, pid, filename, "# Reference test");
    try {
      await page.goto(`/projects/${pid}?tab=files`);
      await expect(page.getByText(filename)).toBeVisible({ timeout: 8000 });

      await page.locator(`[data-cy="copy-url-knowledge-${kid}"]`).click();

      // Brief ✓ confirmation must appear
      await expect(page.locator(`[data-cy="copy-url-knowledge-${kid}"]`)).toHaveText("✓", { timeout: 3000 });

      // Clipboard must contain the correct URL
      const clipped = await page.evaluate(() => navigator.clipboard.readText());
      expect(clipped).toContain(`/projects/${pid}/knowledge/${kid}`);
    } finally {
      await deleteKnowledgeEntry(page, pid, kid);
      await apiDeleteProject(page, pid);
    }
  });

  test("Download and Copy URL buttons visible; Delete button also present for editor", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, `E2E KnowButtons-${Date.now()}`, workerTenantId);
    const filename = `buttons-test-${Date.now()}.txt`;
    const kid = await uploadKnowledgeEntry(page, pid, filename, "button visibility test");
    try {
      await page.goto(`/projects/${pid}?tab=files`);
      await expect(page.getByText(filename)).toBeVisible({ timeout: 8000 });

      // As admin/owner: all three buttons present
      await expect(page.locator(`[data-cy="download-knowledge-${kid}"]`)).toBeVisible();
      await expect(page.locator(`[data-cy="copy-url-knowledge-${kid}"]`)).toBeVisible();
      await expect(page.locator(`[data-cy="delete-knowledge-${kid}"]`)).toBeVisible();
    } finally {
      await deleteKnowledgeEntry(page, pid, kid);
      await apiDeleteProject(page, pid);
    }
  });

});

// ─── Suite 9: Search / Filter / Sort toolbar ──────────────────────────────────
//
// To test role-based filters we need projects with known my_role values for the
// test user (info@schumann.net, admin).  Strategy:
//   - owner project  : created by admin → auto-added as owner
//   - editor project : create with admin as owner, add a temp second owner, then
//                      PATCH admin's role to "editor"
//   - viewer project : same setup, PATCH admin to "viewer"
//
// The temp user is created via POST /tenants/:id/users and deleted in cleanup.
// All filter assertions reload the page so they test the full data flow.
// ---------------------------------------------------------------------------

const AUTH_BASE = (process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173") + "/admin/auth";

/** Return the current user's id and tenant_id from /admin/auth/me */
async function getMe(page: Page): Promise<{ id: string; tenant_id: string }> {
  const r = await page.context().request.get(`${AUTH_BASE}/me`);
  expect(r.ok(), "GET /auth/me").toBeTruthy();
  return r.json();
}

/** Create a throwaway tenant member user; returns their id */
async function createTempUser(page: Page, tenantId: string, email: string): Promise<string> {
  const r = await page.context().request.post(`${ADMIN_BASE}/tenants/${tenantId}/users`, {
    data: { email, role: "member" },
  });
  expect(r.ok(), `create temp user ${email}: ${await r.text()}`).toBeTruthy();
  const body = await r.json() as { id: string };
  return body.id;
}

/** Delete a user via the admin API; silently ignores errors (cleanup helper) */
async function deleteTempUser(page: Page, userId: string) {
  await page.context().request.delete(`${ADMIN_BASE}/users/${userId}`).catch(() => {});
}

/**
 * Demote the admin user's role in a project.
 * Requires at least one other owner to be present first (last-owner guard).
 * Adds `secondOwnerId` as owner, then patches `adminId` to `newRole`.
 */
async function demoteAdminInProject(
  page: Page,
  projectId: string,
  adminId: string,
  secondOwnerId: string,
  newRole: "editor" | "viewer",
) {
  // Add second owner
  const addResp = await page.context().request.post(`${ADMIN_BASE}/projects/${projectId}/members`, {
    data: { user_id: secondOwnerId, role: "owner" },
  });
  expect(addResp.ok(), `add second owner: ${await addResp.text()}`).toBeTruthy();

  // Demote admin
  const patchResp = await page.context().request.patch(
    `${ADMIN_BASE}/projects/${projectId}/members/${adminId}`,
    { data: { role: newRole } },
  );
  expect(patchResp.ok(), `demote admin to ${newRole}: ${await patchResp.text()}`).toBeTruthy();
}

test.describe("Search/Filter/Sort toolbar", () => {

  // ── Toolbar visibility ─────────────────────────────────────────────────────

  test("toolbar elements are present on the projects list page", async ({ page }) => {
    await page.goto("/projects");
    await expect(page.locator("[data-cy=projects-search]")).toBeVisible({ timeout: 8000 });
    await expect(page.locator("[data-cy=filter-all]")).toBeVisible();
    await expect(page.locator("[data-cy=filter-owner]")).toBeVisible();
    await expect(page.locator("[data-cy=filter-editor]")).toBeVisible();
    await expect(page.locator("[data-cy=filter-viewer]")).toBeVisible();
    const sel = page.locator("[data-cy=projects-sort]");
    await expect(sel).toBeVisible();
    await expect(sel.locator("option[value=activity]")).toHaveText("Recent Activity");
    await expect(sel.locator("option[value=edited]")).toHaveText("Last edited");
    await expect(sel.locator("option[value=created]")).toHaveText("Date created");
  });

  // ── Search ─────────────────────────────────────────────────────────────────

  test("search filters by name — matching project visible, non-matching hidden", async ({ page, workerTenantId }) => {
    const marker = `xzqm-${Date.now()}`;
    const pid1 = await apiCreateProject(page, `E2E-search-baseline-${Date.now()}`, workerTenantId);
    const pid2 = await apiCreateProject(page, `${marker}-target`, workerTenantId);
    try {
      await page.goto("/projects");
      await expect(page.locator("[data-cy=projects-search]")).toBeVisible({ timeout: 8000 });
      await expect(page.locator(`[data-cy="project-row-${pid1}"]`)).toBeVisible();
      await expect(page.locator(`[data-cy="project-row-${pid2}"]`)).toBeVisible();

      await page.locator("[data-cy=projects-search]").fill(marker);
      await expect(page.locator(`[data-cy="project-row-${pid2}"]`)).toBeVisible({ timeout: 3000 });
      await expect(page.locator(`[data-cy="project-row-${pid1}"]`)).not.toBeVisible();

      // Clear — both reappear
      await page.locator("[data-cy=projects-search]").fill("");
      await expect(page.locator(`[data-cy="project-row-${pid1}"]`)).toBeVisible({ timeout: 3000 });
    } finally {
      await apiDeleteProject(page, pid1);
      await apiDeleteProject(page, pid2);
    }
  });

  test("search with no matches shows empty-state message", async ({ page, workerTenantId }) => {
    // "No projects match your search." only renders when projects.length > 0 but
    // displayProjects.length === 0 (search filters out all of them). Create one
    // project first so the list is non-empty before searching.
    const pid = await apiCreateProject(page, `E2E-search-nomatch-${Date.now()}`, workerTenantId);
    try {
      await page.goto("/projects");
      await expect(page.locator("[data-cy=projects-search]")).toBeVisible({ timeout: 8000 });
      await expect(page.locator(`[data-cy="project-row-${pid}"]`)).toBeVisible({ timeout: 5000 });
      await page.locator("[data-cy=projects-search]").fill("zzz-no-match-ever-zzz");
      await expect(page.locator("text=No projects match your search.")).toBeVisible({ timeout: 3000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  // ── Filter: Your projects (owner) ─────────────────────────────────────────

  test("'Your projects' shows only owner-role project, hides editor-role project", async ({ page }) => {
    // ownerPid: admin is owner (default after create)
    // editorPid: admin is demoted to editor
    const { id: adminId, tenant_id: tenantId } = await getMe(page);
    const ownerPid  = await apiCreateProject(page, `E2E-filter-owner-${Date.now()}`, tenantId);
    const editorPid = await apiCreateProject(page, `E2E-filter-editor-${Date.now()}`, tenantId);
    const tmpEmail  = `tmp-filter-${Date.now()}@example.invalid`;
    const tmpUserId = await createTempUser(page, tenantId, tmpEmail);

    try {
      await demoteAdminInProject(page, editorPid, adminId, tmpUserId, "editor");

      await page.goto("/projects");
      await expect(page.locator("[data-cy=filter-owner]")).toBeVisible({ timeout: 8000 });

      // Reload to get fresh data
      await page.reload();
      await expect(page.locator("[data-cy=filter-owner]")).toBeVisible({ timeout: 8000 });

      await page.locator("[data-cy=filter-owner]").click();

      await expect(page.locator(`[data-cy="project-row-${ownerPid}"]`)).toBeVisible({ timeout: 3000 });
      await expect(page.locator(`[data-cy="project-row-${editorPid}"]`)).not.toBeVisible();
    } finally {
      await apiDeleteProject(page, ownerPid);
      await apiDeleteProject(page, editorPid);
      await deleteTempUser(page, tmpUserId);
    }
  });

  // ── Filter: Team (editor) ──────────────────────────────────────────────────

  test("'Team' filter shows editor-role project, hides owner-role project", async ({ page }) => {
    const { id: adminId, tenant_id: tenantId } = await getMe(page);
    const ownerPid  = await apiCreateProject(page, `E2E-team-owner-${Date.now()}`, tenantId);
    const editorPid = await apiCreateProject(page, `E2E-team-editor-${Date.now()}`, tenantId);
    const tmpEmail  = `tmp-team-${Date.now()}@example.invalid`;
    const tmpUserId = await createTempUser(page, tenantId, tmpEmail);

    try {
      await demoteAdminInProject(page, editorPid, adminId, tmpUserId, "editor");

      await page.goto("/projects");
      await page.reload();
      await expect(page.locator("[data-cy=filter-editor]")).toBeVisible({ timeout: 8000 });

      await page.locator("[data-cy=filter-editor]").click();

      await expect(page.locator(`[data-cy="project-row-${editorPid}"]`)).toBeVisible({ timeout: 3000 });
      await expect(page.locator(`[data-cy="project-row-${ownerPid}"]`)).not.toBeVisible();
    } finally {
      await apiDeleteProject(page, ownerPid);
      await apiDeleteProject(page, editorPid);
      await deleteTempUser(page, tmpUserId);
    }
  });

  // ── Filter: Shared with you (viewer) ──────────────────────────────────────

  test("'Shared with you' shows viewer-role project, hides owner-role project", async ({ page }) => {
    const { id: adminId, tenant_id: tenantId } = await getMe(page);
    const ownerPid  = await apiCreateProject(page, `E2E-shared-owner-${Date.now()}`, tenantId);
    const viewerPid = await apiCreateProject(page, `E2E-shared-viewer-${Date.now()}`, tenantId);
    const tmpEmail  = `tmp-shared-${Date.now()}@example.invalid`;
    const tmpUserId = await createTempUser(page, tenantId, tmpEmail);

    try {
      await demoteAdminInProject(page, viewerPid, adminId, tmpUserId, "viewer");

      await page.goto("/projects");
      await page.reload();
      await expect(page.locator("[data-cy=filter-viewer]")).toBeVisible({ timeout: 8000 });

      await page.locator("[data-cy=filter-viewer]").click();

      await expect(page.locator(`[data-cy="project-row-${viewerPid}"]`)).toBeVisible({ timeout: 3000 });
      await expect(page.locator(`[data-cy="project-row-${ownerPid}"]`)).not.toBeVisible();
    } finally {
      await apiDeleteProject(page, ownerPid);
      await apiDeleteProject(page, viewerPid);
      await deleteTempUser(page, tmpUserId);
    }
  });

  // ── Filter: All ────────────────────────────────────────────────────────────

  test("'All' shows projects of every role (owner and editor) together", async ({ page }) => {
    const { id: adminId, tenant_id: tenantId } = await getMe(page);
    const ownerPid  = await apiCreateProject(page, `E2E-all-owner-${Date.now()}`, tenantId);
    const editorPid = await apiCreateProject(page, `E2E-all-editor-${Date.now()}`, tenantId);
    const tmpEmail  = `tmp-all-${Date.now()}@example.invalid`;
    const tmpUserId = await createTempUser(page, tenantId, tmpEmail);

    try {
      await demoteAdminInProject(page, editorPid, adminId, tmpUserId, "editor");

      await page.goto("/projects");
      await page.reload();
      await expect(page.locator("[data-cy=filter-all]")).toBeVisible({ timeout: 8000 });

      // "All" is the default; both should be present
      await expect(page.locator(`[data-cy="project-row-${ownerPid}"]`)).toBeVisible({ timeout: 3000 });
      await expect(page.locator(`[data-cy="project-row-${editorPid}"]`)).toBeVisible();

      // Switch away then back to "All"
      await page.locator("[data-cy=filter-owner]").click();
      await page.locator("[data-cy=filter-all]").click();
      await expect(page.locator(`[data-cy="project-row-${ownerPid}"]`)).toBeVisible({ timeout: 3000 });
      await expect(page.locator(`[data-cy="project-row-${editorPid}"]`)).toBeVisible();
    } finally {
      await apiDeleteProject(page, ownerPid);
      await apiDeleteProject(page, editorPid);
      await deleteTempUser(page, tmpUserId);
    }
  });

  // ── Sort ───────────────────────────────────────────────────────────────────

  test("changing sort does not crash and table remains visible", async ({ page, workerTenantId }) => {
    const pid = await apiCreateProject(page, `E2E-sort-${Date.now()}`, workerTenantId);
    try {
      await page.goto("/projects");
      await expect(page.locator("[data-cy=projects-sort]")).toBeVisible({ timeout: 8000 });

      await page.locator("[data-cy=projects-sort]").selectOption("edited");
      await expect(page.locator("[data-cy=projects-table]")).toBeVisible({ timeout: 3000 });

      await page.locator("[data-cy=projects-sort]").selectOption("created");
      await expect(page.locator("[data-cy=projects-table]")).toBeVisible({ timeout: 3000 });

      await page.locator("[data-cy=projects-sort]").selectOption("activity");
      await expect(page.locator("[data-cy=projects-table]")).toBeVisible({ timeout: 3000 });
    } finally {
      await apiDeleteProject(page, pid);
    }
  });

  test("'Date created' sort puts the newest project first", async ({ page, workerTenantId }) => {
    const pid1 = await apiCreateProject(page, `E2E-sort-first-${Date.now()}`, workerTenantId);
    // Small delay so created_at timestamps differ
    await new Promise((r) => setTimeout(r, 1100));
    const pid2 = await apiCreateProject(page, `E2E-sort-second-${Date.now()}`, workerTenantId);
    try {
      await page.goto("/projects");
      await page.reload();
      await expect(page.locator("[data-cy=projects-sort]")).toBeVisible({ timeout: 8000 });

      await page.locator("[data-cy=projects-sort]").selectOption("created");
      // pid2 was created later → should appear before pid1 in the table.
      // Scan all rows to find relative positions — parallel workers may have
      // created other projects between or after our two, so we cannot assume
      // pid1/pid2 occupy rows 0 and 1.
      const rows = page.locator("[data-cy=projects-table] tbody tr");
      const rowCount = await rows.count();
      let idx1 = -1, idx2 = -1;
      for (let i = 0; i < rowCount; i++) {
        const id = await rows.nth(i).getAttribute("data-cy") ?? "";
        if (id.includes(pid1)) idx1 = i;
        if (id.includes(pid2)) idx2 = i;
        if (idx1 !== -1 && idx2 !== -1) break;
      }
      expect(idx2, `pid2 not found in table (pid1 at row ${idx1})`).not.toBe(-1);
      expect(idx1, `pid1 not found in table (pid2 at row ${idx2})`).not.toBe(-1);
      expect(idx2, "pid2 (newer) should appear before pid1 (older) when sorted by created desc").toBeLessThan(idx1);
    } finally {
      await apiDeleteProject(page, pid1);
      await apiDeleteProject(page, pid2);
    }
  });
});
