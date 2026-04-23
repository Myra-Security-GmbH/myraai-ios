/**
 * playwright.int.config.ts — Run e2e tests against the integration (int) environment.
 *
 * Mirrors playwright.docker.config.ts but points to int hostnames.
 * Usage:
 *   ./run-e2e.sh --config playwright.int.config.ts
 *   ./run-e2e.sh tests/<feature>.spec.ts --config playwright.int.config.ts
 */

import { defineConfig, devices } from "@playwright/test";
import path from "path";

const SESSION = path.resolve(__dirname, "tests/.auth/int-session.json");

process.env.PLAYWRIGHT_ADMIN_URL   = "https://ai-api-admin-int.myra.eu";
process.env.PLAYWRIGHT_BASE_URL    = process.env.PLAYWRIGHT_BASE_URL ?? "https://ai-int.myra.eu";
process.env.PLAYWRIGHT_GATEWAY_URL = "https://ai-api-int.myra.eu";

export const SEQUENTIAL_TESTS_INT = [
  "**/chat.spec.ts",
  "**/chat-autotitle.spec.ts",
  "**/chat-autotitle-presets.spec.ts",
  "**/chat-docx.spec.ts",
  "**/chat-docx-qwen.spec.ts",
  "**/chat-anthropic-caching.spec.ts",
  "**/chat-image-qwen.spec.ts",
  "**/chat-long-response.spec.ts",
  "**/chat-ods.spec.ts",
  "**/chat-pdf-qwen.spec.ts",
  "**/chat-pptx.spec.ts",
  "**/chat-qwen3-a3b.spec.ts",
  "**/chat-summarize.spec.ts",
  "**/chat-web-search.spec.ts",
  "**/chat-xlsx.spec.ts",
  "**/chat-tool-matrix.spec.ts",
  "**/chat-project-read-commands.spec.ts",
  "**/chat-preset-switch.spec.ts",
  "**/chat-pdf-export.spec.ts",
  "**/chat-sonnet-format.spec.ts",
  "**/chat-artifact-panel.spec.ts",
  "**/css-rendering.spec.ts",
  "**/css-pdf-quality.spec.ts",
  "**/email-delivery.spec.ts",
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
    {
      name: "int-setup",
      testMatch: "**/auth.int.setup.ts",
      use: { ...devices["Desktop Chrome"] },
    },

    {
      name: "int-permissions-setup",
      testMatch: "**/permissions.int.setup.ts",
      dependencies: ["int-setup"],
      use: { ...devices["Desktop Chrome"] },
    },

    {
      name: "int",
      dependencies: ["int-setup", "int-permissions-setup"],
      testIgnore: [
        "**/auth.setup.ts",
        "**/auth.docker.setup.ts",
        "**/auth.int.setup.ts",
        "**/permissions.setup.ts",
        "**/permissions.docker.setup.ts",
        "**/permissions.int.setup.ts",
        "**/permissions.teardown.ts",
        "**/tenant-scoping.spec.ts",
        "**/tenant-admin-scoping.spec.ts",
        "**/login.spec.ts",
        "**/input-perf.spec.ts",
        // Requires live Anthropic provider credentials (provider_config not present on int)
        "**/chat-anthropic-think-tag.spec.ts",
        ...SEQUENTIAL_TESTS_INT,
      ],
      use: { ...devices["Desktop Chrome"], storageState: SESSION },
    },

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
