/**
 * playwright.production.config.ts — Playwright config for capturing screenshots
 * against the live production instance at https://ai.myra.eu.
 *
 * Usage (from frontend/ directory):
 *   npx playwright test tests/screenshots.spec.ts \
 *     --config playwright.production.config.ts \
 *     --project=chromium
 */

import { defineConfig, devices } from "@playwright/test";
import path from "path";

const SESSION = path.resolve(__dirname, "tests/.auth/production-session.json");

export default defineConfig({
  testDir: "./tests",
  timeout: 30000,
  retries: 1,
  workers: 1,
  reporter: [["list"]],

  use: {
    baseURL: "https://ai.myra.eu",
    headless: true,
    ignoreHTTPSErrors: false,
    screenshot: "only-on-failure",
    video: "off",
  },

  projects: [
    {
      name: "production-setup",
      testMatch: "**/auth.production.setup.ts",
      use: { ...devices["Desktop Chrome"] },
    },
    {
      name: "chromium",
      testMatch: "**/screenshots.spec.ts",
      dependencies: ["production-setup"],
      use: { ...devices["Desktop Chrome"], storageState: SESSION },
    },
  ],
});
