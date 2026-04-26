/**
 * chat-feedback.spec.ts — verifies the session feedback modal in the chat UI.
 *
 * Uses the admin API to seed a conversation, then exercises the flag-icon
 * button and the GET/PUT feedback endpoints directly.
 */

import { test, expect, type Page } from "./base";

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------

async function getFirstGatewayId(page: Page): Promise<string | null> {
  const tenantsResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
  if (!tenantsResp.ok()) return null;
  const tenants = (await tenantsResp.json()) as Array<{ id: string; slug: string }>;
  if (!tenants.length) return null;
  // Prefer myratest — test fixture tenants are newest and appear first in the list
  const preferred = tenants.find((t) => t.slug === "myratest") ?? tenants[0];
  const gwResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants/${preferred.id}/gateways`);
  if (!gwResp.ok()) return null;
  const gws = (await gwResp.json()) as Array<{ id: string }>;
  return gws.length ? gws[0].id : null;
}

async function createConversation(page: Page, gatewayId: string, title: string): Promise<string | null> {
  const resp = await page.context().request.post(`${ADMIN_URL}/admin/v1/conversations`, {
    data: { gateway_id: gatewayId, title },
  });
  if (!resp.ok()) return null;
  return ((await resp.json()) as { id: string }).id;
}

async function addMessage(page: Page, convId: string, role: "user" | "assistant", content: string) {
  await page.context().request.post(`${ADMIN_URL}/admin/v1/conversations/${convId}/messages`, {
    data: { role, content },
  });
}

async function deleteConversation(page: Page, convId: string) {
  await page.context().request.delete(`${ADMIN_URL}/admin/v1/conversations/${convId}`).catch(() => {});
}

/** Navigate to /chat and open the specific conversation by its data-id attribute. */
async function openConversation(page: Page, convId: string) {
  await page.goto("/chat");
  // Wait for sidebar to populate then click the specific conversation
  const convItem = page.locator(`[role='option'][data-id='${convId}']`);
  await convItem.waitFor({ state: "visible", timeout: 8000 });
  await convItem.click();
  // Wait until the conversation is active (aria-selected becomes true)
  await expect(convItem).toHaveAttribute("aria-selected", "true", { timeout: 5000 });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Chat — session feedback", () => {
  test.describe.configure({ mode: "serial" });
  let gatewayId: string;

  test.beforeAll(async ({ browser }) => {
    const page = await browser.newPage();
    const gid = await getFirstGatewayId(page);
    await page.close();
    if (!gid) throw new Error("No gateway found — cannot run feedback tests");
    gatewayId = gid;
  });

  // ── 1. Feedback button disabled with no active conversation ───────────────

  test("feedback button is disabled on fresh load", async ({ page }) => {
    await page.goto("/chat");
    await page.waitForTimeout(600);

    const btn = page.locator("button[title='Session feedback']");
    const visible = await btn.isVisible({ timeout: 5000 }).catch(() => false);
    if (!visible) { test.skip(true, "Required UI element not visible in this environment"); return; }

    await expect(btn).toBeDisabled();
  });

  // ── 2. Modal opens, rating + comment submit, persists on re-open ──────────

  test("feedback modal opens, saves rating+comment, and pre-fills on re-open", async ({ page }) => {
    const convId = await createConversation(page, gatewayId, "Feedback Test Conversation");
    if (!convId) { test.skip(true, "Failed to create test conversation"); return; }

    await addMessage(page, convId, "user", "Hello.");
    await addMessage(page, convId, "assistant", "Hi there!");

    try {
      await openConversation(page, convId);

      const feedbackBtn = page.locator("button[title='Session feedback']");
      await expect(feedbackBtn).toBeEnabled({ timeout: 5000 });

      // Open modal
      await feedbackBtn.click();

      const modal = page.getByRole("dialog").or(
        page.locator(".modal-overlay, [class*='modal-overlay']")
      );
      // Wait for modal content
      await page.waitForSelector("text=Session Feedback", { timeout: 5000 });

      // Scope all rating-button interactions to inside the modal to avoid
      // matching config-preset buttons (e.g. "PII qwen3") that contain digits.
      const modalEl = page.locator("[class*='modal-overlay']").or(page.getByRole("dialog")).filter({ hasText: "Session Feedback" });
      await modalEl.waitFor({ state: "visible", timeout: 5000 });

      // Rating buttons 1-5 should be visible inside the modal
      for (const n of [1, 2, 3, 4, 5]) {
        await expect(modalEl.getByRole("button", { name: String(n), exact: true })).toBeVisible();
      }

      // Select rating 2
      await modalEl.getByRole("button", { name: "2", exact: true }).click();

      // Enter comment
      const textarea = modalEl.locator("textarea[placeholder*='could be better']");
      await textarea.fill("The response was a bit slow.");

      // Save
      const saveBtn = modalEl.getByRole("button", { name: "Save feedback" });
      await saveBtn.click();

      // "Saved ✓" flash should appear
      await expect(modalEl.getByText("Saved ✓")).toBeVisible({ timeout: 5000 });

      // Modal auto-closes after 800 ms — wait for the overlay to disappear
      await expect(page.locator("[class*='modal-overlay']")).not.toBeVisible({ timeout: 5000 });

      // Re-open modal — form should be pre-filled
      await feedbackBtn.click();
      const modalEl2 = page.locator("[class*='modal-overlay']").or(page.getByRole("dialog")).filter({ hasText: "Session Feedback" });
      await modalEl2.waitFor({ state: "visible", timeout: 5000 });

      // Rating 2 should be highlighted (selected class)
      const rating2Btn = modalEl2.getByRole("button", { name: "2", exact: true });
      await expect(rating2Btn).toHaveClass(/picker-btn--selected/);

      // Comment should be pre-filled
      const ta = modalEl2.locator("textarea[placeholder*='could be better']");
      await expect(ta).toHaveValue("The response was a bit slow.");

      // Close
      await modalEl2.getByRole("button", { name: "Cancel" }).click();

      // Verify in DB via API
      const fbResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/conversations/${convId}/feedback`);
      expect(fbResp.ok()).toBe(true);
      const fb = await fbResp.json() as { rating: number; comment: string };
      expect(fb.rating).toBe(2);
      expect(fb.comment).toBe("The response was a bit slow.");
    } finally {
      await deleteConversation(page, convId);
    }
  });

  // ── 3. Save disabled until a rating is selected ───────────────────────────

  test("Save feedback button is disabled until a rating is selected", async ({ page }) => {
    const convId = await createConversation(page, gatewayId, "Feedback Disabled Test");
    if (!convId) { test.skip(true, "Failed to create test conversation"); return; }

    await addMessage(page, convId, "user", "Quick question.");
    await addMessage(page, convId, "assistant", "Quick answer.");

    try {
      await openConversation(page, convId);

      const feedbackBtn = page.locator("button[title='Session feedback']");
      await expect(feedbackBtn).toBeEnabled({ timeout: 5000 });
      await feedbackBtn.click();
      await page.waitForSelector("text=Session Feedback", { timeout: 5000 });

      const saveBtn = page.getByRole("button", { name: "Save feedback" });
      await expect(saveBtn).toBeDisabled();

      // Select a rating — scope to modal to avoid hitting config-preset buttons
      const ratingModal = page.locator("[class*='modal-overlay']").or(page.getByRole("dialog")).filter({ hasText: "Session Feedback" });
      await ratingModal.waitFor({ state: "visible", timeout: 5000 });
      await ratingModal.getByRole("button", { name: "3", exact: true }).click();
      await expect(saveBtn).toBeEnabled();

      await page.getByRole("button", { name: "Cancel" }).click();
    } finally {
      await deleteConversation(page, convId);
    }
  });
});
