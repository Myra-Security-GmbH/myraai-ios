/**
 * playwright.docker.sequential.config.ts — Sequential pass for tests that use
 * deleteAllConversations(page, timestamp).
 *
 * These tests bulk-delete conversations by wall-clock timestamp.  Running them
 * concurrently causes one file's afterEach cleanup to delete another file's
 * in-progress fixtures.  workers:1 serialises them so only one file runs at a time.
 *
 * This config is invoked automatically by run-e2e.sh after the parallel pass
 * (playwright.docker.config.ts) completes.  Do not invoke it directly unless
 * you are running a subset of sequential tests.
 */

import { defineConfig, devices } from "@playwright/test";
import path from "path";
import { SEQUENTIAL_TESTS } from "./playwright.docker.config";

const SESSION = path.resolve(__dirname, "tests/.auth/docker-session.json");

process.env.PLAYWRIGHT_ADMIN_URL   = "https://ai-api-admin.myra.eu";
process.env.PLAYWRIGHT_BASE_URL    = process.env.PLAYWRIGHT_BASE_URL ?? "https://ai.myra.eu";
process.env.PLAYWRIGHT_GATEWAY_URL = "https://ai-api.myra.eu";

export default defineConfig({
  testDir: "./tests",
  timeout: 30000,
  retries: process.env.CI ? 1 : 0,
  workers: 1,
  reporter: [["./reporters/progress.ts"], ["html", { open: "never" }]],

  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL ?? "https://ai.myra.eu",
    headless: true,
    screenshot: "only-on-failure",
    video: "off",
  },

  projects: [
    // Reuse the session written by the parallel pass — no need to re-authenticate.
    {
      name: "docker-sequential",
      testMatch: SEQUENTIAL_TESTS,
      use: { ...devices["Desktop Chrome"], storageState: SESSION },
    },
  ],
});
