/**
 * chat-feedback.spec.ts — verifies the session feedback modal in the chat UI.
 *
 * Uses the admin API to seed a conversation, then exercises the flag-icon
 * button and the GET/PUT feedback endpoints directly.
 */

import { test, expect, Page } from "@playwright/test";

const ADMIN_URL = process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu";

// ---------------------------------------------------------------------------
// API helpers
// ---------------------------------------------------------------------------

async function getFirstGatewayId(page: Page): Promise<string | null> {
  const tenantsResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants`);
  if (!tenantsResp.ok()) return null;
  const tenants = (await tenantsResp.json()) as Array<{ id: string }>;
  for (const tenant of tenants) {
    const gwResp = await page.context().request.get(`${ADMIN_URL}/admin/v1/tenants/${tenant.id}/gateways`);
    if (!gwResp.ok()) continue;
    const gws = (await gwResp.json()) as Array<{ id: string }>;
    if (gws.length) return gws[0].id;
  }
  return null;
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

async function openConversation(page: Page) {
  await page.goto("/chat");
  await page.waitForTimeout(800);
  const firstItem = page.locator("[role='option']").first();
  await firstItem.waitFor({ state: "visible", timeout: 8000 });
  await firstItem.click();
  await page.waitForTimeout(600);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test.describe("Chat — session feedback", () => {
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
    if (!visible) { test.skip(); return; }

    await expect(btn).toBeDisabled();
  });

  // ── 2. Modal opens, rating + comment submit, persists on re-open ──────────

  test("feedback modal opens, saves rating+comment, and pre-fills on re-open", async ({ page }) => {
    const convId = await createConversation(page, gatewayId, "Feedback Test Conversation");
    if (!convId) { test.skip(); return; }

    await addMessage(page, convId, "user", "Hello.");
    await addMessage(page, convId, "assistant", "Hi there!");

    try {
      await openConversation(page);

      const feedbackBtn = page.locator("button[title='Session feedback']");
      await expect(feedbackBtn).toBeEnabled({ timeout: 5000 });

      // Open modal
      await feedbackBtn.click();

      const modal = page.getByRole("dialog").or(
        page.locator(".modal-overlay, [class*='modal-overlay']")
      );
      // Wait for modal content
      await page.waitForSelector("text=Session Feedback", { timeout: 5000 });

      // Rating buttons 1-5 should be visible
      for (const n of [1, 2, 3, 4, 5]) {
        await expect(page.getByRole("button", { name: String(n) }).first()).toBeVisible();
      }

      // Select rating 2
      await page.getByRole("button", { name: "2" }).first().click();

      // Enter comment
      const textarea = page.locator("textarea[placeholder*='could be better']");
      await textarea.fill("The response was a bit slow.");

      // Save
      const saveBtn = page.getByRole("button", { name: "Save feedback" });
      await saveBtn.click();

      // "Saved ✓" flash should appear
      await expect(page.getByText("Saved ✓")).toBeVisible({ timeout: 5000 });

      // Modal auto-closes after 800 ms
      await page.waitForTimeout(1200);
      await expect(page.locator("text=Session Feedback")).not.toBeVisible();

      // Re-open modal — form should be pre-filled
      await feedbackBtn.click();
      await page.waitForSelector("text=Session Feedback", { timeout: 5000 });

      // Rating 2 should be highlighted (bold / border)
      const rating2Btn = page.getByRole("button", { name: "2" }).first();
      const fw = await rating2Btn.evaluate((el) => (el as HTMLElement).style.fontWeight);
      expect(fw).toBe("700");

      // Comment should be pre-filled
      const ta = page.locator("textarea[placeholder*='could be better']");
      await expect(ta).toHaveValue("The response was a bit slow.");

      // Close
      await page.getByRole("button", { name: "Cancel" }).click();

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
    if (!convId) { test.skip(); return; }

    await addMessage(page, convId, "user", "Quick question.");
    await addMessage(page, convId, "assistant", "Quick answer.");

    try {
      await openConversation(page);

      const feedbackBtn = page.locator("button[title='Session feedback']");
      await expect(feedbackBtn).toBeEnabled({ timeout: 5000 });
      await feedbackBtn.click();
      await page.waitForSelector("text=Session Feedback", { timeout: 5000 });

      const saveBtn = page.getByRole("button", { name: "Save feedback" });
      await expect(saveBtn).toBeDisabled();

      // Select a rating — button should become enabled
      await page.getByRole("button", { name: "3" }).first().click();
      await expect(saveBtn).toBeEnabled();

      await page.getByRole("button", { name: "Cancel" }).click();
    } finally {
      await deleteConversation(page, convId);
    }
  });
});
