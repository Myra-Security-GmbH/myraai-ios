/**
 * screenshots.spec.ts — captures admin UI screenshots for the documentation.
 *
 * Run against production:
 *   cd frontend
 *   npx playwright test tests/screenshots.spec.ts \
 *     --config playwright.production.config.ts --project=chromium
 *
 * Output: docs/docs.md/assets/screenshots/*.png
 */

import { test, expect, Page, Locator } from "@playwright/test";
import path from "path";
import fs from "fs";

test.use({
  viewport: { width: 1440, height: 900 },
  deviceScaleFactor: 2,
});

// ---------------------------------------------------------------------------
// Output directory
// ---------------------------------------------------------------------------

const OUT = path.resolve(__dirname, "../../docs/docs.md/assets/screenshots");
fs.mkdirSync(OUT, { recursive: true });

function snap(name: string) {
  return { path: path.join(OUT, name), animations: "disabled" as const };
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

async function waitReady(page: Page, extra = 400) {
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(extra);
}

/** Select the myratest tenant on /gateways or /tenants. */
async function selectMyratest(page: Page): Promise<boolean> {
  const btn = page.getByRole("button", { name: /^myratest$/i });
  if (!await btn.isVisible().catch(() => false)) return false;
  await btn.click();
  await page.waitForTimeout(600);
  return true;
}

/** Open the first available gateway detail page from /gateways. */
async function openFirstGateway(page: Page): Promise<boolean> {
  await selectMyratest(page);
  const openBtn = page.getByRole("button", { name: /Open →/i }).first();
  if (!await openBtn.isVisible().catch(() => false)) return false;
  await openBtn.click();
  await page.waitForTimeout(700);
  return true;
}

/** Open the gateway Edit modal. Returns the modal locator or null. */
async function openEditModal(page: Page): Promise<Locator | null> {
  const editBtn = page.getByRole("button", { name: /^Edit$/i }).first();
  if (!await editBtn.isVisible().catch(() => false)) return null;
  await editBtn.click();
  await page.waitForTimeout(500);
  const modal = page.locator("[role='dialog']").first();
  if (!await modal.isVisible().catch(() => false)) return null;
  return modal;
}

/** Scroll to a heading inside a container and screenshot that region. */
async function snapSection(
  container: Locator | Page,
  heading: RegExp | string,
  outFile: string,
): Promise<boolean> {
  const h = (container as Locator).getByText
    ? (container as Locator).getByText(heading)
    : (container as Page).getByText(heading);
  if (!await h.isVisible().catch(() => false)) return false;
  await h.scrollIntoViewIfNeeded();
  await (container as any).page?.waitForTimeout(200) ?? await (container as Page).waitForTimeout(200);
  if ((container as Locator).screenshot) {
    await (container as Locator).screenshot({ path: path.join(OUT, outFile), animations: "disabled" });
  } else {
    await (container as Page).screenshot(snap(outFile));
  }
  return true;
}

// ---------------------------------------------------------------------------
// 1. Login page (logged-out)
// ---------------------------------------------------------------------------

test("login-page", async ({ browser }) => {
  // Fresh context so we are not logged in
  const ctx  = await browser.newContext();
  const page = await ctx.newPage();
  await page.goto("/login");
  await waitReady(page);
  await page.screenshot(snap("login-page.png"));
  await ctx.close();
});

// ---------------------------------------------------------------------------
// 2. Dashboard overview
// ---------------------------------------------------------------------------

test("dashboard-overview", async ({ page }) => {
  await page.goto("/dashboard");
  await waitReady(page);
  await page.screenshot(snap("dashboard-overview.png"));
});

// ---------------------------------------------------------------------------
// 3. Live monitor
// ---------------------------------------------------------------------------

test("monitor-overview", async ({ page }) => {
  await page.goto("/monitor");
  await waitReady(page);
  await page.screenshot(snap("monitor-overview.png"));
});

// ---------------------------------------------------------------------------
// 4. Analytics
// ---------------------------------------------------------------------------

test("analytics-tabs", async ({ page }) => {
  await page.goto("/analytics");
  await waitReady(page);
  await page.screenshot(snap("analytics-tabs.png"));
});

// ---------------------------------------------------------------------------
// 5. Request logs
// ---------------------------------------------------------------------------

test("logs-table", async ({ page }) => {
  await page.goto("/logs");
  await waitReady(page);
  await page.screenshot(snap("logs-table.png"));
});

// ---------------------------------------------------------------------------
// 6. Playground
// ---------------------------------------------------------------------------

test("playground-layout", async ({ page }) => {
  await page.goto("/playground");
  await waitReady(page);
  const sel = page.locator("select").first();
  if (await sel.isVisible().catch(() => false)) {
    const opts = await sel.locator("option").allTextContents();
    if (opts.some(o => /myratest/i.test(o))) {
      await sel.selectOption({ label: "myratest" });
      await page.waitForTimeout(600);
    }
  }
  await page.screenshot(snap("playground-layout.png"));
});

// ---------------------------------------------------------------------------
// 7. Chat
// ---------------------------------------------------------------------------

test("chat", async ({ page }) => {
  await page.goto("/chat");
  await waitReady(page);
  await page.screenshot(snap("chat.png"));
});

test("chat-file-attach", async ({ page }) => {
  await page.goto("/chat");
  await waitReady(page);
  // Click the attach / paperclip button to reveal the file picker area
  const attachBtn = page.locator("button[title*='ttach'], button[aria-label*='ttach'], button[title*='ile'], button[aria-label*='ile']").first();
  if (await attachBtn.isVisible().catch(() => false) && await attachBtn.isEnabled().catch(() => false)) {
    await attachBtn.click();
    await page.waitForTimeout(400);
  }
  await page.screenshot(snap("chat-file-attach.png"));
});

// ---------------------------------------------------------------------------
// 8. Projects
// ---------------------------------------------------------------------------

test("projects-list", async ({ page }) => {
  await page.goto("/projects");
  await waitReady(page);
  await page.screenshot(snap("projects-list.png"));
});

test("projects-create", async ({ page }) => {
  await page.goto("/projects");
  await waitReady(page);
  const newBtn = page.getByRole("button", { name: /\+ new project/i }).first();
  if (await newBtn.isVisible().catch(() => false)) {
    await newBtn.click();
    await page.waitForTimeout(500);
  }
  await page.screenshot(snap("projects-create.png"));
});

// ---------------------------------------------------------------------------
// 9. Tenants list
// ---------------------------------------------------------------------------

test("tenants-list", async ({ page }) => {
  await page.goto("/tenants");
  await waitReady(page);
  await page.screenshot(snap("tenants-list.png"));
});

// ---------------------------------------------------------------------------
// 9. Users list
// ---------------------------------------------------------------------------

test("users-list", async ({ page }) => {
  await page.goto("/users");
  await waitReady(page);
  await page.screenshot(snap("users-list.png"));
});

// ---------------------------------------------------------------------------
// 10. New user dialog
// ---------------------------------------------------------------------------

test("user-new", async ({ page }) => {
  await page.goto("/users");
  await waitReady(page);
  const newBtn = page.getByRole("button", { name: /new user|add user|\+ user/i }).first();
  if (await newBtn.isVisible().catch(() => false)) {
    await newBtn.click();
    await page.waitForTimeout(400);
    const modal = page.locator("[role='dialog']").first();
    if (await modal.isVisible().catch(() => false)) {
      await modal.screenshot({ path: path.join(OUT, "user-new.png"), animations: "disabled" });
      return;
    }
  }
  await page.screenshot(snap("user-new.png"));
});

// ---------------------------------------------------------------------------
// 11. My tokens (profile page)
// ---------------------------------------------------------------------------

test("my-tokens", async ({ page }) => {
  await page.goto("/profile");
  await waitReady(page);
  await page.screenshot(snap("my-tokens.png"));
});

// ---------------------------------------------------------------------------
// 12. New token dialog
// ---------------------------------------------------------------------------

test("token-new", async ({ page }) => {
  await page.goto("/profile");
  await waitReady(page);
  const newBtn = page.getByRole("button", { name: /new token|add token|create token|\+ token/i }).first();
  if (await newBtn.isVisible().catch(() => false)) {
    await newBtn.click();
    await page.waitForTimeout(400);
    const modal = page.locator("[role='dialog']").first();
    if (await modal.isVisible().catch(() => false)) {
      await modal.screenshot({ path: path.join(OUT, "token-new.png"), animations: "disabled" });
      return;
    }
  }
  await page.screenshot(snap("token-new.png"));
});

// ---------------------------------------------------------------------------
// 13. Model prices
// ---------------------------------------------------------------------------

test("model-prices-list", async ({ page }) => {
  await page.goto("/model-prices");
  await waitReady(page);
  await page.screenshot(snap("model-prices-list.png"));
});

test("model-prices-edit", async ({ page }) => {
  await page.goto("/model-prices");
  await waitReady(page);
  // Try to click the first Edit button on any price row
  const editBtn = page.getByRole("button", { name: /^edit$/i }).first();
  if (await editBtn.isVisible().catch(() => false)) {
    await editBtn.click();
    await page.waitForTimeout(400);
    const modal = page.locator("[role='dialog']").first();
    if (await modal.isVisible().catch(() => false)) {
      await modal.screenshot({ path: path.join(OUT, "model-prices-edit.png"), animations: "disabled" });
      return;
    }
  }
  await page.screenshot(snap("model-prices-edit.png"));
});

// ---------------------------------------------------------------------------
// 14. Gateways list
// ---------------------------------------------------------------------------

test("gateways-list", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  await selectMyratest(page).catch(() => {});
  await page.screenshot(snap("gateways-list.png"));
  // gateway-list.png is the same view, referenced from quick-start docs
  await page.screenshot(snap("gateway-list.png"));
});

// ---------------------------------------------------------------------------
// 15. Gateway detail
// ---------------------------------------------------------------------------

test("gateway-detail", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  await openFirstGateway(page);
  await page.screenshot(snap("gateway-detail.png"));
});

// ---------------------------------------------------------------------------
// 16. Gateway edit modal
// ---------------------------------------------------------------------------

test("gateway-edit-modal", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  if (await openFirstGateway(page)) {
    const modal = await openEditModal(page);
    if (modal) {
      await modal.screenshot({ path: path.join(OUT, "gateway-edit-modal.png"), animations: "disabled" });
      return;
    }
  }
  await page.screenshot(snap("gateway-edit-modal.png"));
});

// ---------------------------------------------------------------------------
// 17–21. Gateway config modal — specific sections
// ---------------------------------------------------------------------------

async function gatewayModalSection(page: Page, heading: string | RegExp, outFile: string) {
  await page.goto("/gateways");
  await waitReady(page);
  if (!await openFirstGateway(page)) { await page.screenshot(snap(outFile)); return; }
  const modal = await openEditModal(page);
  if (!modal) { await page.screenshot(snap(outFile)); return; }
  // Scroll inside modal to the section heading
  const target = modal.getByText(heading, { exact: false }).first();
  if (await target.isVisible().catch(() => false)) {
    await target.scrollIntoViewIfNeeded();
    await page.waitForTimeout(300);
  }
  await modal.screenshot({ path: path.join(OUT, outFile), animations: "disabled" });
}

test("gateway-config-auth",      ({ page }) => gatewayModalSection(page, /auth/i,         "gateway-config-auth.png"));
test("gateway-config-azure",     ({ page }) => gatewayModalSection(page, /azure/i,        "gateway-config-azure.png"));
test("gateway-config-vertex",    ({ page }) => gatewayModalSection(page, /vertex/i,       "gateway-config-vertex.png"));
test("gateway-config-base-urls", ({ page }) => gatewayModalSection(page, /base url|provider url/i, "gateway-config-base-urls.png"));

// ---------------------------------------------------------------------------
// 22–23. Gateway rate limit and budget
// ---------------------------------------------------------------------------

test("gateway-rate-limit", ({ page }) => gatewayModalSection(page, /rate limit/i, "gateway-rate-limit.png"));
test("gateway-budget",     ({ page }) => gatewayModalSection(page, /budget/i,     "gateway-budget.png"));

// ---------------------------------------------------------------------------
// 24–25. Budget reset (screenshot the reset button area without clicking)
// ---------------------------------------------------------------------------

async function budgetResetSnap(page: Page, outFile: string) {
  await page.goto("/gateways");
  await waitReady(page);
  if (!await openFirstGateway(page)) { await page.screenshot(snap(outFile)); return; }
  const resetBtn = page.getByRole("button", { name: /reset.*budget|budget.*reset/i }).first();
  if (await resetBtn.isVisible().catch(() => false)) {
    await resetBtn.scrollIntoViewIfNeeded();
    await page.waitForTimeout(200);
    await page.screenshot(snap(outFile));
  } else {
    await page.screenshot(snap(outFile));
  }
}

test("gateway-budget-reset", ({ page }) => budgetResetSnap(page, "gateway-budget-reset.png"));

test("user-budget-reset", async ({ page }) => {
  await page.goto("/users");
  await waitReady(page);
  const e2eUser = page.getByText("e2e-create-user-test@local.test").first();
  if (await e2eUser.isVisible().catch(() => false)) {
    await e2eUser.click();
    await page.waitForTimeout(400);
  }
  const resetBtn = page.getByRole("button", { name: /reset.*budget|budget.*reset/i }).first();
  if (await resetBtn.isVisible().catch(() => false)) {
    await resetBtn.scrollIntoViewIfNeeded();
    await page.waitForTimeout(200);
  }
  await page.screenshot(snap("user-budget-reset.png"));
});

// ---------------------------------------------------------------------------
// 26–27. Token rate limit and budget (user detail panel)
// ---------------------------------------------------------------------------

test("token-rate-limit", async ({ page }) => {
  await page.goto("/users");
  await waitReady(page);
  const e2eUser = page.getByText("e2e-create-user-test@local.test").first();
  if (await e2eUser.isVisible().catch(() => false)) {
    await e2eUser.click();
    await page.waitForTimeout(500);
  }
  const target = page.getByText(/rate limit/i).first();
  if (await target.isVisible().catch(() => false)) await target.scrollIntoViewIfNeeded();
  await page.screenshot(snap("token-rate-limit.png"));
});

test("token-budget", async ({ page }) => {
  await page.goto("/users");
  await waitReady(page);
  const e2eUser = page.getByText("e2e-create-user-test@local.test").first();
  if (await e2eUser.isVisible().catch(() => false)) {
    await e2eUser.click();
    await page.waitForTimeout(500);
  }
  const target = page.getByText(/budget/i).first();
  if (await target.isVisible().catch(() => false)) await target.scrollIntoViewIfNeeded();
  await page.screenshot(snap("token-budget.png"));
});

// ---------------------------------------------------------------------------
// 28. Gateway circuit breaker
// ---------------------------------------------------------------------------

test("gateway-circuit-breaker", ({ page }) => gatewayModalSection(page, /circuit breaker/i, "gateway-circuit-breaker.png"));

// ---------------------------------------------------------------------------
// 29. Gateway SIEM
// ---------------------------------------------------------------------------

test("gateway-siem", ({ page }) => gatewayModalSection(page, /siem/i, "gateway-siem.png"));

// ---------------------------------------------------------------------------
// 30. BYOK add key modal
// ---------------------------------------------------------------------------

test("byok-add-key", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  if (!await openFirstGateway(page)) { await page.screenshot(snap("byok-add-key.png")); return; }
  // Scroll to Provider Keys / BYOK card
  const byokCard = page.getByText(/provider key|byok/i).first();
  if (await byokCard.isVisible().catch(() => false)) await byokCard.scrollIntoViewIfNeeded();
  // Click Add / + button in BYOK section
  const addBtn = page.getByRole("button", { name: /add key|\+ key|add provider key/i }).first();
  if (await addBtn.isVisible().catch(() => false)) {
    await addBtn.click();
    await page.waitForTimeout(400);
    const modal = page.locator("[role='dialog']").first();
    if (await modal.isVisible().catch(() => false)) {
      await modal.screenshot({ path: path.join(OUT, "byok-add-key.png"), animations: "disabled" });
      return;
    }
  }
  await page.screenshot(snap("byok-add-key.png"));
});

// ---------------------------------------------------------------------------
// 31. IP allowlist config
// ---------------------------------------------------------------------------

test("ip-allowlist-config", ({ page }) => gatewayModalSection(page, /ip allow|allowlist/i, "ip-allowlist-config.png"));

// ---------------------------------------------------------------------------
// 32. Guardrails builder (overview)
// ---------------------------------------------------------------------------

test("guardrails-builder", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  if (await openFirstGateway(page)) {
    const saveBtn = page.getByRole("button", { name: /save guardrail/i });
    if (await saveBtn.isVisible().catch(() => false)) {
      await saveBtn.scrollIntoViewIfNeeded();
      await page.waitForTimeout(200);
    }
  }
  await page.screenshot(snap("guardrails-builder.png"));
});

// ---------------------------------------------------------------------------
// 33. Guardrails builder — showing the add-type buttons
// ---------------------------------------------------------------------------

test("guardrails-builder-add", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  if (await openFirstGateway(page)) {
    // Scroll to the Add Type / + button cluster
    const addArea = page.getByRole("button", { name: /\+ regex|\+ keyword|\+ jailbreak/i }).first();
    if (await addArea.isVisible().catch(() => false)) {
      await addArea.scrollIntoViewIfNeeded();
      await page.waitForTimeout(200);
    } else {
      const saveBtn = page.getByRole("button", { name: /save guardrail/i });
      if (await saveBtn.isVisible().catch(() => false)) await saveBtn.scrollIntoViewIfNeeded();
    }
  }
  await page.screenshot(snap("guardrails-builder-add.png"));
});

// ---------------------------------------------------------------------------
// 34–43. Individual guardrail type cards
// ---------------------------------------------------------------------------

const GUARDRAIL_TYPES: Array<{ label: string; slug: string }> = [
  { label: "Regex",         slug: "regex" },
  { label: "Keyword",       slug: "keyword" },
  { label: "Jailbreak",     slug: "jailbreak" },
  { label: "JSON Schema",   slug: "json-schema" },
  { label: "Contains Code", slug: "contains-code" },
  { label: "Gibberish",     slug: "gibberish" },
  { label: "Language",      slug: "language" },
  { label: "Presidio",      slug: "presidio" },
  { label: "Prompt Guard",  slug: "prompt_guard" },
  { label: "PII Protector", slug: "pii_protector" },
];

for (const { label, slug } of GUARDRAIL_TYPES) {
  test(`guardrail-${slug}-builder`, async ({ page }) => {
    const outFile = `guardrail-${slug}-builder.png`;
    await page.goto("/gateways");
    await waitReady(page);
    if (!await openFirstGateway(page)) { await page.screenshot(snap(outFile)); return; }

    const saveBtn = page.getByRole("button", { name: /save guardrail/i });
    if (await saveBtn.isVisible().catch(() => false)) await saveBtn.scrollIntoViewIfNeeded();

    // Click the "+ Type" add button for this guardrail
    const addBtn = page.getByRole("button", {
      name: new RegExp(`\\+\\s*${label.replace(/[()[\]]/g, "\\$&")}`, "i"),
    });
    if (!await addBtn.isVisible().catch(() => false)) {
      await page.screenshot(snap(outFile));
      return;
    }
    await addBtn.click();
    await page.waitForTimeout(400);

    // Expand the last card (newly added)
    const cards = page.locator("[data-testid='detector-card']");
    const count = await cards.count();
    if (count > 0) {
      const last = cards.nth(count - 1);
      await last.click();
      await page.waitForTimeout(300);
      await last.scrollIntoViewIfNeeded();
      await page.waitForTimeout(200);
      await last.screenshot({ path: path.join(OUT, outFile), animations: "disabled" });
    } else {
      await page.screenshot(snap(outFile));
    }
  });

  // Also save without "-builder" suffix for pages that reference guardrail-{slug}.png
  test(`guardrail-${slug}`, async ({ page }) => {
    const outFile = `guardrail-${slug}.png`;
    const builderFile = path.join(OUT, `guardrail-${slug}-builder.png`);
    // Re-use the builder screenshot if it was already saved
    await page.waitForTimeout(200);
    if (fs.existsSync(builderFile)) {
      fs.copyFileSync(builderFile, path.join(OUT, outFile));
      return;
    }
    await page.goto("/gateways");
    await waitReady(page);
    await openFirstGateway(page);
    await page.screenshot(snap(outFile));
  });
}

// ---------------------------------------------------------------------------
// 44. Routing rules list (on gateway detail)
// ---------------------------------------------------------------------------

test("routing-rules-list", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  if (await openFirstGateway(page)) {
    const rulesHeading = page.getByText(/routing rule/i).first();
    if (await rulesHeading.isVisible().catch(() => false)) {
      await rulesHeading.scrollIntoViewIfNeeded();
      await page.waitForTimeout(200);
    }
  }
  await page.screenshot(snap("routing-rules-list.png"));
});

// ---------------------------------------------------------------------------
// 45. Routing rule editor modal (basic)
// ---------------------------------------------------------------------------

test("routing-rule-editor", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  if (await openFirstGateway(page)) {
    const newBtn = page.getByRole("button", { name: /\+ new rule/i });
    if (await newBtn.isVisible().catch(() => false)) {
      await newBtn.click();
      await page.waitForTimeout(400);
      const addCond = page.getByRole("button", { name: /^\+ add$/i }).first();
      if (await addCond.isVisible().catch(() => false)) { await addCond.click(); await page.waitForTimeout(200); }
    }
  }
  await page.screenshot(snap("routing-rule-editor.png"));
});

// ---------------------------------------------------------------------------
// 46. Routing rule editor — fallbacks section visible
// ---------------------------------------------------------------------------

test("routing-rule-fallbacks", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  if (await openFirstGateway(page)) {
    const newBtn = page.getByRole("button", { name: /\+ new rule/i });
    if (await newBtn.isVisible().catch(() => false)) {
      await newBtn.click();
      await page.waitForTimeout(400);
      const fallbackSection = page.getByText(/fallback/i).first();
      if (await fallbackSection.isVisible().catch(() => false)) await fallbackSection.scrollIntoViewIfNeeded();
    }
  }
  await page.screenshot(snap("routing-rule-fallbacks.png"));
});

// ---------------------------------------------------------------------------
// 47. Routing rule editor — load balancing section visible
// ---------------------------------------------------------------------------

test("routing-rule-load-balance", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  if (await openFirstGateway(page)) {
    const newBtn = page.getByRole("button", { name: /\+ new rule/i });
    if (await newBtn.isVisible().catch(() => false)) {
      await newBtn.click();
      await page.waitForTimeout(400);
      const lbSection = page.getByText(/load balanc/i).first();
      if (await lbSection.isVisible().catch(() => false)) await lbSection.scrollIntoViewIfNeeded();
    }
  }
  await page.screenshot(snap("routing-rule-load-balance.png"));
});

// ---------------------------------------------------------------------------
// 48. Prompts / prompt library
// ---------------------------------------------------------------------------

test("prompts", async ({ page }) => {
  await page.goto("/prompts");
  await waitReady(page);
  await page.screenshot(snap("prompts.png"));
});

// ---------------------------------------------------------------------------
// Instruction screenshots — blue-border highlighted variants
// Naming convention: <base>-hl.png  (hl = highlighted)
// Used in instruction steps (Creating / Editing / Deleting sections).
// The highlighted element shows the user exactly where to click or type.
// ---------------------------------------------------------------------------

/** Apply a blue outline to a locator, take a screenshot, then remove it. */
async function snapHighlight(
  page: Page,
  locator: Locator,
  outFile: string,
  containerLocator?: Locator,
) {
  await locator.evaluate((el: HTMLElement) => {
    el.dataset._hlPrev = el.style.outline + "|" + el.style.outlineOffset;
    el.style.outline = "3px solid #0066CC";
    el.style.outlineOffset = "2px";
  });
  await page.waitForTimeout(100);
  if (containerLocator) {
    await containerLocator.screenshot({ path: path.join(OUT, outFile), animations: "disabled" });
  } else {
    await page.screenshot(snap(outFile));
  }
  await locator.evaluate((el: HTMLElement) => {
    const prev = (el.dataset._hlPrev ?? "|").split("|");
    el.style.outline = prev[0];
    el.style.outlineOffset = prev[1];
    delete el.dataset._hlPrev;
  });
}

// -- Gateway list: highlight the "+ New Gateway" button --
test("gateway-list-hl", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  await selectMyratest(page).catch(() => {});
  const btn = page.getByRole("button", { name: /\+ new gateway/i });
  if (await btn.isVisible().catch(() => false)) {
    await snapHighlight(page, btn, "gateway-list-hl.png");
  } else {
    await page.screenshot(snap("gateway-list-hl.png"));
  }
});

// -- Gateway edit modal: highlight the Save button --
test("gateway-edit-modal-hl", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  if (!await openFirstGateway(page)) { await page.screenshot(snap("gateway-edit-modal-hl.png")); return; }
  const modal = await openEditModal(page);
  if (!modal) { await page.screenshot(snap("gateway-edit-modal-hl.png")); return; }
  const saveBtn = modal.getByRole("button", { name: /save/i }).first();
  if (await saveBtn.isVisible().catch(() => false)) {
    await snapHighlight(page, saveBtn, "gateway-edit-modal-hl.png", modal);
  } else {
    await modal.screenshot({ path: path.join(OUT, "gateway-edit-modal-hl.png"), animations: "disabled" });
  }
});

// -- Users list: highlight the "+ New User" button --
test("users-list-hl", async ({ page }) => {
  await page.goto("/users");
  await waitReady(page);
  const btn = page.getByRole("button", { name: /\+ new user/i });
  if (await btn.isVisible().catch(() => false)) {
    await snapHighlight(page, btn, "users-list-hl.png");
  } else {
    await page.screenshot(snap("users-list-hl.png"));
  }
});

// -- New user dialog: highlight the "Create User" submit button --
test("user-new-hl", async ({ page }) => {
  await page.goto("/users");
  await waitReady(page);
  const newBtn = page.getByRole("button", { name: /\+ new user/i });
  if (await newBtn.isVisible().catch(() => false)) {
    await newBtn.click();
    await page.waitForTimeout(400);
  }
  const modal = page.locator("[role='dialog']").first();
  const submitBtn = modal.getByRole("button", { name: /create user/i });
  if (await submitBtn.isVisible().catch(() => false)) {
    await snapHighlight(page, submitBtn, "user-new-hl.png", modal);
  } else {
    await page.screenshot(snap("user-new-hl.png"));
  }
});

// -- My Tokens: highlight the "+ New Token" button --
test("my-tokens-hl", async ({ page }) => {
  await page.goto("/tokens");
  await waitReady(page);
  const btn = page.getByRole("button", { name: /\+ new token/i });
  if (await btn.isVisible().catch(() => false)) {
    await snapHighlight(page, btn, "my-tokens-hl.png");
  } else {
    await page.screenshot(snap("my-tokens-hl.png"));
  }
});

// -- New token dialog: highlight the "Create Token" submit button --
test("token-new-hl", async ({ page }) => {
  await page.goto("/tokens");
  await waitReady(page);
  const newBtn = page.getByRole("button", { name: /\+ new token/i });
  if (await newBtn.isVisible().catch(() => false)) {
    await newBtn.click();
    await page.waitForTimeout(400);
  }
  const modal = page.locator("[role='dialog']").first();
  const submitBtn = modal.getByRole("button", { name: /create token/i });
  if (await submitBtn.isVisible().catch(() => false)) {
    await snapHighlight(page, submitBtn, "token-new-hl.png", modal);
  } else {
    await page.screenshot(snap("token-new-hl.png"));
  }
});

// -- Model prices list: highlight the "+ New Price" button --
test("model-prices-list-hl", async ({ page }) => {
  await page.goto("/model-prices");
  await waitReady(page);
  const btn = page.getByRole("button", { name: /\+ new price/i });
  if (await btn.isVisible().catch(() => false)) {
    await snapHighlight(page, btn, "model-prices-list-hl.png");
  } else {
    await page.screenshot(snap("model-prices-list-hl.png"));
  }
});

// -- Model prices edit dialog: highlight the Save button --
test("model-prices-edit-hl", async ({ page }) => {
  await page.goto("/model-prices");
  await waitReady(page);
  const editBtn = page.getByRole("button", { name: /edit/i }).first();
  if (await editBtn.isVisible().catch(() => false)) {
    await editBtn.click();
    await page.waitForTimeout(400);
  }
  const modal = page.locator("[role='dialog']").first();
  const saveBtn = modal.getByRole("button", { name: /save/i });
  if (await saveBtn.isVisible().catch(() => false)) {
    await snapHighlight(page, saveBtn, "model-prices-edit-hl.png", modal);
  } else {
    await page.screenshot(snap("model-prices-edit-hl.png"));
  }
});

// -- BYOK: highlight the Add / Rotate button on the gateway detail --
test("byok-add-key-hl", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  if (!await openFirstGateway(page)) { await page.screenshot(snap("byok-add-key-hl.png")); return; }
  const addBtn = page.getByRole("button", { name: /add.*rotate|rotate.*add|\+ add/i }).first();
  if (await addBtn.isVisible().catch(() => false)) {
    await addBtn.scrollIntoViewIfNeeded();
    await page.waitForTimeout(200);
    await snapHighlight(page, addBtn, "byok-add-key-hl.png");
  } else {
    await page.screenshot(snap("byok-add-key-hl.png"));
  }
});

// -- Guardrails builder: highlight the "+ Regex/Pattern" add-guardrail button --
test("guardrails-builder-hl", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  if (!await openFirstGateway(page)) { await page.screenshot(snap("guardrails-builder-hl.png")); return; }
  const addBtn = page.getByRole("button", { name: /regex.*pattern|\+ keyword|\+ jailbreak/i }).first();
  if (await addBtn.isVisible().catch(() => false)) {
    await addBtn.scrollIntoViewIfNeeded();
    await page.waitForTimeout(200);
    await snapHighlight(page, addBtn, "guardrails-builder-hl.png");
  } else {
    await page.screenshot(snap("guardrails-builder-hl.png"));
  }
});

// -- IP allowlist: highlight the Add entry field or button --
test("ip-allowlist-config-hl", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  if (!await openFirstGateway(page)) { await page.screenshot(snap("ip-allowlist-config-hl.png")); return; }
  const modal = await openEditModal(page);
  if (!modal) { await page.screenshot(snap("ip-allowlist-config-hl.png")); return; }
  const ipTarget = modal.getByText(/ip.*allow|allowlist/i).first();
  if (await ipTarget.isVisible().catch(() => false)) await ipTarget.scrollIntoViewIfNeeded();
  const addBtn = modal.getByRole("button", { name: /add|save/i }).last();
  if (await addBtn.isVisible().catch(() => false)) {
    await snapHighlight(page, addBtn, "ip-allowlist-config-hl.png", modal);
  } else {
    await modal.screenshot({ path: path.join(OUT, "ip-allowlist-config-hl.png"), animations: "disabled" });
  }
});

// -- Routing rule editor: highlight the Save / Create button --
test("routing-rule-editor-hl", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  if (!await openFirstGateway(page)) { await page.screenshot(snap("routing-rule-editor-hl.png")); return; }
  const newBtn = page.getByRole("button", { name: /\+ new rule/i });
  if (await newBtn.isVisible().catch(() => false)) {
    await newBtn.click();
    await page.waitForTimeout(400);
  }
  const saveBtn = page.getByRole("button", { name: /save.*rule|create.*rule|save/i }).first();
  if (await saveBtn.isVisible().catch(() => false)) {
    await snapHighlight(page, saveBtn, "routing-rule-editor-hl.png");
  } else {
    await page.screenshot(snap("routing-rule-editor-hl.png"));
  }
});

// -- Gateways list: highlight the "Open →" link for the first gateway --
test("gateways-list-hl", async ({ page }) => {
  await page.goto("/gateways");
  await waitReady(page);
  await selectMyratest(page).catch(() => {});
  const openBtn = page.getByRole("button", { name: /Open →/i }).first();
  if (await openBtn.isVisible().catch(() => false)) {
    await snapHighlight(page, openBtn, "gateways-list-hl.png");
  } else {
    await page.screenshot(snap("gateways-list-hl.png"));
  }
});
