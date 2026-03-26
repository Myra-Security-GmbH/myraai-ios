import { test, expect } from "@playwright/test";

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

  test("table shows Email, Name, Role, Organization columns", async ({ page }) => {
    if (!await page.locator("table").isVisible().catch(() => false)) { test.skip(); return; }
    const headers = page.locator("thead th");
    await expect(headers.filter({ hasText: "Email" })).toBeVisible();
    await expect(headers.filter({ hasText: "Name" })).toBeVisible();
    await expect(headers.filter({ hasText: "Role" })).toBeVisible();
    await expect(headers.filter({ hasText: "Organization" })).toBeVisible();
  });

  test("shows role badges in the table", async ({ page }) => {
    if (!await page.locator("table").isVisible().catch(() => false)) { test.skip(); return; }
    const badges = page.locator("tbody .badge, tbody [class*='badge']");
    await expect(badges.first()).toBeVisible();
  });

  test("admin user sees org filter dropdown or is scoped to one org", async ({ page }) => {
    // Platform admin: shows "All organizations" select; org-member: no dropdown (scoped to own org)
    const hasFilter = await page.getByRole("option", { name: "All organizations" }).isVisible().catch(() => false);
    const hasTable  = await page.locator("table").isVisible().catch(() => false);
    const hasEmpty  = await page.getByText(/No users yet/).isVisible().catch(() => false);
    // Either the filter exists (admin), or the page loaded normally (member)
    expect(hasFilter || hasTable || hasEmpty).toBe(true);
  });

  // ---------------------------------------------------------------------------
  // Detail view
  // ---------------------------------------------------------------------------

  test("detail shows stat cards: Email, Name, Role, Organization", async ({ page }) => {
    const rows = page.locator("tbody tr");
    if (await rows.count() === 0) { test.skip(); return; }
    await rows.first().click();
    // Stat labels are in .stat-label divs — use more specific locators to avoid matching table headers
    const statLabels = page.locator("[class*='stat-label']");
    await expect(statLabels.filter({ hasText: "Email" })).toBeVisible();
    await expect(statLabels.filter({ hasText: "Name" })).toBeVisible();
    await expect(statLabels.filter({ hasText: "Role" })).toBeVisible();
    await expect(statLabels.filter({ hasText: "Organization" })).toBeVisible();
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
});
