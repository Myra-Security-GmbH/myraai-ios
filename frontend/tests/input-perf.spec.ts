/**
 * input-perf.spec.ts — measures keystroke-to-DOM latency on input fields.
 *
 * Methodology: press each key individually via keyboard.press(), measure the
 * wall-clock time from before the first keypress to after all characters have
 * appeared in the DOM. Reports ms/character average.
 *
 * Run with:
 *   cd frontend && npx playwright test tests/input-perf.spec.ts --project=chromium --reporter=list
 */

import { test, expect } from "@playwright/test";

test.use({ storageState: { cookies: [], origins: [] } });

/** Type `text` one key at a time; return total wall-clock ms. */
async function measureTyping(page: any, locator: any, text: string): Promise<number> {
  await locator.focus();
  const t0 = Date.now();
  for (const ch of text) {
    await page.keyboard.press(ch === " " ? "Space" : ch);
    // Wait until the character is reflected in the DOM value
    await page.waitForFunction(
      ({ sel, expected }: { sel: string; expected: number }) => {
        const el = document.querySelector(sel) as HTMLInputElement | null;
        return el ? el.value.length >= expected : false;
      },
      { sel: `#${(await locator.getAttribute("id"))}`, expected: (await locator.inputValue()).length },
      { timeout: 5000 }
    );
  }
  return Date.now() - t0;
}

test.describe("input field keystroke latency", () => {

  test("email input on login page", async ({ page }) => {
    await page.goto("/login");
    await page.getByText("Continue with Email code").click();

    const input = page.getByLabel("Email address");
    await expect(input).toBeVisible();
    await input.focus();

    const testString = "admin@example.com";
    const t0 = Date.now();
    for (const ch of testString) {
      await page.keyboard.type(ch, { delay: 0 });
    }
    // Wait until full value is in the DOM
    await expect(input).toHaveValue(testString, { timeout: 30000 });
    const elapsed = Date.now() - t0;
    const msPerChar = elapsed / testString.length;

    console.log(`\n[email input] total=${elapsed}ms  chars=${testString.length}  avg=${msPerChar.toFixed(1)}ms/char`);

    // Fail loudly if typing is pathologically slow (>200ms per character)
    expect(msPerChar, `email input: ${msPerChar.toFixed(1)}ms/char — expected <200ms`).toBeLessThan(200);
  });

  test("OTP code input on login page", async ({ page }) => {
    // Intercept the OTP request so we don't need a real email
    await page.route("**/admin/auth/otp/request", route =>
      route.fulfill({ status: 200, contentType: "application/json",
                      body: JSON.stringify({ message: "Code sent (intercepted)" }) })
    );

    await page.goto("/login");
    await page.getByText("Continue with Email code").click();
    await page.getByLabel("Email address").fill("admin@example.com");
    await page.getByRole("button", { name: "Send code" }).click();

    const input = page.getByLabel("6-digit code");
    await expect(input).toBeVisible({ timeout: 5000 });
    await input.focus();

    const testString = "123456";
    const t0 = Date.now();
    for (const ch of testString) {
      await page.keyboard.type(ch, { delay: 0 });
    }
    await expect(input).toHaveValue(testString, { timeout: 30000 });
    const elapsed = Date.now() - t0;
    const msPerChar = elapsed / testString.length;

    console.log(`\n[OTP input]   total=${elapsed}ms  chars=${testString.length}  avg=${msPerChar.toFixed(1)}ms/char`);

    expect(msPerChar, `OTP input: ${msPerChar.toFixed(1)}ms/char — expected <200ms`).toBeLessThan(200);
  });

  test("per-keystroke breakdown on OTP input", async ({ page }) => {
    await page.route("**/admin/auth/otp/request", route =>
      route.fulfill({ status: 200, contentType: "application/json",
                      body: JSON.stringify({ message: "Code sent (intercepted)" }) })
    );

    await page.goto("/login");
    await page.getByText("Continue with Email code").click();
    await page.getByLabel("Email address").fill("admin@example.com");
    await page.getByRole("button", { name: "Send code" }).click();

    const input = page.getByLabel("6-digit code");
    await expect(input).toBeVisible({ timeout: 5000 });
    await input.focus();

    const digits = ["1", "2", "3", "4", "5", "6"];
    const timings: number[] = [];

    for (let i = 0; i < digits.length; i++) {
      const expected = i + 1;
      const t0 = Date.now();
      await page.keyboard.type(digits[i], { delay: 0 });
      await expect(input).toHaveValue(digits.slice(0, expected).join(""), { timeout: 10000 });
      timings.push(Date.now() - t0);
    }

    console.log("\n[per-keystroke OTP timings]");
    timings.forEach((ms, i) => console.log(`  digit ${i + 1}: ${ms}ms`));
    console.log(`  min=${Math.min(...timings)}ms  max=${Math.max(...timings)}ms  avg=${(timings.reduce((a,b)=>a+b,0)/timings.length).toFixed(1)}ms`);

    // Every individual keystroke should reflect in under 1 second
    for (const ms of timings) {
      expect(ms, `a single keypress took ${ms}ms`).toBeLessThan(1000);
    }
  });
});
