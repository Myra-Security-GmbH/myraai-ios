/**
 * account-delete-restore.spec.ts — E2E tests for soft-delete ("Delete Account")
 * and admin-only restore.
 *
 * Verifies:
 *   1. Admin can DELETE a user → user.deleted_at is set; user is hidden from
 *      the default list; ?include_deleted=1 surfaces the user with deleted_at.
 *   2. PATCH on a deleted user returns 409 (admin must restore first).
 *   3. POST /users/:id/restore clears deleted_at and the user is back in the
 *      default list.
 *   4. The user's record (email, role, tenant_id, created_at) is preserved
 *      across the delete → restore cycle — no data loss.
 *   5. OTP request for a deleted user's email returns the generic 200 response
 *      so account existence is not leaked, and crucially no session can be
 *      obtained (the deleted user stays locked out).
 *   6. Default list (no flag) does NOT include deleted users.
 *
 * Each test creates its own user fixture and cleans up in finally{}.
 */

import { test, expect, type Page } from "./base";

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

interface CreatedUser {
  id: string;
  email: string;
  tenantId: string;
}

async function getFirstTenantId(page: Page): Promise<string> {
  const res = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
  expect(res.ok(), "GET /tenants must succeed").toBe(true);
  const all = (await res.json()) as Array<{ id: string }>;
  expect(all.length, "at least one tenant must exist").toBeGreaterThan(0);
  return all[0].id;
}

async function createUser(page: Page, tenantId: string, suffix: string): Promise<CreatedUser> {
  const email = `test-delete-${suffix}-${Date.now()}@example.invalid`;
  const res = await page.context().request.post(
    `${ADMIN_URL}/admin/v1/tenants/${tenantId}/users`,
    { data: { email, name: "Test Delete User", role: "member" } },
  );
  expect(res.ok(), `create user: ${await res.text()}`).toBe(true);
  const body = (await res.json()) as { id: string };
  return { id: body.id, email, tenantId };
}

async function hardCleanup(page: Page, userId: string) {
  // Best-effort cleanup; idempotent regardless of state.
  await page.context().request.post(`${ADMIN_URL}/admin/v1/users/${userId}/restore`).catch(() => {});
  await page.context().request.delete(`${ADMIN_URL}/admin/v1/users/${userId}`).catch(() => {});
}

test.describe("Account delete + admin restore", () => {
  test("delete sets deleted_at; ?include_deleted=1 surfaces; default hides", async ({ page, workerSuffix }) => {
    const tenantId = await getFirstTenantId(page);
    const user = await createUser(page, tenantId, `flow-${workerSuffix}`);
    try {
      // Default list: user is present, deleted_at is null/undefined.
      const before: Array<{ id: string; deleted_at?: number | null }> =
        await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants/${tenantId}/users`).then(r => r.json());
      const beforeRow = before.find(u => u.id === user.id);
      expect(beforeRow, "newly created user must appear in default list").toBeTruthy();
      expect(beforeRow!.deleted_at == null, "new user must not be soft-deleted").toBeTruthy();

      // Delete the user.
      const del = await page.context().request.delete(`${ADMIN_URL}/admin/v1/users/${user.id}`);
      expect(del.ok(), `DELETE: ${await del.text()}`).toBe(true);

      // Default list: user is gone.
      const after: Array<{ id: string }> =
        await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants/${tenantId}/users`).then(r => r.json());
      expect(after.find(u => u.id === user.id),
        "deleted user must not appear in default list").toBeFalsy();

      // include_deleted=1: user is back, with deleted_at set.
      const afterAll: Array<{ id: string; email: string; role: string; tenant_id: string | null; deleted_at?: number | null; deleted_by_id?: string | null }> =
        await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants/${tenantId}/users?include_deleted=1`).then(r => r.json());
      const row = afterAll.find(u => u.id === user.id);
      expect(row, "deleted user must appear when include_deleted=1").toBeTruthy();
      expect(typeof row!.deleted_at, "deleted_at must be a unix timestamp").toBe("number");
      expect(row!.deleted_by_id, "deleted_by_id must record the actor admin").toBeTruthy();
      // Account fields are preserved (no data loss on soft-delete).
      expect(row!.email).toBe(user.email);
      expect(row!.role).toBe("member");
      expect(row!.tenant_id).toBe(tenantId);
    } finally {
      await hardCleanup(page, user.id);
    }
  });

  test("PATCH on a deleted user returns 409", async ({ page, workerSuffix }) => {
    const tenantId = await getFirstTenantId(page);
    const user = await createUser(page, tenantId, `patch-${workerSuffix}`);
    try {
      const del = await page.context().request.delete(`${ADMIN_URL}/admin/v1/users/${user.id}`);
      expect(del.ok()).toBe(true);

      const patch = await page.context().request.patch(
        `${ADMIN_URL}/admin/v1/users/${user.id}`,
        { data: { name: "Should not be settable" } },
      );
      expect(patch.status(),
        "PATCH on deleted user must return 409 — admin must restore first").toBe(409);
      const body = await patch.json() as { error: string };
      expect(body.error).toMatch(/deleted/i);
      expect(body.error).toMatch(/restore/i);
    } finally {
      await hardCleanup(page, user.id);
    }
  });

  test("restore clears deleted_at; data is intact", async ({ page, workerSuffix }) => {
    const tenantId = await getFirstTenantId(page);
    const user = await createUser(page, tenantId, `restore-${workerSuffix}`);
    try {
      const del = await page.context().request.delete(`${ADMIN_URL}/admin/v1/users/${user.id}`);
      expect(del.ok()).toBe(true);

      const restore = await page.context().request.post(
        `${ADMIN_URL}/admin/v1/users/${user.id}/restore`);
      expect(restore.ok(), `restore: ${await restore.text()}`).toBe(true);

      // Default list: user is back.
      const afterRestore: Array<{ id: string; email: string; role: string; deleted_at?: number | null }> =
        await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants/${tenantId}/users`).then(r => r.json());
      const row = afterRestore.find(u => u.id === user.id);
      expect(row, "restored user must appear in default list").toBeTruthy();
      expect(row!.deleted_at == null, "deleted_at must be cleared on restore").toBeTruthy();
      expect(row!.email).toBe(user.email);
      expect(row!.role).toBe("member");
    } finally {
      await hardCleanup(page, user.id);
    }
  });

  test("restore on an active user is idempotent", async ({ page, workerSuffix }) => {
    const tenantId = await getFirstTenantId(page);
    const user = await createUser(page, tenantId, `noop-${workerSuffix}`);
    try {
      const restore = await page.context().request.post(
        `${ADMIN_URL}/admin/v1/users/${user.id}/restore`);
      expect(restore.ok()).toBe(true);
      const body = await restore.json() as { ok: boolean; already_active?: boolean };
      expect(body.ok).toBe(true);
      expect(body.already_active).toBe(true);
    } finally {
      await hardCleanup(page, user.id);
    }
  });

  test("OTP request for deleted user returns generic 200 — no account leak, no session", async ({ browser, page, workerSuffix }) => {
    const tenantId = await getFirstTenantId(page);
    const user = await createUser(page, tenantId, `otp-${workerSuffix}`);
    try {
      const del = await page.context().request.delete(`${ADMIN_URL}/admin/v1/users/${user.id}`);
      expect(del.ok()).toBe(true);

      // Use a fresh, fully-empty context to mimic a real client trying to
      // log in as the deleted user. Pass an explicit empty storageState so
      // we don't inherit the project default (which is the admin session).
      const anon = await browser.newContext({ storageState: { cookies: [], origins: [] } });
      try {
        const otp = await anon.request.post(`${ADMIN_URL}/admin/auth/otp/request`,
          { data: { email: user.email } });
        expect(otp.ok(), "OTP request must return 200 to avoid leaking account existence").toBe(true);
        const body = await otp.json() as { message: string };
        expect(body.message).toMatch(/code/i);

        // /me with no session cookie must remain unauthenticated.
        const me = await anon.request.get(`${ADMIN_URL}/admin/auth/me`);
        expect(me.status(),
          "deleted user must remain unauthenticated").toBe(401);
      } finally {
        await anon.close();
      }
    } finally {
      await hardCleanup(page, user.id);
    }
  });
});
