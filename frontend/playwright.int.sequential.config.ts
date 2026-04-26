/**
 * playwright.int.sequential.config.ts — Sequential pass for int environment.
 * Mirrors playwright.docker.sequential.config.ts but uses int hostnames.
 */

import { defineConfig, devices } from "@playwright/test";
import path from "path";
import { SEQUENTIAL_TESTS_INT } from "./playwright.int.config";

const SESSION = path.resolve(__dirname, "tests/.auth/docker-session.json");

process.env.PLAYWRIGHT_ADMIN_URL   = "https://ai-api-admin-int.myra.eu";
process.env.PLAYWRIGHT_BASE_URL    = process.env.PLAYWRIGHT_BASE_URL ?? "https://ai-int.myra.eu";
process.env.PLAYWRIGHT_GATEWAY_URL = "https://ai-api-int.myra.eu";

export default defineConfig({
  testDir: "./tests",
  timeout: 30000,
  retries: process.env.CI ? 1 : 0,
  workers: 1,
  reporter: [["./reporters/progress.ts"], ["html", { open: "never" }]],

  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL ?? "https://ai-int.myra.eu",
    headless: true,
    screenshot: "only-on-failure",
    video: "off",
  },

  projects: [
    {
      name: "int-sequential",
      testMatch: SEQUENTIAL_TESTS_INT,
      use: { ...devices["Desktop Chrome"], storageState: SESSION },
    },
  ],
});
