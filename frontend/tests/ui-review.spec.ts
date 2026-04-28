/**
 * ui-review.spec.ts — full UI review screenshots in light and dark mode.
 *
 * Run against Docker container:
 *   cd frontend
 *   ./run-e2e.sh tests/ui-review.spec.ts --config playwright.docker.config.ts --project=ui-review
 *
 * Output: /tmp/ui-review/{light,dark}/*.png
 */

import { test, Browser, Page } from "@playwright/test";
import path from "path";
import fs from "fs";

test.setTimeout(180_000);

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

const BASE = "/tmp/ui-review";
const SESSION = path.resolve(__dirname, ".auth/docker-session.json");
["light", "dark"].forEach((m) => fs.mkdirSync(path.join(BASE, m), { recursive: true }));

type Mode = "light" | "dark";

async function snap(page: Page, mode: Mode, name: string) {
  await page.screenshot({
    path: path.join(BASE, mode, name),
    animations: "disabled",
    fullPage: false,
  });
}

async function waitReady(page: Page) {
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(400);
}

async function applyMode(page: Page, mode: Mode) {
  await page.emulateMedia({ colorScheme: mode });
  await page.evaluate((m) => {
    document.documentElement.setAttribute("data-theme", m);
    try { localStorage.setItem("aig-theme", m); } catch {}
  }, mode);
  await page.waitForTimeout(100);
}

async function newCtx(browser: Browser, mode: Mode) {
  const ctx = await browser.newContext({
    colorScheme: mode,
    storageState: SESSION,
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: 2,
  });
  // Pre-acknowledge the AIDisclosureModal so its overlay does not block clicks.
  await ctx.addInitScript(() => {
    try { localStorage.setItem("aig:ai-disclosure-acknowledged-v1", "1"); } catch {}
  });
  return ctx;
}

async function selectMyratest(page: Page) {
  const btn = page.getByRole("button", { name: /^myratest$/i });
  if (await btn.isVisible().catch(() => false)) { await btn.click(); await page.waitForTimeout(400); }
}

async function openFirstGateway(page: Page) {
  await selectMyratest(page);
  const btn = page.getByRole("button", { name: /Open →/i }).first();
  if (await btn.isVisible().catch(() => false)) { await btn.click(); await page.waitForTimeout(600); return true; }
  return false;
}

// ---------------------------------------------------------------------------
// Capture all screens in one mode
// ---------------------------------------------------------------------------

async function captureAll(browser: Browser, mode: Mode) {
  // ── Standard pages (shared context) ─────────────────────────────────────
  const ctx = await newCtx(browser, mode);
  const page = await ctx.newPage();
  await applyMode(page, mode);

  const pages: Array<{ name: string; url: string; setup?: (p: Page) => Promise<void> }> = [
    { name: "dashboard",              url: "/dashboard" },
    { name: "monitor",                url: "/monitor" },
    { name: "analytics",              url: "/analytics" },
    { name: "logs",                   url: "/logs" },
    { name: "playground",             url: "/playground" },
    { name: "chat",                   url: "/chat" },
    { name: "projects",               url: "/projects" },
    { name: "tenants",                url: "/tenants" },
    { name: "users",                  url: "/users" },
    { name: "profile",                url: "/profile" },
    { name: "model-prices",           url: "/model-prices" },
    { name: "prompts",                url: "/prompts" },
    { name: "gateways-list",          url: "/gateways", setup: selectMyratest },
    { name: "gateway-detail",         url: "/gateways", setup: openFirstGateway },
    {
      name: "gateway-detail-bottom",
      url: "/gateways",
      setup: async (p) => {
        await openFirstGateway(p);
        await p.evaluate(() => window.scrollTo(0, 1200));
        await p.waitForTimeout(200);
      },
    },
  ];

  for (const { name, url, setup } of pages) {
    await page.goto(url);
    await waitReady(page);
    await applyMode(page, mode);
    if (setup) await setup(page);
    await snap(page, mode, `${name}.png`);
  }

  // ── Chat with feedback button visible (scrolled to bottom-right) ──────────
  await page.goto("/chat");
  await waitReady(page);
  await applyMode(page, mode);
  await snap(page, mode, "chat-with-feedback-btn.png");

  // ── Gateway edit modal ────────────────────────────────────────────────────
  await page.goto("/gateways");
  await waitReady(page);
  await applyMode(page, mode);
  await openFirstGateway(page);
  const editBtn = page.getByRole("button", { name: /^Edit$/i }).first();
  if (await editBtn.isVisible().catch(() => false)) {
    await editBtn.click();
    await page.waitForTimeout(500);
  }
  await snap(page, mode, "gateway-edit-modal.png");

  // ── User new modal ────────────────────────────────────────────────────────
  await page.goto("/users");
  await waitReady(page);
  await applyMode(page, mode);
  const newUserBtn = page.getByRole("button", { name: /\+ new user/i }).first();
  if (await newUserBtn.isVisible().catch(() => false)) { await newUserBtn.click(); await page.waitForTimeout(400); }
  await snap(page, mode, "user-new-modal.png");

  // ── App feedback modal ─────────────────────────────────────────────────
  await page.goto("/dashboard");
  await waitReady(page);
  await applyMode(page, mode);
  const fbBtn = page.locator("[data-cy=app-feedback-btn]");
  if (await fbBtn.isVisible().catch(() => false)) { await fbBtn.click(); await page.waitForTimeout(400); }
  await snap(page, mode, "app-feedback-modal.png");

  // ── Chat settings drawer ──────────────────────────────────────────────────
  await page.goto("/chat");
  await waitReady(page);
  await applyMode(page, mode);
  const settingsBtn = page.locator("button[data-cy='chat-settings'], button[title*='etting']").first();
  if (await settingsBtn.isVisible().catch(() => false)) { await settingsBtn.click(); await page.waitForTimeout(400); }
  await snap(page, mode, "chat-settings.png");

  await ctx.close();

  // ── Login page (logged-out, fresh context) ────────────────────────────────
  const ctx2 = await browser.newContext({ colorScheme: mode, viewport: { width: 1440, height: 900 }, deviceScaleFactor: 2 });
  const page2 = await ctx2.newPage();
  await applyMode(page2, mode);
  await page2.goto("/login");
  await waitReady(page2);
  await snap(page2, mode, "login.png");
  await ctx2.close();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test("ui-review-light", async ({ browser }) => {
  await captureAll(browser, "light");
});

test("ui-review-dark", async ({ browser }) => {
  await captureAll(browser, "dark");
});
