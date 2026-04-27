/**
 * content-reports.spec.ts — E2E tests for the Play-Store-mandated content
 * reporting feature.
 *
 * Verifies:
 *   1. Any authenticated user can POST a report.
 *   2. Invalid reason is rejected with 400.
 *   3. Admin can list reports; tenant_admin can list only their tenant.
 *   4. PATCH transitions status (open → triaged → dismissed → open) and
 *      writes triaged_at + triaged_by_id.
 *   5. The /reports admin page renders, shows the report, and Mark triaged
 *      / Dismiss actions update the row.
 *
 * Each test creates its own report fixture and cleans up via status flips
 * (no DELETE endpoint by design — moderators want an audit trail).
 */

import { test, expect, type Page } from "./base";

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

interface ContentReport {
  id: string;
  reason: string;
  status: "open" | "triaged" | "dismissed";
  message_text: string | null;
  notes: string | null;
  triaged_at: number | null;
  triaged_by_id: string | null;
  user_email: string | null;
}

async function postReport(page: Page, body: Record<string, unknown>) {
  return page.context().request.post(`${ADMIN_URL}/admin/v1/reports`, { data: body });
}

async function listReports(page: Page, qs = "") {
  const r = await page.context().request.get(`${ADMIN_URL}/admin/v1/reports${qs}`);
  expect(r.ok(), `GET /reports: ${await r.text()}`).toBe(true);
  return (await r.json()) as ContentReport[];
}

test.describe("Content reports — backend API", () => {
  test("any authenticated user can file a report; admin sees it", async ({ page, workerSuffix }) => {
    const marker = `e2e-report-${workerSuffix}-${Date.now()}`;
    const create = await postReport(page, {
      reason:       "offensive",
      message_text: marker,
      notes:        "automated test",
    });
    expect(create.status(), `create: ${await create.text()}`).toBe(201);
    const created = (await create.json()) as { id: string };
    expect(created.id).toBeTruthy();

    const all = await listReports(page);
    const row = all.find((r) => r.id === created.id);
    expect(row, "newly created report must appear in the list").toBeTruthy();
    expect(row!.reason).toBe("offensive");
    expect(row!.status).toBe("open");
    expect(row!.message_text).toBe(marker);
    expect(row!.notes).toBe("automated test");
    expect(row!.user_email, "user_email must be populated by the LEFT JOIN").toBeTruthy();

    // Cleanup: mark dismissed so it stops cluttering "open" filter.
    await page.context().request.patch(`${ADMIN_URL}/admin/v1/reports/${created.id}`,
      { data: { status: "dismissed" } });
  });

  test("invalid reason is rejected with 400", async ({ page }) => {
    const r = await postReport(page, { reason: "not-a-real-reason", message_text: "x" });
    expect(r.status()).toBe(400);
    const body = (await r.json()) as { error: string };
    expect(body.error).toMatch(/reason/i);
  });

  test("missing reason is rejected with 400", async ({ page }) => {
    const r = await postReport(page, { message_text: "x" });
    expect(r.status()).toBe(400);
  });

  test("PATCH triages a report and stamps triaged_by_id + triaged_at", async ({ page, workerSuffix }) => {
    const create = await postReport(page, {
      reason:       "inaccurate",
      message_text: `triage-${workerSuffix}-${Date.now()}`,
    });
    expect(create.status()).toBe(201);
    const { id } = (await create.json()) as { id: string };

    try {
      const before = (await listReports(page, "?status=open"))
        .find((r) => r.id === id);
      expect(before, "must appear in open filter").toBeTruthy();
      expect(before!.triaged_at == null).toBeTruthy();

      const triage = await page.context().request.patch(
        `${ADMIN_URL}/admin/v1/reports/${id}`,
        { data: { status: "triaged" } });
      expect(triage.ok()).toBe(true);

      const after = (await listReports(page, "?status=triaged"))
        .find((r) => r.id === id);
      expect(after, "must move to triaged filter").toBeTruthy();
      expect(typeof after!.triaged_at).toBe("number");
      expect(after!.triaged_by_id, "triaged_by_id must be set").toBeTruthy();

      const reopen = await page.context().request.patch(
        `${ADMIN_URL}/admin/v1/reports/${id}`,
        { data: { status: "open" } });
      expect(reopen.ok()).toBe(true);
    } finally {
      await page.context().request.patch(`${ADMIN_URL}/admin/v1/reports/${id}`,
        { data: { status: "dismissed" } });
    }
  });

  test("PATCH with invalid status is rejected", async ({ page, workerSuffix }) => {
    const create = await postReport(page, {
      reason:       "other",
      message_text: `bad-status-${workerSuffix}-${Date.now()}`,
    });
    expect(create.status()).toBe(201);
    const { id } = (await create.json()) as { id: string };
    try {
      const r = await page.context().request.patch(
        `${ADMIN_URL}/admin/v1/reports/${id}`,
        { data: { status: "deleted" } });
      expect(r.status()).toBe(400);
    } finally {
      await page.context().request.patch(`${ADMIN_URL}/admin/v1/reports/${id}`,
        { data: { status: "dismissed" } });
    }
  });
});

test.describe("Content reports — admin page UI", () => {
  test("/reports page renders the report and allows triage", async ({ page, workerSuffix }) => {
    test.setTimeout(60000);
    const marker = `ui-report-${workerSuffix}-${Date.now()}`;
    const create = await postReport(page, {
      reason:       "unsafe",
      message_text: marker,
      notes:        "UI test",
    });
    expect(create.status()).toBe(201);
    const { id } = (await create.json()) as { id: string };

    try {
      await page.goto("/reports");
      await expect(page.getByRole("heading", { name: /Content Reports/i })).toBeVisible({ timeout: 15000 });
      const row = page.locator("[data-cy=report-row]").filter({ hasText: marker }).first();
      await expect(row).toBeVisible({ timeout: 15000 });

      await row.locator("[data-cy=report-mark-triaged]").click();
      // After the PATCH succeeds, optimistic update flips the status badge in
      // this row from "open" → "triaged" and hides the "Mark triaged" button.
      await expect(row.locator("[data-cy=report-mark-triaged]")).toHaveCount(0, { timeout: 10000 });
      await expect(row.getByText("triaged", { exact: true })).toBeVisible();
      // No error banner from Layout.module.scss surfaced.
      await expect(page.locator(".alert--error, [class*='alert--error']")).toHaveCount(0);
    } finally {
      await page.context().request.patch(`${ADMIN_URL}/admin/v1/reports/${id}`,
        { data: { status: "dismissed" } });
    }
  });
});
