/**
 * playwright.docker.config.ts — Run e2e tests against the live Docker stack.
 *
 * Parallelism strategy (workers: 4):
 *   "docker" project    — safe to parallelise; runs up to 4 files at once.
 *   "docker-sequential" — files that use deleteAllConversations(page, timestamp)
 *                         for cleanup; bulk-deletes by timestamp are unsafe across
 *                         concurrent workers because one file's cleanup deletes
 *                         another file's in-progress fixtures.  These files run
 *                         after "docker" completes and are forced onto a single
 *                         worker via workers:1 in playwright.docker.sequential.config.ts
 *                         (run-e2e.sh executes both configs in order).
 *
 * Usage (via run-e2e.sh — preferred):
 *   ./run-e2e.sh --config playwright.docker.config.ts
 *
 * Direct usage (parallel pass only):
 *   npx playwright test --config playwright.docker.config.ts
 */

import { defineConfig, devices } from "@playwright/test";
import path from "path";

const SESSION = path.resolve(__dirname, "tests/.auth/docker-session.json");

// Make base URLs available to test files
process.env.PLAYWRIGHT_ADMIN_URL = "https://ai-api-admin.myra.eu";
process.env.PLAYWRIGHT_BASE_URL = process.env.PLAYWRIGHT_BASE_URL ?? "https://ai.myra.eu";

// These files use deleteAllConversations(page, timestamp) which bulk-deletes by
// wall-clock time.  Running them concurrently causes cross-file fixture deletion.
// They are excluded here and run sequentially by playwright.docker.sequential.config.ts.
export const SEQUENTIAL_TESTS = [
  "**/chat.spec.ts",
  "**/chat-autotitle.spec.ts",
  "**/chat-autotitle-presets.spec.ts",
  "**/chat-docx.spec.ts",
  "**/chat-docx-qwen.spec.ts",
  "**/chat-image-qwen.spec.ts",
  "**/chat-long-response.spec.ts",
  "**/chat-ods.spec.ts",
  "**/chat-pdf-qwen.spec.ts",
  "**/chat-pptx.spec.ts",
  "**/chat-qwen3-a3b.spec.ts",
  "**/chat-summarize.spec.ts",
  "**/chat-web-search.spec.ts",
  "**/chat-xlsx.spec.ts",
  // Full permutation matrix: real inference across all model/PII/tool combinations.
  "**/chat-tool-matrix.spec.ts",
  // Contains real-inference Suite B (vllm); fails under parallel load from 16 workers.
  "**/chat-project-read-commands.spec.ts",
  // Creates conversations + checks sidebar auto-title; sidebar state conflicts with parallel workers.
  "**/chat-preset-switch.spec.ts",
  // Uses deleteAllConversations in afterEach (UI suite) and runs a long inference flow.
  "**/chat-pdf-export.spec.ts",
  // Uses deleteAllConversations; real-inference tests for response formatting regressions.
  "**/chat-sonnet-format.spec.ts",
  // Creates a project fixture and mutates localStorage for dark-mode testing.
  "**/css-rendering.spec.ts",
  // Runs docker exec for pymupdf geometry analysis; not safe to parallelise.
  "**/css-pdf-quality.spec.ts",
];

export default defineConfig({
  testDir: "./tests",
  timeout: 30000,
  retries: process.env.CI ? 1 : 0,
  workers: 16,
  reporter: [["./reporters/progress.ts"], ["html", { open: "never" }]],

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

    // Permissions setup — creates isolated tenant/gateway/user fixtures + member session
    {
      name: "permissions-setup",
      testMatch: "**/permissions.docker.setup.ts",
      dependencies: ["docker-setup"],
      use: { ...devices["Desktop Chrome"] },
    },

    // Parallel-safe tests — up to 16 files run concurrently
    {
      name: "docker",
      dependencies: ["docker-setup", "permissions-setup"],
      testIgnore: [
        "**/auth.setup.ts",
        "**/auth.docker.setup.ts",
        "**/permissions.setup.ts",
        "**/permissions.docker.setup.ts",
        "**/permissions.teardown.ts",
        "**/tenant-scoping.spec.ts",
        "**/tenant-admin-scoping.spec.ts",
        "**/login.spec.ts",
        "**/input-perf.spec.ts",
        // Sequential tests — run separately via playwright.docker.sequential.config.ts
        ...SEQUENTIAL_TESTS,
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
