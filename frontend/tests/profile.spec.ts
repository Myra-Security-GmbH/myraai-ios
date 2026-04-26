import { test, expect } from "./base";

const ADMIN_BASE = (process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173") + "/admin/v1";

async function apiGetMyTokens(page: import("@playwright/test").Page) {
  const r = await page.context().request.get(`${ADMIN_BASE}/me/tokens`);
  if (!r.ok()) return [];
  return r.json() as Promise<Array<{ id: string; label: string | null; budget_usd: number | null }>>;
}

async function apiDeleteToken(page: import("@playwright/test").Page, id: string) {
  await page.context().request.delete(`${ADMIN_BASE}/me/tokens/${id}`).catch(() => {});
}

async function openTokenModal(page: import("@playwright/test").Page) {
  await page.getByRole("button", { name: /\+ New Token/i }).click();
  await expect(page.getByRole("heading", { name: "New Token" })).toBeVisible({ timeout: 5000 });
}

// ---------------------------------------------------------------------------
// Profile — My Tokens
// ---------------------------------------------------------------------------

test.describe("Profile — My Tokens", () => {
  test("shows page title", async ({ page }) => {
    await page.goto("/profile");
    await expect(page.getByRole("heading", { name: "My Tokens" })).toBeVisible();
  });

  test("shows Profile card with email and role badge", async ({ page }) => {
    await page.goto("/profile");
    await page.waitForLoadState("networkidle");

    // Fetch the logged-in user's email from the API
    const r = await page.context().request.get(`${ADMIN_BASE}/me`);
    const me = r.ok() ? (await r.json() as { email: string }) : null;
    if (me?.email) {
      await expect(page.getByText(me.email)).toBeVisible();
    }

    await expect(page.getByRole("heading", { name: "Profile" })).toBeVisible();
    await expect(page.getByText("Email")).toBeVisible();
    await expect(page.getByText("Role")).toBeVisible();
  });

  test("Tokens card and New Token button visible for admin", async ({ page }) => {
    await page.goto("/profile");
    // Use exact match to avoid matching "My Tokens" heading
    await expect(page.getByRole("heading", { name: "Tokens", exact: true })).toBeVisible();
    await expect(page.getByRole("button", { name: /\+ New Token/i })).toBeVisible();
  });

  test("New Token modal opens with all fields", async ({ page }) => {
    await page.goto("/profile");
    await page.waitForLoadState("networkidle");
    await openTokenModal(page);
    await expect(page.getByText("Gateway *")).toBeVisible();
    await expect(page.getByPlaceholder("dev laptop")).toBeVisible();
    await expect(page.getByText("Expires At")).toBeVisible();
    await expect(page.getByPlaceholder("unlimited")).toBeVisible();
    await expect(page.getByText(/Rate limit/i)).toBeVisible();
  });

  test("modal closes on Cancel", async ({ page }) => {
    await page.goto("/profile");
    await page.waitForLoadState("networkidle");
    await openTokenModal(page);
    await page.getByRole("button", { name: /Cancel/i }).click();
    await expect(page.getByRole("heading", { name: "New Token" })).not.toBeVisible();
  });

  test("creates a token with a label, reveals it once, then appears in table", async ({ page, workerSuffix }) => {
    const label = `e2e-profile-${workerSuffix}-${Date.now()}`;
    let createdId: string | null = null;
    try {
      await page.goto("/profile");
      await page.waitForLoadState("networkidle");
      await openTokenModal(page);

      // Fill label via placeholder selector (avoids ambiguity with table th "Label")
      await page.getByPlaceholder("dev laptop").fill(label);
      await page.getByRole("button", { name: "Create Token" }).click();

      // Reveal modal must show the raw token string exactly once
      await expect(page.getByText(/^myra_/)).toBeVisible({ timeout: 10000 });
      await expect(page.getByText(/will not be shown again/i)).toBeVisible();
      await page.getByRole("button", { name: "Done" }).click();
      await expect(page.getByText(/^myra_/)).not.toBeVisible();

      // Token appears in the table
      await expect(page.getByRole("cell", { name: label })).toBeVisible();

      // No error banner
      await expect(page.getByText(/failed/i).first()).not.toBeVisible();

      const tokens = await apiGetMyTokens(page);
      createdId = tokens.find((t) => t.label === label)?.id ?? null;
    } finally {
      if (createdId) await apiDeleteToken(page, createdId);
    }
  });

  test("creates token with budget and verifies it in the table", async ({ page, workerSuffix }) => {
    const label = `e2e-budget-${workerSuffix}-${Date.now()}`;
    let createdId: string | null = null;
    try {
      await page.goto("/profile");
      await page.waitForLoadState("networkidle");
      await openTokenModal(page);

      await page.getByPlaceholder("dev laptop").fill(label);
      await page.getByPlaceholder("unlimited").fill("5.00");

      await page.getByRole("button", { name: "Create Token" }).click();
      await expect(page.getByText(/^myra_/)).toBeVisible({ timeout: 10000 });
      await page.getByRole("button", { name: "Done" }).click();

      // Token row shows budget
      await expect(page.getByRole("cell", { name: label })).toBeVisible();
      await expect(page.getByRole("cell", { name: "$5" })).toBeVisible();

      const tokens = await apiGetMyTokens(page);
      const saved = tokens.find((t) => t.label === label);
      expect(saved?.budget_usd).toBe(5);
      createdId = saved?.id ?? null;
    } finally {
      if (createdId) await apiDeleteToken(page, createdId);
    }
  });

  test("revokes a token and it disappears from the table", async ({ page, workerSuffix }) => {
    const label = `e2e-revoke-${workerSuffix}-${Date.now()}`;
    let createdId: string | null = null;
    try {
      // Create via UI
      await page.goto("/profile");
      await page.waitForLoadState("networkidle");
      await openTokenModal(page);
      await page.getByPlaceholder("dev laptop").fill(label);
      await page.getByRole("button", { name: "Create Token" }).click();
      await expect(page.getByText(/^myra_/)).toBeVisible({ timeout: 10000 });
      await page.getByRole("button", { name: "Done" }).click();
      await expect(page.getByRole("cell", { name: label })).toBeVisible();

      const tokens = await apiGetMyTokens(page);
      createdId = tokens.find((t) => t.label === label)?.id ?? null;

      // Revoke
      page.on("dialog", (d) => d.accept());
      await page.getByRole("cell", { name: label })
        .locator("xpath=ancestor::tr//button[contains(text(),'Revoke')]").click();

      await expect(page.getByRole("cell", { name: label })).not.toBeVisible({ timeout: 5000 });
      createdId = null; // already revoked
    } finally {
      if (createdId) await apiDeleteToken(page, createdId);
    }
  });

  test("cancelling revoke dialog keeps the token in the table", async ({ page, workerSuffix }) => {
    const label = `e2e-norevoke-${workerSuffix}-${Date.now()}`;
    let createdId: string | null = null;
    try {
      await page.goto("/profile");
      await page.waitForLoadState("networkidle");
      await openTokenModal(page);
      await page.getByPlaceholder("dev laptop").fill(label);
      await page.getByRole("button", { name: "Create Token" }).click();
      await expect(page.getByText(/^myra_/)).toBeVisible({ timeout: 10000 });
      await page.getByRole("button", { name: "Done" }).click();
      await expect(page.getByRole("cell", { name: label })).toBeVisible();

      const tokens = await apiGetMyTokens(page);
      createdId = tokens.find((t) => t.label === label)?.id ?? null;

      // Dismiss the confirm dialog
      page.once("dialog", (d) => d.dismiss());
      await page.getByRole("cell", { name: label })
        .locator("xpath=ancestor::tr//button[contains(text(),'Revoke')]").click();

      // Token must still be visible
      await expect(page.getByRole("cell", { name: label })).toBeVisible();
    } finally {
      if (createdId) await apiDeleteToken(page, createdId);
    }
  });

  test("direct URL /profile loads the page", async ({ page }) => {
    await page.goto("/profile");
    await expect(page.getByRole("heading", { name: "My Tokens" })).toBeVisible();
  });
});
