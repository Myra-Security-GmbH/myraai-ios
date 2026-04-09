/**
 * chat-star-archive.spec.ts — E2E tests for conversation starring and archiving.
 *
 * Coverage:
 *   Group 1 — API: starring
 *   Group 2 — API: archiving / unarchiving
 *   Group 3 — UI: star button toggles state and persists
 *   Group 4 — UI: archive button removes from list; archived view; unarchive
 *   Group 5 — UI: recency buckets render correctly
 */

import { test, expect, type Page } from "@playwright/test";

// The session cookie is for localhost — always go through the Vite proxy.
const ADMIN_BASE = `${process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173"}/admin/v1`;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

interface ConvRow { id: string; title: string; starred?: number; archived_at?: number | null; updated_at: string; }
interface TenantRow { id: string; slug: string; }
interface GatewayRow { id: string; slug: string; }

async function getGatewayId(page: Page): Promise<string | null> {
  const tr = await page.request.get(`${ADMIN_BASE}/tenants`);
  if (!tr.ok()) return null;
  const tenants = await tr.json() as TenantRow[];
  for (const t of tenants) {
    const gr = await page.request.get(`${ADMIN_BASE}/tenants/${t.id}/gateways`);
    if (!gr.ok()) continue;
    const gws = await gr.json() as GatewayRow[];
    if (gws.length) return gws[0].id;
  }
  return null;
}

async function createConv(page: Page, gatewayId: string, title: string): Promise<string> {
  const r = await page.request.post(`${ADMIN_BASE}/conversations`, {
    data: { gateway_id: gatewayId, title },
  });
  expect(r.ok(), `createConv: ${await r.text()}`).toBeTruthy();
  const body = await r.json() as ConvRow;
  return body.id;
}

async function deleteConv(page: Page, id: string) {
  await page.request.delete(`${ADMIN_BASE}/conversations/${id}`).catch(() => {});
}

async function patchConv(page: Page, id: string, data: Record<string, unknown>) {
  const r = await page.request.patch(`${ADMIN_BASE}/conversations/${id}`, { data });
  expect(r.ok(), `patchConv(${id}): ${await r.text()}`).toBeTruthy();
}

async function listConvs(page: Page, archived = false): Promise<ConvRow[]> {
  const url = archived ? `${ADMIN_BASE}/conversations?archived=1` : `${ADMIN_BASE}/conversations`;
  const r = await page.request.get(url);
  expect(r.ok()).toBeTruthy();
  return r.json();
}

async function setChatGateway(page: Page, gatewayId: string) {
  // Must be on the app domain to access localStorage
  if (!page.url().startsWith("http://localhost")) {
    await page.goto("/dashboard");
    await page.waitForTimeout(400);
  }
  await page.evaluate((g) => {
    localStorage.setItem("aig-chat-gateway", g);
  }, gatewayId);
}

// ---------------------------------------------------------------------------
// Group 1: API — starring
// ---------------------------------------------------------------------------

test.describe("star API", () => {
  let convId: string;
  let gatewayId: string;

  test.beforeEach(async ({ page }) => {
    const gw = await getGatewayId(page);
    expect(gw, "need at least one gateway").toBeTruthy();
    gatewayId = gw!;
    convId = await createConv(page, gatewayId, "star-test-" + Date.now());
  });

  test.afterEach(async ({ page }) => {
    if (convId) await deleteConv(page, convId);
  });

  test("PATCH starred=1 → GET list returns item with starred=1", async ({ page }) => {
    await patchConv(page, convId, { starred: 1 });
    const rows = await listConvs(page);
    const row = rows.find((r) => r.id === convId);
    expect(row, "conversation must appear in list").toBeTruthy();
    expect(row!.starred).toBe(1);
  });

  test("starred conversation appears first in list", async ({ page }) => {
    const otherId = await createConv(page, gatewayId, "other-" + Date.now());
    try {
      await patchConv(page, convId, { starred: 1 });
      const rows = await listConvs(page);
      const idx   = rows.findIndex((r) => r.id === convId);
      const other = rows.findIndex((r) => r.id === otherId);
      expect(idx).toBeGreaterThanOrEqual(0);
      expect(other).toBeGreaterThanOrEqual(0);
      expect(idx).toBeLessThan(other);
    } finally {
      await deleteConv(page, otherId);
    }
  });

  test("PATCH starred=0 → starred field becomes 0", async ({ page }) => {
    await patchConv(page, convId, { starred: 1 });
    await patchConv(page, convId, { starred: 0 });
    const rows = await listConvs(page);
    const row = rows.find((r) => r.id === convId);
    expect(row!.starred).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Group 2: API — archiving / unarchiving
// ---------------------------------------------------------------------------

test.describe("archive API", () => {
  let convId: string;
  let gatewayId: string;

  test.beforeEach(async ({ page }) => {
    const gw = await getGatewayId(page);
    expect(gw, "need at least one gateway").toBeTruthy();
    gatewayId = gw!;
    convId = await createConv(page, gatewayId, "archive-test-" + Date.now());
  });

  test.afterEach(async ({ page }) => {
    if (convId) await deleteConv(page, convId);
  });

  test("PATCH archived_at → item absent from default list", async ({ page }) => {
    await patchConv(page, convId, { archived_at: Math.floor(Date.now() / 1000) });
    const rows = await listConvs(page, false);
    expect(rows.find((r) => r.id === convId)).toBeUndefined();
  });

  test("PATCH archived_at → item present in ?archived=1 list", async ({ page }) => {
    const ts = Math.floor(Date.now() / 1000);
    await patchConv(page, convId, { archived_at: ts });
    const rows = await listConvs(page, true);
    const row = rows.find((r) => r.id === convId);
    expect(row, "archived conversation must appear in archived list").toBeTruthy();
    // archived_at should be non-null (cjson omits nil, check truthy)
    expect(row!.archived_at == null).toBeFalsy();
  });

  test("PATCH archived_at=null → item returns to default list", async ({ page }) => {
    await patchConv(page, convId, { archived_at: Math.floor(Date.now() / 1000) });
    await patchConv(page, convId, { archived_at: null });
    const rows = await listConvs(page, false);
    expect(rows.find((r) => r.id === convId)).toBeTruthy();
    const archivedRows = await listConvs(page, true);
    expect(archivedRows.find((r) => r.id === convId)).toBeUndefined();
  });
});

// ---------------------------------------------------------------------------
// Group 3: UI — star button
// ---------------------------------------------------------------------------

test.describe("star UI", () => {
  let convId: string;
  let gatewayId: string;

  test.beforeEach(async ({ page }) => {
    const gw = await getGatewayId(page);
    expect(gw, "need at least one gateway").toBeTruthy();
    gatewayId = gw!;
    convId = await createConv(page, gatewayId, "ui-star-" + Date.now());
    await setChatGateway(page, gatewayId);
  });

  test.afterEach(async ({ page }) => {
    if (convId) {
      await patchConv(page, convId, { starred: 0 }).catch(() => {});
      await deleteConv(page, convId);
    }
  });

  test("star button appears on hover and conversation lands in Starred bucket", async ({ page }) => {
    await page.goto("/chat");
    await page.waitForTimeout(800);

    const item = page.locator(`[role="option"]:has-text("ui-star-")`).first();
    await expect(item).toBeVisible({ timeout: 8000 });

    await item.hover();
    const starBtn = item.locator("button[title='Star conversation']");
    await expect(starBtn).toBeVisible();

    await starBtn.click();

    // The "Starred" section header should appear
    await expect(page.locator(".conv-bucket-label, [class*='conv-bucket-label']").filter({ hasText: "Starred" })).toBeVisible({ timeout: 5000 });
  });

  test("starred state persists after page reload", async ({ page }) => {
    await patchConv(page, convId, { starred: 1 });

    await page.goto("/chat");
    await page.waitForTimeout(800);

    // Starred bucket should appear
    const starredLabel = page.locator("[class*='conv-bucket-label']").filter({ hasText: "Starred" });
    await expect(starredLabel).toBeVisible({ timeout: 8000 });

    // Our conversation should be in it
    await expect(page.locator(`[role="option"]:has-text("ui-star-")`).first()).toBeVisible();
  });

  test("unstar button replaces star button after starring", async ({ page }) => {
    await patchConv(page, convId, { starred: 1 });

    await page.goto("/chat");
    await page.waitForTimeout(800);

    const item = page.locator(`[role="option"]:has-text("ui-star-")`).first();
    await item.hover();

    // Should show "Unstar" title
    const unstarBtn = item.locator("button[title='Unstar']");
    await expect(unstarBtn).toBeVisible();

    await unstarBtn.click();
    await page.waitForTimeout(300);

    // API should show starred=0
    const rows = await listConvs(page, false);
    const row = rows.find((r) => r.id === convId);
    expect(row!.starred).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Group 4: UI — archive button, archived view, unarchive
// ---------------------------------------------------------------------------

test.describe("archive UI", () => {
  let convId: string;
  let gatewayId: string;

  test.beforeEach(async ({ page }) => {
    const gw = await getGatewayId(page);
    expect(gw, "need at least one gateway").toBeTruthy();
    gatewayId = gw!;
    convId = await createConv(page, gatewayId, "ui-archive-" + Date.now());
    await setChatGateway(page, gatewayId);
  });

  test.afterEach(async ({ page }) => {
    if (convId) {
      await patchConv(page, convId, { archived_at: null }).catch(() => {});
      await deleteConv(page, convId);
    }
  });

  test("archive button removes item from main list immediately", async ({ page }) => {
    await page.goto("/chat");
    await page.waitForTimeout(800);

    const item = page.locator(`[role="option"]:has-text("ui-archive-")`).first();
    await expect(item).toBeVisible({ timeout: 8000 });

    await item.hover();
    const archiveBtn = item.locator("button[title='Archive conversation']");
    await expect(archiveBtn).toBeVisible();
    await archiveBtn.click();

    // Item should disappear from main list
    await expect(page.locator(`[role="option"]:has-text("ui-archive-")`)).not.toBeVisible({ timeout: 5000 });
  });

  test("Archived chats toggle shows archived items", async ({ page }) => {
    await patchConv(page, convId, { archived_at: Math.floor(Date.now() / 1000) });

    await page.goto("/chat");
    await page.waitForTimeout(800);

    // Item should not be in main list
    await expect(page.locator(`[role="option"]:has-text("ui-archive-")`)).not.toBeVisible();

    // Click archive toggle
    const toggle = page.locator("[data-cy='conv-archive-toggle']");
    await expect(toggle).toBeVisible();
    await toggle.click();
    await page.waitForTimeout(600);

    // Item should appear in archived view
    await expect(page.locator(`[role="option"]:has-text("ui-archive-")`)).toBeVisible({ timeout: 8000 });
  });

  test("unarchive restores item to main list", async ({ page }) => {
    await patchConv(page, convId, { archived_at: Math.floor(Date.now() / 1000) });

    await page.goto("/chat");
    await page.waitForTimeout(800);

    // Switch to archived view
    const toggle = page.locator("[data-cy='conv-archive-toggle']");
    await toggle.click();
    await page.waitForTimeout(600);

    const item = page.locator(`[role="option"]:has-text("ui-archive-")`).first();
    await expect(item).toBeVisible({ timeout: 8000 });

    await item.hover();
    const unarchiveBtn = item.locator("button[title='Unarchive conversation']");
    await expect(unarchiveBtn).toBeVisible();
    await unarchiveBtn.click();
    await page.waitForTimeout(800);

    // Should switch back to main list view
    await expect(toggle).toContainText("Archived chats");

    // Item should appear in main list
    await expect(page.locator(`[role="option"]:has-text("ui-archive-")`)).toBeVisible({ timeout: 8000 });
  });

  test("Back button exits archived view", async ({ page }) => {
    await page.goto("/chat");
    await page.waitForTimeout(800);

    const toggle = page.locator("[data-cy='conv-archive-toggle']");
    await toggle.click();
    await page.waitForTimeout(400);
    await expect(toggle).toContainText("← Back");

    await toggle.click();
    await page.waitForTimeout(400);
    await expect(toggle).toContainText("Archived chats");
  });
});

// ---------------------------------------------------------------------------
// Group 5: UI — recency buckets
// ---------------------------------------------------------------------------

test.describe("recency buckets UI", () => {
  let convId: string;
  let gatewayId: string;

  test.beforeEach(async ({ page }) => {
    const gw = await getGatewayId(page);
    expect(gw, "need at least one gateway").toBeTruthy();
    gatewayId = gw!;
    convId = await createConv(page, gatewayId, "bucket-today-" + Date.now());
    await setChatGateway(page, gatewayId);
  });

  test.afterEach(async ({ page }) => {
    if (convId) await deleteConv(page, convId);
  });

  test("Today bucket appears for a newly created conversation", async ({ page }) => {
    await page.goto("/chat");
    await page.waitForTimeout(800);

    // Today bucket label should be present
    const todayLabel = page.locator("[class*='conv-bucket-label']").filter({ hasText: "Today" });
    await expect(todayLabel).toBeVisible({ timeout: 8000 });

    // The newly created conversation should be visible under it
    await expect(page.locator(`[role="option"]:has-text("bucket-today-")`).first()).toBeVisible();
  });
});
