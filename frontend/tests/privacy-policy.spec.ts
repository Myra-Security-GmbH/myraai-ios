/**
 * privacy-policy.spec.ts — E2E tests for the public /privacy page.
 *
 * The privacy policy URL must be reachable WITHOUT authentication (Google
 * Play Store and Apple App Store reviewers will not log in), and must
 * disclose the items required by Play Store Data Safety and the corporate
 * privacy policy.
 *
 * Each test creates a fresh, unauthenticated browser context — the
 * playwright config's default storageState (signed-in admin) is bypassed
 * deliberately.
 */

import { test, expect } from "@playwright/test";

test.describe("Privacy policy — public page", () => {
  test("is reachable without authentication", async ({ browser, baseURL }) => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    try {
      const resp = await page.goto(`${baseURL}/privacy`);
      expect(resp?.status(), "expected 200 OK").toBe(200);
      // Must NOT have been redirected to /login.
      expect(page.url(), "should not redirect to login").not.toContain("/login");
      await expect(page.getByRole("heading", { name: /MYRA AI.*Privacy Policy/i, level: 1 }))
        .toBeVisible();
    } finally {
      await ctx.close();
    }
  });

  test("discloses every Play Store-required data category and recipient", async ({ browser, baseURL }) => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    try {
      await page.goto(`${baseURL}/privacy`);
      const body = page.locator("body");

      // Identity & contact (developer name + privacy email)
      await expect(body).toContainText("Myra Security GmbH");
      await expect(body).toContainText("info@myrasecurity.com");

      // Data categories — explicit
      await expect(body).toContainText(/account/i);
      await expect(body).toContainText(/conversation|prompts|messages/i);
      await expect(body).toContainText(/push notification token|Apple Push Notification|Firebase Cloud Messaging/i);
      await expect(body).toContainText(/device/i);

      // Third-party recipients — model providers must be named
      await expect(body).toContainText(/Anthropic/);
      await expect(body).toContainText(/OpenAI/);
      await expect(body).toContainText(/Google/);
      await expect(body).toContainText(/Mistral/);

      // Push delivery providers
      await expect(body).toContainText(/Apple Push Notification/i);
      await expect(body).toContainText(/Firebase Cloud Messaging/i);

      // International transfers + erasure path + delete-and-restore semantic
      await expect(body).toContainText(/Standard Contractual Clauses|Data Privacy Framework/);
      await expect(body).toContainText(/30 days/);
      await expect(body).toContainText(/Delete Account/i);
      await expect(body).toContainText(/Permanent erasure|Art\. 17/);
      // Account-delete must be advertised as admin-restorable, not self-restorable
      await expect(body).toContainText(/cannot reactivate the account yourself|administrator can restore/i);

      // Generative AI disclosure + reporting affordance
      await expect(body).toContainText(/generative AI|inaccurate/i);
      await expect(body).toContainText(/report/i);

      // Minimum age (Play target audience + TX/UT age verification scoping)
      await expect(body).toContainText(/18 and over|aged 18/i);

      // Security practice
      await expect(body).toContainText(/TLS/i);

      // No error/empty states
      await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
      await expect(page.getByText(/not found/i)).not.toBeVisible();
    } finally {
      await ctx.close();
    }
  });

  test("links back to the corporate privacy policy and to sign-in", async ({ browser, baseURL }) => {
    const ctx = await browser.newContext();
    const page = await ctx.newPage();
    try {
      await page.goto(`${baseURL}/privacy`);
      const corporateLinks = page.getByRole("link", { name: /corporate privacy policy/i });
      // Page links to the corporate policy in both intro and footer.
      await expect(corporateLinks).toHaveCount(2);
      for (const href of await corporateLinks.evaluateAll(els => els.map(e => (e as HTMLAnchorElement).href))) {
        expect(href).toBe("https://www.myrasecurity.com/en/privacy-policy/");
      }
      await expect(page.getByRole("link", { name: /back to sign in/i }))
        .toHaveAttribute("href", "/login");
    } finally {
      await ctx.close();
    }
  });
});
