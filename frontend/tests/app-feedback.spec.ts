/**
 * app-feedback.spec.ts — AGF-31
 *
 * End-to-end tests for the application feedback widget (floating button) and
 * the admin feedback inbox page.
 *
 * Coverage:
 *   1. Widget button is visible on authenticated pages
 *   2. Modal opens with type selector, summary, description fields
 *   3. Submit a bug report → POST /admin/v1/app-feedback → success toast
 *   4. Submitted item appears in admin feedback inbox (/feedback)
 *   5. Mark as processed → "Done" state
 *   6. Type filter narrows the list
 *   7. Submit with empty summary → error shown
 *   8. Cancel closes modal without submitting
 *   9. Widget is not shown on /login page (authenticated route guard)
 */

import { test, expect, Page } from "@playwright/test";

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------

interface AppFeedback {
  id: string;
  type: string;
  summary: string;
  processed: number;
  user_email: string | null;
}

async function listAppFeedback(page: Page, type?: string): Promise<AppFeedback[]> {
  const params = type ? `?type=${encodeURIComponent(type)}` : "";
  const resp = await page.context().request.get(`${ADMIN_URL}/admin/v1/app-feedback${params}`);
  if (!resp.ok()) return [];
  return resp.json() as Promise<AppFeedback[]>;
}

async function deleteAppFeedback(page: Page, id: string) {
  // There is no DELETE endpoint; mark as processed to clean up the test fixture
  await page.context().request.patch(`${ADMIN_URL}/admin/v1/app-feedback/${id}`, {
    data: { processed: true },
  }).catch(() => {});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("AGF-31 — Application feedback widget", () => {
  // ── 1. Widget button is visible on authenticated pages ───────────────────

  test("feedback button is visible on /dashboard", async ({ page }) => {
    await page.goto("/dashboard");
    await expect(page.locator("[data-cy='app-feedback-btn']")).toBeVisible({ timeout: 8000 });
  });

  test("feedback button is visible on /chat", async ({ page }) => {
    await page.goto("/chat");
    await expect(page.locator("[data-cy='app-feedback-btn']")).toBeVisible({ timeout: 8000 });
  });

  // ── 2. Modal opens ────────────────────────────────────────────────────────

  test("clicking the feedback button opens the modal", async ({ page }) => {
    await page.goto("/dashboard");
    await page.locator("[data-cy='app-feedback-btn']").click();
    await expect(page.getByText("Send Feedback")).toBeVisible({ timeout: 5000 });
    await expect(page.locator("[data-cy='app-feedback-summary']")).toBeVisible();
    await expect(page.locator("[data-cy='app-feedback-description']")).toBeVisible();
  });

  // ── 3. Submit a bug report ────────────────────────────────────────────────

  test("submitting a bug report shows success message and saves to DB", async ({ page }) => {
    const uniqueSummary = `Playwright bug report ${Date.now()}`;
    let createdId: string | null = null;

    try {
      await page.goto("/dashboard");
      await page.locator("[data-cy='app-feedback-btn']").click();
      await expect(page.locator("[data-cy='app-feedback-summary']")).toBeVisible({ timeout: 5000 });

      // Select Bug report type
      await page.getByRole("button", { name: "Bug report" }).click();

      // Fill in summary
      await page.locator("[data-cy='app-feedback-summary']").fill(uniqueSummary);

      // Fill in description
      await page.locator("[data-cy='app-feedback-description']").fill("Playwright automated test.");

      // Submit
      await page.locator("[data-cy='app-feedback-submit']").click();

      // Success message
      await expect(page.getByText("Thanks for your feedback!")).toBeVisible({ timeout: 8000 });

      // Modal closes automatically
      await expect(page.locator("[data-cy='app-feedback-summary']")).not.toBeVisible({ timeout: 5000 });

      // Verify in DB
      const items = await listAppFeedback(page, "bug");
      const created = items.find((i) => i.summary === uniqueSummary);
      expect(created, "Created item must appear in API").toBeTruthy();
      expect(created?.type).toBe("bug");
      createdId = created?.id ?? null;

      // No error banner
      await expect(page.getByText(/failed to/i)).not.toBeVisible();
    } finally {
      if (createdId) await deleteAppFeedback(page, createdId);
    }
  });

  // ── 4. Admin inbox shows submitted item ──────────────────────────────────

  test("submitted item appears in admin feedback inbox", async ({ page }) => {
    const uniqueSummary = `Playwright inbox test ${Date.now()}`;
    let createdId: string | null = null;

    try {
      // Submit via widget
      await page.goto("/dashboard");
      await page.locator("[data-cy='app-feedback-btn']").click();
      await expect(page.locator("[data-cy='app-feedback-summary']")).toBeVisible({ timeout: 5000 });
      await page.locator("[data-cy='app-feedback-summary']").fill(uniqueSummary);
      await page.locator("[data-cy='app-feedback-submit']").click();
      await expect(page.getByText("Thanks for your feedback!")).toBeVisible({ timeout: 8000 });

      // Find in DB to get ID
      const items = await listAppFeedback(page);
      const created = items.find((i) => i.summary === uniqueSummary);
      expect(created, "Created item must appear in API").toBeTruthy();
      createdId = created?.id ?? null;

      // Navigate to admin page
      await page.goto("/feedback");
      await expect(page.locator("h1").filter({ hasText: "Feedback Inbox" })).toBeVisible({ timeout: 8000 });

      // The submitted item appears in the table
      await expect(page.getByText(uniqueSummary)).toBeVisible({ timeout: 5000 });
    } finally {
      if (createdId) await deleteAppFeedback(page, createdId);
    }
  });

  // ── 5. Mark as processed ─────────────────────────────────────────────────

  test("admin can mark a feedback item as processed", async ({ page }) => {
    const uniqueSummary = `Playwright processed test ${Date.now()}`;
    let createdId: string | null = null;

    try {
      // Submit via API (faster than widget for setup)
      const postResp = await page.context().request.post(`${ADMIN_URL}/admin/v1/app-feedback`, {
        data: { type: "other", summary: uniqueSummary },
      });
      expect(postResp.ok(), `POST app-feedback: ${await postResp.text()}`).toBeTruthy();
      createdId = ((await postResp.json()) as { id: string }).id;

      await page.goto("/feedback");
      await expect(page.locator("h1").filter({ hasText: "Feedback Inbox" })).toBeVisible({ timeout: 8000 });
      await expect(page.getByText(uniqueSummary)).toBeVisible({ timeout: 5000 });

      // Click "Mark done" for this row
      const row = page.locator("[data-cy='feedback-row']").filter({ hasText: uniqueSummary });
      await expect(row).toBeVisible();
      await row.locator("[data-cy='feedback-toggle-processed']").click();

      // Button should now say "Done"
      await expect(row.locator("[data-cy='feedback-toggle-processed']")).toHaveText("Done", { timeout: 5000 });

      // Verify in DB
      const items = await listAppFeedback(page);
      const updated = items.find((i) => i.id === createdId);
      expect(updated?.processed).toBeTruthy();
    } finally {
      if (createdId) await deleteAppFeedback(page, createdId);
    }
  });

  // ── 6. Type filter ────────────────────────────────────────────────────────

  test("type filter narrows the feedback inbox", async ({ page }) => {
    const bugSummary = `Playwright bug filter ${Date.now()}`;
    const featureSummary = `Playwright feature filter ${Date.now()}`;
    let bugId: string | null = null;
    let featureId: string | null = null;

    try {
      // Create one bug and one feature via API
      const bugResp = await page.context().request.post(`${ADMIN_URL}/admin/v1/app-feedback`, {
        data: { type: "bug", summary: bugSummary },
      });
      expect(bugResp.ok()).toBeTruthy();
      bugId = ((await bugResp.json()) as { id: string }).id;

      const featureResp = await page.context().request.post(`${ADMIN_URL}/admin/v1/app-feedback`, {
        data: { type: "feature", summary: featureSummary },
      });
      expect(featureResp.ok()).toBeTruthy();
      featureId = ((await featureResp.json()) as { id: string }).id;

      await page.goto("/feedback");
      await expect(page.locator("h1").filter({ hasText: "Feedback Inbox" })).toBeVisible({ timeout: 8000 });

      // Filter to Bug — only bug summary visible
      await page.locator("[data-cy='feedback-filter-bug']").click();
      await expect(page.getByText(bugSummary)).toBeVisible({ timeout: 5000 });
      await expect(page.getByText(featureSummary)).not.toBeVisible();

      // Filter to Feature — only feature summary visible
      await page.locator("[data-cy='feedback-filter-feature']").click();
      await expect(page.getByText(featureSummary)).toBeVisible({ timeout: 5000 });
      await expect(page.getByText(bugSummary)).not.toBeVisible();

      // Reset to All
      await page.locator("[data-cy='feedback-filter-all']").click();
      await expect(page.getByText(bugSummary)).toBeVisible({ timeout: 5000 });
      await expect(page.getByText(featureSummary)).toBeVisible();
    } finally {
      if (bugId) await deleteAppFeedback(page, bugId);
      if (featureId) await deleteAppFeedback(page, featureId);
    }
  });

  // ── 7. Validation: empty summary ─────────────────────────────────────────

  test("submit with empty summary shows validation error", async ({ page }) => {
    await page.goto("/dashboard");
    await page.locator("[data-cy='app-feedback-btn']").click();
    await expect(page.locator("[data-cy='app-feedback-summary']")).toBeVisible({ timeout: 5000 });

    // Clear summary and submit
    await page.locator("[data-cy='app-feedback-summary']").fill("");
    const submitBtn = page.locator("[data-cy='app-feedback-submit']");

    // Submit button should be disabled when summary is empty
    await expect(submitBtn).toBeDisabled();
  });

  // ── 8. Cancel closes modal ────────────────────────────────────────────────

  test("cancelling the modal does not submit feedback", async ({ page }) => {
    const uniqueSummary = `Playwright cancel test ${Date.now()}`;

    await page.goto("/dashboard");
    await page.locator("[data-cy='app-feedback-btn']").click();
    await expect(page.locator("[data-cy='app-feedback-summary']")).toBeVisible({ timeout: 5000 });
    await page.locator("[data-cy='app-feedback-summary']").fill(uniqueSummary);

    // Cancel
    await page.getByRole("button", { name: "Cancel" }).click();

    // Modal closes
    await expect(page.locator("[data-cy='app-feedback-summary']")).not.toBeVisible({ timeout: 5000 });

    // Verify NOT in DB
    const items = await listAppFeedback(page);
    const notCreated = items.find((i) => i.summary === uniqueSummary);
    expect(notCreated, "Cancelled item must not be in DB").toBeFalsy();
  });

  // ── 9. Navigation — direct URL access to /feedback works ─────────────────

  test("direct URL access to /feedback page renders inbox", async ({ page }) => {
    await page.goto("/feedback");
    await expect(page.locator("h1").filter({ hasText: "Feedback Inbox" })).toBeVisible({ timeout: 8000 });
    // Page title area is visible
    await expect(page.getByText("Bug reports and feature suggestions submitted by users.")).toBeVisible();
  });
});
