/**
 * playwright.docker.config.ts — Run e2e tests against the live Docker stack.
 *
 * Usage:
 *   PLAYWRIGHT_BASE_URL=https://ai.myra.eu npx playwright test --config playwright.docker.config.ts
 */

import { defineConfig, devices } from "@playwright/test";
import path from "path";

const SESSION = path.resolve(__dirname, "tests/.auth/docker-session.json");

// Make the admin API base URL available to test files
process.env.PLAYWRIGHT_ADMIN_URL = "https://ai-api-admin.myra.eu";

export default defineConfig({
  testDir: "./tests",
  timeout: 30000,
  retries: 1,
  workers: 1,
  reporter: [["list"], ["html", { open: "never" }]],

  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL ?? "https://ai.myra.eu",
    headless: true,
    screenshot: "only-on-failure",
    video: "off",
  },

  projects: [
    // Auth setup — inserts OTP into MySQL, saves session
    {
      name: "docker-setup",
      testMatch: "**/auth.docker.setup.ts",
      use: { ...devices["Desktop Chrome"] },
    },

    // All tests except those that require SQLite direct access or local Vite proxy
    {
      name: "docker",
      dependencies: ["docker-setup"],
      testIgnore: [
        "**/auth.setup.ts",
        "**/auth.docker.setup.ts",
        "**/permissions.setup.ts",
        "**/permissions.teardown.ts",
        "**/tenant-scoping.spec.ts",
        "**/tenant-admin-scoping.spec.ts",
        "**/login.spec.ts",
        "**/input-perf.spec.ts",
      ],
      use: { ...devices["Desktop Chrome"], storageState: SESSION },
    },

    // Screenshots — authenticated, wider viewport, 2× DPI
    {
      name: "screenshots",
      dependencies: ["docker-setup"],
      testMatch: "**/screenshots.spec.ts",
      use: {
        ...devices["Desktop Chrome"],
        storageState: SESSION,
        viewport: { width: 1440, height: 900 },
        deviceScaleFactor: 2,
      },
    },
  ],
});
