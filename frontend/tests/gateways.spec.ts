import { test, expect, Page } from "@playwright/test";

// Helper: get tenant buttons inside the "Select Tenant" card
function getTenantButtons(page: Page) {
  return page.getByRole("heading", { name: "Select Tenant" })
    .locator("xpath=ancestor::*[2]/div[2]/button");
}

// Helper: select a tenant that has at least one gateway (tries each tenant in order)
async function selectTenantWithGateway(page: Page): Promise<boolean> {
  await page.goto("/gateways");
  await page.waitForTimeout(500);
  const btns = getTenantButtons(page);
  const count = await btns.count();
  if (count === 0) return false;
  for (let i = 0; i < count; i++) {
    await btns.nth(i).click();
    await page.waitForTimeout(600);
    const manageBtn = page.getByRole("button", { name: /Manage →/i }).first();
    if (await manageBtn.isVisible()) return true;
  }
  return false;
}

async function selectFirstTenant(page: Page): Promise<boolean> {
  await page.goto("/gateways");
  await page.waitForTimeout(500);
  const btns = getTenantButtons(page);
  if (await btns.count() === 0) return false;
  await btns.first().click();
  await page.waitForTimeout(600);
  return true;
}

// Helper: navigate into first available gateway's detail
async function openFirstGateway(page: Page): Promise<boolean> {
  const ok = await selectTenantWithGateway(page);
  if (!ok) return false;
  const manageBtn = page.getByRole("button", { name: /Manage →/i }).first();
  await manageBtn.click();
  await page.waitForTimeout(400);
  return true;
}

test.describe("Gateways page", () => {
  test("shows page heading and Select Tenant section", async ({ page }) => {
    await page.goto("/gateways");
    await expect(page.getByRole("heading", { name: "Gateways" })).toBeVisible();
    await expect(page.getByText("Select Tenant")).toBeVisible();
  });

  test("selecting a tenant shows its gateways or empty state", async ({ page }) => {
    const ok = await selectFirstTenant(page);
    if (!ok) { test.skip(); return; }
    const hasTable = await page.locator("table").isVisible().catch(() => false);
    const hasEmpty = await page.getByText(/No gateways/).isVisible().catch(() => false);
    const hasNew = await page.getByRole("button", { name: /New Gateway/i }).isVisible().catch(() => false);
    expect(hasTable || hasEmpty || hasNew).toBe(true);
  });

  test("New Gateway modal opens and has all config fields", async ({ page }) => {
    const ok = await selectFirstTenant(page);
    if (!ok) { test.skip(); return; }
    const newBtn = page.getByRole("button", { name: /New Gateway/i });
    if (!await newBtn.isVisible()) { test.skip(); return; }
    await newBtn.click();
    await expect(page.getByRole("heading", { name: /New Gateway/i })).toBeVisible();
    await expect(page.getByLabel("Slug *")).toBeVisible();
    await expect(page.getByLabel("Budget (USD)")).toBeVisible();
    await expect(page.getByLabel("Cache TTL (s)")).toBeVisible();
    await expect(page.getByLabel("Retry Count")).toBeVisible();
    await expect(page.getByText(/Require auth token/i)).toBeVisible();
    await expect(page.getByText(/Guardrails \(/i).first()).toBeVisible();
  });

  test("gateway detail shows all sections", async ({ page }) => {
    const ok = await openFirstGateway(page);
    if (!ok) { test.skip(); return; }
    await expect(page.getByRole("heading", { name: "Provider Keys" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Auth Tokens" })).toBeVisible();
    await expect(page.getByRole("heading", { name: "Routing Rules" })).toBeVisible();
  });

  test("gateway detail shows config stat cards", async ({ page }) => {
    const ok = await openFirstGateway(page);
    if (!ok) { test.skip(); return; }
    await expect(page.getByText("Budget").first()).toBeVisible();
    await expect(page.getByText("Cache TTL").first()).toBeVisible();
    await expect(page.getByText("Auth").first()).toBeVisible();
  });

  test("Edit gateway config modal has all fields", async ({ page }) => {
    const ok = await openFirstGateway(page);
    if (!ok) { test.skip(); return; }
    await page.getByRole("button", { name: /^Edit$/i }).first().click();
    await expect(page.getByRole("heading", { name: /Edit Gateway/i })).toBeVisible();
    await expect(page.getByLabel("Budget (USD)")).toBeVisible();
    await expect(page.getByLabel("Cache TTL (s)")).toBeVisible();
    await expect(page.getByLabel("Retry Count")).toBeVisible();
    await expect(page.getByLabel("Timeout (ms)")).toBeVisible();
    await expect(page.getByText(/Require auth token/i)).toBeVisible();
  });

  test("Add/Rotate provider key modal", async ({ page }) => {
    const ok = await openFirstGateway(page);
    if (!ok) { test.skip(); return; }
    await page.getByRole("button", { name: /Add \/ Rotate/i }).click();
    await expect(page.getByRole("heading", { name: "Add / Rotate Provider Key" })).toBeVisible();
    await expect(page.getByLabel("Provider")).toBeVisible();
    await expect(page.getByLabel("Alias")).toBeVisible();
    await expect(page.getByLabel("API Key *")).toBeVisible();
  });

  test("Generate token modal shows expiry, rate limit, and spend cap fields", async ({ page }) => {
    const ok = await openFirstGateway(page);
    if (!ok) { test.skip(); return; }
    await page.getByRole("button", { name: /\+ Generate/i }).click();
    await expect(page.getByRole("heading", { name: /Create Auth Token/i })).toBeVisible();
    await expect(page.getByLabel(/Expires At/i)).toBeVisible();
    await expect(page.getByLabel(/Spend cap/i)).toBeVisible();
    await expect(page.getByLabel(/Rate limit/i)).toBeVisible();
    await expect(page.getByRole("button", { name: /Generate Token/i })).toBeVisible();
  });

  test("Edit gateway modal has webhook configuration section", async ({ page }) => {
    const ok = await openFirstGateway(page);
    if (!ok) { test.skip(); return; }
    await page.getByRole("button", { name: /^Edit$/i }).first().click();
    await expect(page.getByRole("heading", { name: /Edit Gateway/i })).toBeVisible();
    await expect(page.getByText(/Webhook/i).first()).toBeVisible();
    await expect(page.getByPlaceholder(/hooks.example.com/i)).toBeVisible();
  });

  test("gateway detail token table has label and rate limit columns", async ({ page }) => {
    const ok = await openFirstGateway(page);
    if (!ok) { test.skip(); return; }
    // Token table headers
    const tokenSection = page.getByRole("heading", { name: "Auth Tokens" }).locator("xpath=ancestor::*[2]");
    const hasTokens = await tokenSection.locator("table").isVisible().catch(() => false);
    if (!hasTokens) { test.skip(); return; }
    await expect(tokenSection.getByRole("columnheader", { name: /Label/i })).toBeVisible();
    await expect(tokenSection.getByRole("columnheader", { name: /Rate Limit/i })).toBeVisible();
    await expect(tokenSection.getByRole("columnheader", { name: /Spend Cap/i })).toBeVisible();
  });

  test("gateway detail shows Webhook stat card", async ({ page }) => {
    const ok = await openFirstGateway(page);
    if (!ok) { test.skip(); return; }
    await expect(page.getByText("Webhook").first()).toBeVisible();
  });

  test("New routing rule modal has condition/action editors", async ({ page }) => {
    const ok = await openFirstGateway(page);
    if (!ok) { test.skip(); return; }
    await page.getByRole("button", { name: /\+ New Rule/i }).click();
    await expect(page.getByRole("heading", { name: "New Routing Rule" })).toBeVisible();
    await expect(page.getByText(/Conditions/i).first()).toBeVisible();
    await expect(page.getByText(/Route to/i).first()).toBeVisible();
    await expect(page.getByText(/Fallbacks/i).first()).toBeVisible();
    await expect(page.getByLabel("Priority")).toBeVisible();
  });

  test("routing rule modal can add a condition", async ({ page }) => {
    const ok = await openFirstGateway(page);
    if (!ok) { test.skip(); return; }
    await page.getByRole("button", { name: /\+ New Rule/i }).click();
    const addCondBtn = page.getByRole("button", { name: /^\+ Add$/i }).first();
    await addCondBtn.click();
    // A new row with selects for field/op and an input for value should appear
    await expect(page.locator("select", { hasText: "model" }).first()).toBeVisible();
  });

  test("back button from gateway detail returns to list", async ({ page }) => {
    const ok = await openFirstGateway(page);
    if (!ok) { test.skip(); return; }
    await page.getByText(/← Back/i).click();
    await expect(page.getByText("Select Tenant")).toBeVisible();
  });

  test("modal closes on Cancel", async ({ page }) => {
    const ok = await selectFirstTenant(page);
    if (!ok) { test.skip(); return; }
    const newBtn = page.getByRole("button", { name: /New Gateway/i });
    if (!await newBtn.isVisible()) { test.skip(); return; }
    await newBtn.click();
    await page.getByRole("button", { name: /Cancel/i }).click();
    await expect(page.getByRole("heading", { name: /New Gateway/i })).not.toBeVisible();
  });
});
