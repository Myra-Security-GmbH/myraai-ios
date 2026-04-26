/**
 * users-edit.spec.ts — verifies that edits made to a user on the detail page
 * (/users/:id) are reflected immediately when navigating back to the list
 * (/users) and that the list does not show stale data.
 *
 * Covers:
 *  1. Changing the user's name   → reflected in list row after ← Users
 *  2. Changing the user's role   → reflected in list row after ← Users
 *  3. Changing the user's tenant → reflected in list row after ← Users
 *     (the hard case: old code fetched via old tenant_id, missed the user)
 *  4. GET /admin/v1/users/:id    → returns the user object (new endpoint)
 */

import { test, expect, type Page } from "./base";

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

interface CreatedUser {
  id: string;
  email: string;
  tenantId: string;
}

async function getFirstTwoTenants(page: Page): Promise<Array<{ id: string; slug: string }>> {
  const res = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
  expect(res.ok(), "GET /tenants must succeed").toBe(true);
  const all = (await res.json()) as Array<{ id: string; slug: string }>;
  return all.slice(0, 2);
}

async function createTestUser(page: Page, tenantId: string, suffix: string): Promise<CreatedUser> {
  const email = `test-edit-${suffix}-${Date.now()}@example.invalid`;
  const res = await page.context().request.post(`${ADMIN_URL}/admin/v1/tenants/${tenantId}/users`, {
    data: { email, name: "Test Edit User", role: "member" },
  });
  expect(res.ok(), `create user: ${await res.text()}`).toBe(true);
  const body = (await res.json()) as { id: string };
  return { id: body.id, email, tenantId };
}

async function deleteUser(page: Page, userId: string) {
  await page.context().request.delete(`${ADMIN_URL}/admin/v1/users/${userId}`).catch(() => {});
}

/** Navigate to /users, wait for the table, return email cells. */
async function gotoUserList(page: Page): Promise<string[]> {
  await page.goto("/users");
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(400);
  return page.locator("tbody td:first-child").allTextContents();
}

/** Find the row for a user email and return the row locator. */
function userRow(page: Page, email: string) {
  return page.locator("tbody tr").filter({ hasText: email });
}

/** Open the user's detail page via the table row. */
async function openUserDetail(page: Page, email: string) {
  const row = userRow(page, email);
  await row.waitFor({ state: "visible", timeout: 8000 });
  await row.locator("button", { hasText: "Open" }).click();
  await page.waitForURL(/\/users\/.+/);
  await page.waitForTimeout(300);
}

/** Click Edit, change fields, Save, then click ← Users. */
async function editUserAndGoBack(
  page: Page,
  changes: { name?: string; role?: string; tenantSlug?: string; tenantId?: string },
) {
  await page.getByRole("button", { name: "Edit" }).click();
  const modal = page.locator("[class*='modal'], [role='dialog']").first();
  await modal.waitFor({ state: "visible", timeout: 5000 });

  if (changes.name !== undefined) {
    const nameInput = modal.locator("input[placeholder='Alice']");
    await nameInput.fill(changes.name);
  }
  if (changes.role !== undefined) {
    const roleSelect = modal.locator("select").last();
    await roleSelect.selectOption({ value: changes.role });
  }
  if (changes.tenantId !== undefined) {
    const tenantSelect = modal.locator("select").first();
    await tenantSelect.selectOption({ value: changes.tenantId });
  } else if (changes.tenantSlug !== undefined) {
    const tenantSelect = modal.locator("select").first();
    await tenantSelect.selectOption({ label: changes.tenantSlug });
  }

  await modal.getByRole("button", { name: /save changes/i }).click();
  await modal.waitFor({ state: "hidden", timeout: 5000 });

  // Click ← Users to go back
  await page.getByRole("button", { name: /← users/i }).click();
  await page.waitForURL("/users");
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(400);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Users — list invalidation after edit", () => {
  test.setTimeout(60_000);

  test("changing a user's name is reflected in the list immediately", async ({ page }) => {
    const tenants = await getFirstTwoTenants(page);
    if (tenants.length === 0) { test.skip(true, "No tenants configured in this environment"); return; }

    const u = await createTestUser(page, tenants[0].id, "name");
    try {
      await gotoUserList(page);
      await openUserDetail(page, u.email);
      await editUserAndGoBack(page, { name: "Renamed User" });

      // The list must show the new name
      const row = userRow(page, u.email);
      await expect(row).toBeVisible({ timeout: 5000 });
      await expect(row.locator("td").nth(1)).toHaveText("Renamed User");
    } finally {
      await deleteUser(page, u.id);
    }
  });

  test("changing a user's role is reflected in the list immediately", async ({ page }) => {
    const tenants = await getFirstTwoTenants(page);
    if (tenants.length === 0) { test.skip(true, "No tenants configured in this environment"); return; }

    const u = await createTestUser(page, tenants[0].id, "role");
    try {
      await gotoUserList(page);
      await openUserDetail(page, u.email);
      await editUserAndGoBack(page, { role: "viewer" });

      const row = userRow(page, u.email);
      await expect(row).toBeVisible({ timeout: 5000 });
      // Role badge should say "viewer"
      await expect(row).toContainText("viewer");
    } finally {
      await deleteUser(page, u.id);
    }
  });

  test("changing a user's tenant is reflected in the list (stale-state regression)", async ({ page }) => {
    const tenants = await getFirstTwoTenants(page);
    if (tenants.length < 2) {
      test.skip(true, "Need at least 2 tenants to test tenant change");
      return;
    }

    const [tenantA, tenantB] = tenants;
    const u = await createTestUser(page, tenantA.id, "tenant");
    try {
      await gotoUserList(page);

      // Filter to tenantA so the user is visible
      const tenantFilter = page.locator("select").first();
      if (await tenantFilter.isVisible()) {
        await tenantFilter.selectOption(tenantA.id);
        await page.waitForTimeout(400);
      }

      await openUserDetail(page, u.email);

      // Change tenant to tenantB
      await editUserAndGoBack(page, { tenantId: tenantB.id });

      // After going back (with the filter cleared / all tenants):
      // reset filter to show all users
      const tenantFilterBack = page.locator("select").first();
      if (await tenantFilterBack.isVisible()) {
        await tenantFilterBack.selectOption("");
        await page.waitForTimeout(400);
      }

      // The user must still be in the list (previously would disappear or show stale tenant)
      const row = userRow(page, u.email);
      await expect(row).toBeVisible({ timeout: 5000 });
      // Tenant column should now show tenantB
      await expect(row).toContainText(tenantB.slug);
    } finally {
      await deleteUser(page, u.id);
    }
  });

  test("list does not show stale data after navigating back without editing", async ({ page }) => {
    const tenants = await getFirstTwoTenants(page);
    if (tenants.length === 0) { test.skip(true, "No tenants configured in this environment"); return; }

    const u = await createTestUser(page, tenants[0].id, "nochange");
    try {
      await gotoUserList(page);
      await openUserDetail(page, u.email);

      // Go back without editing
      await page.getByRole("button", { name: /← users/i }).click();
      await page.waitForURL("/users");
      await page.waitForLoadState("networkidle");
      await page.waitForTimeout(400);

      // User must still be visible
      await expect(userRow(page, u.email)).toBeVisible({ timeout: 5000 });
    } finally {
      await deleteUser(page, u.id);
    }
  });
});

// ---------------------------------------------------------------------------
// New API endpoint: GET /admin/v1/users/:id
// ---------------------------------------------------------------------------

test.describe("GET /admin/v1/users/:id", () => {
  test("returns the user object for an existing user", async ({ page }) => {
    const tenants = await getFirstTwoTenants(page);
    if (tenants.length === 0) { test.skip(true, "No tenants configured in this environment"); return; }

    const u = await createTestUser(page, tenants[0].id, "getbyid");
    try {
      const res = await page.context().request.get(`${ADMIN_URL}/admin/v1/users/${u.id}`);
      expect(res.ok(), `GET /users/:id must return 200, got ${res.status()}`).toBe(true);

      const body = (await res.json()) as Record<string, unknown>;
      expect(body.id).toBe(u.id);
      expect(body.email).toBe(u.email);
      expect(body.tenant_id).toBe(tenants[0].id);
    } finally {
      await deleteUser(page, u.id);
    }
  });

  test("returns 404 for an unknown user id", async ({ page }) => {
    const res = await page.context().request.get(`${ADMIN_URL}/admin/v1/users/nonexistent-user-id-xyz`);
    expect(res.status()).toBe(404);
  });

  test("PATCH /users/:id returns the updated user object", async ({ page }) => {
    const tenants = await getFirstTwoTenants(page);
    if (tenants.length === 0) { test.skip(true, "No tenants configured in this environment"); return; }

    const u = await createTestUser(page, tenants[0].id, "patchreturn");
    try {
      const res = await page.context().request.patch(`${ADMIN_URL}/admin/v1/users/${u.id}`, {
        data: { name: "Patched Name" },
      });
      expect(res.ok()).toBe(true);
      const body = (await res.json()) as Record<string, unknown>;
      // PATCH now returns the updated user (not just { ok: true })
      expect(body.id).toBe(u.id);
      expect(body.name).toBe("Patched Name");
    } finally {
      await deleteUser(page, u.id);
    }
  });
});
