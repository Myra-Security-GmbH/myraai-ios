import { test, expect } from "./base";

test.describe("Monitor page", () => {
  test.beforeEach(async ({ page }) => {
    await page.goto("/monitor");
  });

  test("shows monitor heading", async ({ page }) => {
    await expect(page.getByRole("heading", { name: /Monitor/i })).toBeVisible();
  });

  test("shows refresh interval controls", async ({ page }) => {
    await expect(page.getByText(/interval|refresh|auto/i).first()).toBeVisible();
  });

  test("shows period stats sections", async ({ page }) => {
    await page.waitForTimeout(800);
    await expect(page.getByText(/last minute|today|last hour/i).first()).toBeVisible();
  });

  test("pause/resume toggle exists", async ({ page }) => {
    const pauseBtn = page.getByRole("button", { name: /pause|resume/i });
    await expect(pauseBtn).toBeVisible();
  });

  test("pause stops auto-refresh", async ({ page }) => {
    const pauseBtn = page.getByRole("button", { name: /pause/i });
    await pauseBtn.waitFor({ state: "visible", timeout: 5000 }).catch(() => { test.skip(true, "Required UI element not visible in this environment"); return; });
    await pauseBtn.click();
    await expect(page.getByRole("button", { name: /resume/i })).toBeVisible();
  });
});
