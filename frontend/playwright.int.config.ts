/**
 * playwright.int.config.ts — Run e2e tests against the integration (int) environment.
 *
 * Mirrors playwright.docker.config.ts but points to int hostnames.
 * Int DB credentials for workers.setup.ts are passed via env vars:
 *   E2E_DB_USER=gateway_int  E2E_DB_PASS=<from .env.integration>  E2E_DB_NAME=ai_gateway_int
 *
 * Usage:
 *   ./run-e2e.sh --config playwright.int.config.ts
 *   ./run-e2e.sh tests/<feature>.spec.ts --config playwright.int.config.ts
 */

import { defineConfig, devices } from "@playwright/test";
import path from "path";

const SESSION = path.resolve(__dirname, "tests/.auth/docker-session.json");

process.env.PLAYWRIGHT_ADMIN_URL   = "https://ai-api-admin-int.myra.eu";
process.env.PLAYWRIGHT_BASE_URL    = process.env.PLAYWRIGHT_BASE_URL ?? "https://ai-int.myra.eu";
process.env.PLAYWRIGHT_GATEWAY_URL = "https://ai-api-int.myra.eu";

// Tests with genuine resource/state conflicts — cannot run in parallel even with
// per-worker data isolation.  All cleanup-based tests are now parallel-safe.
export const SEQUENTIAL_TESTS_INT = [
  "**/chat-tool-matrix.spec.ts",
  "**/chat-project-read-commands.spec.ts",
  "**/chat-preset-switch.spec.ts",
  "**/css-rendering.spec.ts",
  "**/css-pdf-quality.spec.ts",
  "**/email-delivery.spec.ts",
  "**/chat-anthropic-caching.spec.ts",
];

export default defineConfig({
  testDir: "./tests",
  timeout: 30000,
  retries: process.env.CI ? 1 : 0,
  workers: 16,
  reporter: [["./reporters/progress.ts"], ["html", { open: "never" }]],

  use: {
    baseURL: process.env.PLAYWRIGHT_BASE_URL ?? "https://ai-int.myra.eu",
    headless: true,
    screenshot: "only-on-failure",
    video: "off",
  },

  projects: [
    // 1. Auth setup
    {
      name: "int-setup",
      testMatch: "**/auth.int.setup.ts",
      use: { ...devices["Desktop Chrome"] },
    },

    // 2. Worker users setup — creates 10 admin users + per-worker sessions
    {
      name: "int-workers-setup",
      testMatch: "**/workers.setup.ts",
      dependencies: ["int-setup"],
      teardown: "int-workers-teardown",
      use: {
        ...devices["Desktop Chrome"],
        baseURL: process.env.PLAYWRIGHT_BASE_URL ?? "https://ai-int.myra.eu",
      },
    },

    // 3. Workers teardown
    {
      name: "int-workers-teardown",
      testMatch: "**/workers.teardown.ts",
      use: { ...devices["Desktop Chrome"] },
    },

    // 4. Permissions setup
    {
      name: "int-permissions-setup",
      testMatch: "**/permissions.int.setup.ts",
      dependencies: ["int-setup"],
      use: { ...devices["Desktop Chrome"] },
    },

    // 5. Parallel tests — each worker uses its own session (./base fixture)
    {
      name: "int",
      dependencies: ["int-setup", "int-workers-setup", "int-permissions-setup"],
      testIgnore: [
        "**/auth.setup.ts",
        "**/auth.docker.setup.ts",
        "**/auth.int.setup.ts",
        "**/workers.setup.ts",
        "**/workers.teardown.ts",
        "**/permissions.setup.ts",
        "**/permissions.docker.setup.ts",
        "**/permissions.int.setup.ts",
        "**/permissions.teardown.ts",
        "**/tenant-scoping.spec.ts",
        "**/tenant-admin-scoping.spec.ts",
        "**/login.spec.ts",
        "**/input-perf.spec.ts",
        ...SEQUENTIAL_TESTS_INT,
      ],
      use: { ...devices["Desktop Chrome"], storageState: SESSION },
    },

    // 6. Screenshots
    {
      name: "int-screenshots",
      dependencies: ["int-setup"],
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
