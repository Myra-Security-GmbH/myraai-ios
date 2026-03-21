import { test, expect, Page } from "@playwright/test";

// Uses tenant=myratest / gateway=prod / model=ollama/qwen2.5:3b
// (locally-pulled Ollama model — no API key required)

const TENANT_SLUG = "myratest";
const GATEWAY_SLUG = "prod";
const MODEL = "ollama/qwen2.5:3b"; // full model ID as stored in catalog
const PROMPT = "Reply with exactly one word: hello";

const WEB_SEARCH_MODEL = "ollama/gpt-oss:120b";
const WEB_SEARCH_20B_MODEL = "ollama/gpt-oss:20b";
const WEB_SEARCH_PROMPT = 'do web search for "myra security gmbh", summarize findings';
const WEATHER_PROMPT = 'do web search for "current weather munich"';

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

async function pickModelByName(page: Page, model: string) {
  const bare = model.replace(/^[^/]+\//, ""); // e.g. "gpt-oss:120b"
  const trigger = page.locator("[aria-haspopup='listbox']").first();
  await trigger.click();
  await page.getByLabel("Search models").fill(bare);
  await page.waitForTimeout(300);
  await page.getByRole("option", { name: model }).first().click();
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

// ─────────────────────────────────────────────────────────────────────────────

test.describe("Playground — Web Search e2e", () => {

  test("ollama/gpt-oss:20b web search returns non-empty streamed content (no-content regression)", async ({ page }) => {
    await setup(page);
    await pickModelByName(page, WEB_SEARCH_20B_MODEL);

    const trigger = page.locator("[aria-haspopup='listbox']").first();
    await expect(trigger).toContainText(WEB_SEARCH_20B_MODEL);

    const wsBtn = page.getByRole("button", { name: /web search/i });
    await wsBtn.click();
    await expect(wsBtn).toContainText("Web Search ON");

    await page.getByLabel("User message").fill("What is myra security?");
    await page.getByRole("button", { name: "Run" }).click();

    const response = page.getByLabel("Response").first();

    await expect(response).toContainText("Running…", { timeout: 15000 });
    await expect(response).not.toContainText("Running…", { timeout: 120000 });

    // searched badge must appear
    await expect(page.getByText("searched")).toBeVisible({ timeout: 5000 });

    // Must not be the empty "(no content)" placeholder
    await expect(response).not.toContainText("(no content)");

    // Must have actual text
    const text = (await response.innerText()).trim();
    expect(text.length).toBeGreaterThan(10);
  });

  test("ollama/gpt-oss:20b current weather munich — no reasoning leak, actual weather data", async ({ page }) => {
    await setup(page);
    await pickModelByName(page, WEB_SEARCH_20B_MODEL);

    await expect(page.locator("[aria-haspopup='listbox']").first()).toContainText(WEB_SEARCH_20B_MODEL);

    const wsBtn = page.getByRole("button", { name: /web search/i });
    await wsBtn.click();
    await expect(wsBtn).toContainText("Web Search ON");

    await page.getByLabel("User message").fill(WEATHER_PROMPT);
    await page.getByRole("button", { name: "Run" }).click();

    const response = page.getByLabel("Response").first();

    await expect(response).toContainText("Running…", { timeout: 15000 });
    await expect(response).not.toContainText("Running…", { timeout: 120000 });

    // Log response before any assertions so we can see it even if something fails
    const text = (await response.innerText()).trim();
    console.log("RESPONSE TEXT:\n" + text);

    await page.waitForTimeout(3000);

    // Re-read the response after the wait so we get the fully-rendered content
    const finalText = (await response.innerText()).trim();
    console.log("FINAL RESPONSE TEXT:\n" + finalText);

    // searched badge confirms the gateway actually ran Brave search
    await expect(page.getByText("searched")).toBeVisible({ timeout: 5000 });

    // Hard failures
    await expect(response).not.toContainText("(no content)");
    await expect(response).not.toContainText("SERVER ERROR");

    // No reasoning leak — the specific thinking phrases the model emits
    await expect(response).not.toContainText("Need to summarize");
    await expect(response).not.toContainText("We have search results");
    await expect(response).not.toContainText("We must not hallucinate");
    await expect(response).not.toContainText("We need to provide");
    await expect(response).not.toContainText("But we can");

    // Must mention Munich (grounded in query)
    await expect(response).toContainText(/munich/i);

    // Must contain actual weather content — temperature number or conditions
    const hasWeatherContent =
      /\d+\s*°/.test(finalText) ||          // temperature like "12°" or "12 °C"
      /\d+\s*degrees/i.test(finalText) ||   // "12 degrees"
      /°[CF]/i.test(finalText) ||           // °C or °F
      /cloud|sun|rain|snow|overcast|clear|fog|wind|storm|partly/i.test(finalText); // conditions
    expect(hasWeatherContent, `response should contain weather data, got: ${finalText}`).toBeTruthy();
  });

  test("ollama/gpt-oss:120b performs live web search and returns grounded results", async ({ page }) => {
    await setup(page);
    await pickModelByName(page, WEB_SEARCH_MODEL);

    // Verify model is selected
    const trigger = page.locator("[aria-haspopup='listbox']").first();
    await expect(trigger).toContainText(WEB_SEARCH_MODEL);

    // Enable web search
    const wsBtn = page.getByRole("button", { name: /web search/i });
    await wsBtn.click();
    await expect(wsBtn).toContainText("Web Search ON");

    // Type the query and run
    await page.getByLabel("User message").fill(WEB_SEARCH_PROMPT);
    await page.getByRole("button", { name: "Run" }).click();

    const response = page.getByLabel("Response").first();

    // Confirm request was dispatched
    await expect(response).toContainText("Running…", { timeout: 15000 });

    // Wait for completion — gpt-oss:120b is large; allow up to 3 minutes
    await expect(response).not.toContainText("Running…", { timeout: 180000 });

    // The "searched" badge must be visible — confirms gateway ran the Brave search
    // and set X-Web-Search-Query on the response
    await expect(page.getByText("searched")).toBeVisible({ timeout: 5000 });

    // Response must not contain the model's standard "no real-time access" disclaimer
    await expect(response).not.toContainText(
      /I don.t have.*(access|ability).*(real.time|live|current|search)/i
    );

    // Response should mention Myra Security
    await expect(response).toContainText(/myra/i);
  });

  test("ollama/gpt-oss:20b myra security gmbh germany — english response, fetched content used", async ({ page }) => {
    await setup(page);
    await pickModelByName(page, WEB_SEARCH_20B_MODEL);
    await expect(page.locator("[aria-haspopup='listbox']").first()).toContainText(WEB_SEARCH_20B_MODEL);

    const wsBtn = page.getByRole("button", { name: /web search/i });
    await wsBtn.click();
    await expect(wsBtn).toContainText("Web Search ON");

    await page.getByLabel("User message").fill('do web search for "myra security gmbh germany", summarize');
    await page.getByRole("button", { name: "Run" }).click();

    const response = page.getByLabel("Response").first();
    await expect(response).toContainText("Running…", { timeout: 15000 });
    await expect(response).not.toContainText("Running…", { timeout: 120000 });

    // Wait for meaningful content to arrive before snapshotting
    await expect(response).toContainText(/myra/i, { timeout: 30000 });
    await page.waitForTimeout(5000);
    const finalText = (await response.innerText()).trim();
    console.log("FINAL RESPONSE TEXT:\n" + finalText);

    // searched badge must appear
    await expect(page.getByText("searched")).toBeVisible({ timeout: 5000 });

    // Must not be empty or errored
    await expect(response).not.toContainText("(no content)");
    await expect(response).not.toContainText("SERVER ERROR");

    // Must mention Myra
    await expect(response).toContainText(/myra/i);

    // Must be in English — check for common English function words and absence of German
    const germanWords = /\b(ist|und|der|die|das|ein|eine|für|mit|von|zu|als|auch|sich|auf|nicht|werden|werden|wurde)\b/i;
    expect(germanWords.test(finalText), `response should be in English but contains German words: ${finalText}`).toBeFalsy();

    // Must have substantive content (not just a one-liner Brave snippet)
    expect(finalText.length, `response too short, likely only Brave snippet: ${finalText}`).toBeGreaterThan(100);
  });

});
