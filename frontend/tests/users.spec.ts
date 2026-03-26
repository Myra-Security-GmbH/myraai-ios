import { test, expect } from "@playwright/test";
import { execSync } from "child_process";

// ---------------------------------------------------------------------------
// Admin completeness: role=admin must see ALL users across all tenants
// ---------------------------------------------------------------------------

test.describe("admin sees all users", () => {
  test("admin user list includes themselves and all tenant users", async ({ page }) => {
    const adminBase = process.env.PLAYWRIGHT_ADMIN_URL ?? "";

    // Fetch ground-truth counts directly from the API
    const tenantsRes = await page.request.get(`${adminBase}/admin/v1/tenants`);
    expect(tenantsRes.ok()).toBe(true);
    const tenants: Array<{ id: string; slug: string }> = await tenantsRes.json();

    // Collect every user from every tenant
    const tenantUsers: Array<{ id: string; email: string }> = [];
    for (const t of tenants) {
      const res = await page.request.get(`${adminBase}/admin/v1/tenants/${t.id}/users`);
      if (res.ok()) tenantUsers.push(...await res.json());
    }

    // Global admins (tenant_id = NULL) via /users
    const globalRes = await page.request.get(`${adminBase}/admin/v1/users`);
    expect(globalRes.ok()).toBe(true);
    const globalUsers: Array<{ id: string; email: string }> = await globalRes.json();

    // Full expected set — deduplicate by id (same logic as the frontend)
    const all = [...tenantUsers, ...globalUsers];
    const expected = all.filter((u, i, arr) => arr.findIndex((x) => x.id === u.id) === i);
    expect(expected.length).toBeGreaterThan(0);

    // -----------------------------------------------------------------------
    // Now load the Users page and verify the UI shows the same set
    // -----------------------------------------------------------------------
    await page.goto("/users");
    // Wait for all API calls (tenants + per-tenant users + /users) to settle
    await page.waitForLoadState("networkidle");
    // Extra buffer for React state flush
    await page.waitForTimeout(600);

    // The subtitle must reflect the full count
    await expect(page.getByText(new RegExp(`${expected.length}\\s+users?`))).toBeVisible();

    // Every expected email must appear at least once in the table
    const emailCells = await page.locator("tbody td:first-child").allTextContents();
    const missingEmails: string[] = [];
    for (const u of expected) {
      if (!emailCells.some(e => e.trim() === u.email)) {
        missingEmails.push(u.email);
      }
    }
    expect(missingEmails, `Missing from users table: ${missingEmails.join(", ")}`).toHaveLength(0);
  });

  test("logged-in admin appears in their own user list", async ({ page }) => {
    const adminBase = process.env.PLAYWRIGHT_ADMIN_URL ?? "";

    // Identify who is currently logged in
    const meRes = await page.request.get(`${adminBase}/admin/auth/me`);
    expect(meRes.ok()).toBe(true);
    const me: { email: string; role: string } = await meRes.json();
    expect(me.role).toBe("admin");

    await page.goto("/users");
    await page.waitForLoadState("networkidle");
    await page.waitForTimeout(600);

    const emailCells = await page.locator("tbody td:first-child").allTextContents();
    expect(
      emailCells.some(e => e.trim() === me.email),
      `Logged-in admin "${me.email}" not visible in users table`
    ).toBe(true);
  });
});

const DB = "/opt/ai-gateway/data/config.db";

test.describe("Users page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/users");
    await page.waitForTimeout(400);
  });

  // ---------------------------------------------------------------------------
  // List view
  // ---------------------------------------------------------------------------

  test("shows page heading and user count subtitle", async ({ page }) => {
    await expect(page.getByRole("heading", { name: "Users" })).toBeVisible();
    await expect(page.getByText(/\d+ users?/)).toBeVisible();
  });

  test("shows users table or empty state", async ({ page }) => {
    const hasTable = await page.locator("table").isVisible().catch(() => false);
    const hasEmpty = await page.getByText(/No users yet/).isVisible().catch(() => false);
    expect(hasTable || hasEmpty).toBe(true);
  });

  test("user rows are clickable and navigate to detail", async ({ page }) => {
    const rows = page.locator("tbody tr");
    if (await rows.count() === 0) { test.skip(); return; }
    await rows.first().click();
    await expect(page.getByRole("button", { name: /← Users/i })).toBeVisible();
  });

  test("back button returns to list", async ({ page }) => {
    const rows = page.locator("tbody tr");
    if (await rows.count() === 0) { test.skip(); return; }
    await rows.first().click();
    await page.getByRole("button", { name: /← Users/i }).click();
    await expect(page.getByRole("heading", { name: "Users" })).toBeVisible();
  });

  test("Open → button navigates to detail", async ({ page }) => {
    const openBtn = page.getByRole("button", { name: "Open →" }).first();
    if (!await openBtn.isVisible().catch(() => false)) { test.skip(); return; }
    await openBtn.click();
    await expect(page.getByRole("button", { name: /← Users/i })).toBeVisible();
  });

  test("table shows Email, Name, Role, Tenant columns", async ({ page }) => {
    if (!await page.locator("table").isVisible().catch(() => false)) { test.skip(); return; }
    const headers = page.locator("thead th");
    await expect(headers.filter({ hasText: "Email" })).toBeVisible();
    await expect(headers.filter({ hasText: "Name" })).toBeVisible();
    await expect(headers.filter({ hasText: "Role" })).toBeVisible();
    await expect(headers.filter({ hasText: "Tenant" })).toBeVisible();
  });

  test("shows role badges in the table", async ({ page }) => {
    if (!await page.locator("table").isVisible().catch(() => false)) { test.skip(); return; }
    const badges = page.locator("tbody .badge, tbody [class*='badge']");
    await expect(badges.first()).toBeVisible();
  });

  test("admin user sees tenant filter dropdown or is scoped to one tenant", async ({ page }) => {
    // Platform admin: shows "All tenants" select; tenant-member: no dropdown (scoped to own tenant)
    const hasFilter = await page.getByRole("option", { name: "All tenants" }).isVisible().catch(() => false);
    const hasTable  = await page.locator("table").isVisible().catch(() => false);
    const hasEmpty  = await page.getByText(/No users yet/).isVisible().catch(() => false);
    // Either the filter exists (admin), or the page loaded normally (member)
    expect(hasFilter || hasTable || hasEmpty).toBe(true);
  });

  // ---------------------------------------------------------------------------
  // Detail view
  // ---------------------------------------------------------------------------

  test("detail shows stat cards: Email, Name, Role, Tenant", async ({ page }) => {
    const rows = page.locator("tbody tr");
    if (await rows.count() === 0) { test.skip(); return; }
    await rows.first().click();
    // Stat labels are in .stat-label divs — use more specific locators to avoid matching table headers
    const statLabels = page.locator("[class*='stat-label']");
    await expect(statLabels.filter({ hasText: "Email" })).toBeVisible();
    await expect(statLabels.filter({ hasText: "Name" })).toBeVisible();
    await expect(statLabels.filter({ hasText: "Role" })).toBeVisible();
    await expect(statLabels.filter({ hasText: "Tenant" })).toBeVisible();
  });

  test("detail shows Tokens section heading", async ({ page }) => {
    const rows = page.locator("tbody tr");
    if (await rows.count() === 0) { test.skip(); return; }
    await rows.first().click();
    await expect(page.getByRole("heading", { name: "Tokens" })).toBeVisible();
  });

  test("Edit button opens edit modal", async ({ page }) => {
    const rows = page.locator("tbody tr");
    if (await rows.count() === 0) { test.skip(); return; }
    await rows.first().click();
    await page.getByRole("button", { name: /^Edit$/i }).click();
    await expect(page.getByRole("heading", { name: /Edit:/i })).toBeVisible();
  });

  test("edit modal pre-fills email field", async ({ page }) => {
    const rows = page.locator("tbody tr");
    if (await rows.count() === 0) { test.skip(); return; }
    // grab the email from the first row before clicking
    const emailCell = rows.first().locator("td").first();
    const email = await emailCell.textContent();
    await rows.first().click();
    await page.getByRole("button", { name: /^Edit$/i }).click();
    const emailInput = page.getByPlaceholder("alice@example.com");
    await expect(emailInput).toHaveValue(email?.trim() ?? /.+/);
  });

  // ---------------------------------------------------------------------------
  // New User modal
  // ---------------------------------------------------------------------------

  test("+ New User opens modal", async ({ page }) => {
    await page.getByRole("button", { name: /New User/i }).click();
    await expect(page.getByRole("heading", { name: "New User" })).toBeVisible();
  });

  test("modal has email, name, role fields", async ({ page }) => {
    await page.getByRole("button", { name: /New User/i }).click();
    await expect(page.getByPlaceholder("alice@example.com")).toBeVisible();
    // Use exact match to avoid substring collision with "alice@example.com"
    await expect(page.getByPlaceholder("Alice", { exact: true })).toBeVisible();
    await expect(page.getByRole("option", { name: /member/i })).toBeAttached();
  });

  test("email is required — submit without email focuses input", async ({ page }) => {
    await page.getByRole("button", { name: /New User/i }).click();
    await page.getByRole("button", { name: "Create User" }).click();
    await expect(page.getByPlaceholder("alice@example.com")).toBeFocused();
  });

  test("Cancel closes New User modal", async ({ page }) => {
    await page.getByRole("button", { name: /New User/i }).click();
    await page.getByRole("button", { name: "Cancel" }).click();
    await expect(page.getByRole("heading", { name: "New User" })).not.toBeVisible();
  });

  // ---------------------------------------------------------------------------
  // Create user — full flow
  // ---------------------------------------------------------------------------

  const TEST_EMAIL = "e2e-create-user-test@local.test";

  test.beforeAll(async () => {
    // Hard-delete any leftover test user directly from the DB to ensure a clean slate.
    if (process.env.PLAYWRIGHT_ADMIN_URL) {
      // Docker mode — MySQL
      const DB_HOST = "172.17.0.1";
      const DB_USER = "gateway";
      const DB_PASS = "gateway";
      const DB_NAME = "ai_gateway";
      try {
        execSync(
          `mysql -h ${DB_HOST} -u ${DB_USER} -p${DB_PASS} ${DB_NAME} -e "DELETE FROM user WHERE email='${TEST_EMAIL}'"`,
          { stdio: "pipe" }
        );
      } catch { /* ignore — user may not exist */ }
    } else {
      execSync(`sqlite3 ${DB} "DELETE FROM user WHERE email='${TEST_EMAIL}'"`);
    }
  });

  test("create user — fills form and submits successfully", async ({ page }) => {
    // Ensure at least one tenant exists; skip gracefully if not
    const adminBase = process.env.PLAYWRIGHT_ADMIN_URL ?? "";
    const orgsRes = await page.request.get(`${adminBase}/admin/v1/tenants`);
    if (!orgsRes.ok() || (await orgsRes.json()).length === 0) { test.skip(); return; }

    await page.getByRole("button", { name: /New User/i }).click();
    await expect(page.getByRole("heading", { name: "New User" })).toBeVisible();

    await page.getByPlaceholder("alice@example.com").fill(TEST_EMAIL);
    await page.getByPlaceholder("Alice", { exact: true }).fill("E2E Test User");
    // Scope to the Role form-group to avoid ambiguity with org / gateway selects
    await page.locator("[class*='form-group']").filter({ hasText: "Role" }).getByRole("combobox").selectOption("member");

    await page.getByRole("button", { name: "Create User" }).click();

    // Modal closes on success
    await expect(page.getByRole("heading", { name: "New User" })).not.toBeVisible({ timeout: 5000 });

    // No inline error shown
    await expect(page.locator("[class*='alert--error']")).not.toBeVisible();
  });

  test("create user — new user appears in the list", async ({ page }) => {
    // If the previous test created the user, it should now appear in the table.
    const rows = page.locator("tbody tr");
    const count = await rows.count();
    if (count === 0) { test.skip(); return; }

    const emails = await page.locator("tbody td:first-child").allTextContents();
    expect(emails.some(e => e.includes(TEST_EMAIL))).toBe(true);
  });

  test("create user — duplicate email shows error", async ({ page }) => {
    const adminBase = process.env.PLAYWRIGHT_ADMIN_URL ?? "";
    const orgsRes = await page.request.get(`${adminBase}/admin/v1/tenants`);
    if (!orgsRes.ok() || (await orgsRes.json()).length === 0) { test.skip(); return; }

    // Try to create the same email again
    await page.getByRole("button", { name: /New User/i }).click();
    await page.getByPlaceholder("alice@example.com").fill(TEST_EMAIL);
    await page.getByRole("button", { name: "Create User" }).click();

    // Modal stays open and shows an error
    await expect(page.getByRole("heading", { name: "New User" })).toBeVisible({ timeout: 5000 });
    await expect(page.locator("[class*='alert--error']").first()).toBeVisible();
  });
});
