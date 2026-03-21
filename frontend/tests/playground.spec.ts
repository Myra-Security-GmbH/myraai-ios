import { test, expect, Page } from "@playwright/test";

// Uses tenant=myratest / gateway=prod / model=ollama/qwen2.5:3b
// (locally-pulled Ollama model — no API key required)

const TENANT_SLUG = "myratest";
const GATEWAY_SLUG = "prod";
const MODEL = "ollama/qwen2.5:3b"; // full model ID as stored in catalog
const PROMPT = "Reply with exactly one word: hello";

async function setup(page: Page) {
  await page.goto("/playground");
  await page.waitForLoadState("networkidle");

  // Tenant select — label text is "Tenant", options are tenant slugs
  const tenantLabel = page.locator("label").filter({ hasText: /^Tenant$/ });
  const tenantSelect = tenantLabel.locator("xpath=following-sibling::select");
  await tenantSelect.selectOption(TENANT_SLUG);
  await page.waitForTimeout(600);

  // Gateway select — label text is "Gateway", options are gateway slugs
  const gatewayLabel = page.locator("label").filter({ hasText: /^Gateway$/ });
  const gatewaySelect = gatewayLabel.locator("xpath=following-sibling::select");
  await gatewaySelect.selectOption(GATEWAY_SLUG);
  await page.waitForTimeout(600);
}

async function pickModel(page: Page) {
  // ModelPicker trigger button has aria-haspopup="listbox"
  const trigger = page.locator("[aria-haspopup='listbox']").first();
  await trigger.click();

  // Type in search box (search by the bare name portion)
  await page.getByLabel("Search models").fill("qwen2.5:3b");
  await page.waitForTimeout(300);

  // Click matching option — text is the full model ID "ollama/qwen2.5:3b"
  await page.getByRole("option", { name: MODEL }).first().click();
  await page.waitForTimeout(200);
}

// ─────────────────────────────────────────────────────────────────────────────

test.describe("Playground — Ollama e2e", () => {

  test("loads playground page with heading", async ({ page }) => {
    await page.goto("/playground");
    await expect(page.getByRole("heading", { name: /playground/i })).toBeVisible();
  });

  test("tenant and gateway selects populate model catalog", async ({ page }) => {
    await setup(page);
    await expect(page.getByText(/in catalog/i)).toBeVisible({ timeout: 8000 });
  });

  test("token is issued after selecting gateway", async ({ page }) => {
    await setup(page);
    await expect(page.getByText(/token active/i)).toBeVisible({ timeout: 8000 });
  });

  test("sends message to ollama/qwen2.5:3b and receives a response", async ({ page }) => {
    await setup(page);
    await pickModel(page);

    // Verify model is selected
    const trigger = page.locator("[aria-haspopup='listbox']").first();
    await expect(trigger).toContainText(MODEL);

    // Type message
    await page.getByLabel("User message").fill(PROMPT);

    // Run
    await page.getByRole("button", { name: "Run" }).click();

    const response = page.getByLabel("Response").first();

    // First confirm request was dispatched ("Running…" must appear)
    await expect(response).toContainText("Running…", { timeout: 10000 });

    // Then wait for it to disappear — request completed
    await expect(response).not.toContainText("Running…", { timeout: 30000 });

    // Should not show an error
    await expect(response).not.toContainText(/server error|internal.*error/i);

    // Should have actual response text
    const text = (await response.innerText()).trim();
    expect(text.length).toBeGreaterThan(0);
  });

});
