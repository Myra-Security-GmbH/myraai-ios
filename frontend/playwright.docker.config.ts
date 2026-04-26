/**
 * playwright.docker.config.ts — Run e2e tests against the live Docker stack.
 *
 * Parallelism strategy (workers: 16):
 *   "docker" project         — safe to parallelise; each worker gets its own
 *                              authenticated session (worker-{i}-session.json) via
 *                              workers.setup.ts so cleanup never touches other workers' data.
 *   "docker-sequential"      — a small set of tests with genuine resource conflicts
 *                              (heavy inference load, docker exec, localStorage mutations)
 *                              that cannot safely run concurrently regardless of data isolation.
 *                              Run after "docker" via playwright.docker.sequential.config.ts.
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
process.env.PLAYWRIGHT_ADMIN_URL   = "https://ai-api-admin.myra.eu";
process.env.PLAYWRIGHT_BASE_URL    = process.env.PLAYWRIGHT_BASE_URL ?? "https://ai.myra.eu";
process.env.PLAYWRIGHT_GATEWAY_URL = "https://ai-api.myra.eu";

// Files with genuine resource/state conflicts that cannot run in parallel even with
// per-worker user isolation.  All other tests (including formerly "sequential" cleanup
// tests) are now safe to parallelise because per-worker sessions isolate their data.
export const SEQUENTIAL_TESTS = [
  // Full permutation matrix: real inference across all model/PII/tool combinations — overloads workers
  "**/chat-tool-matrix.spec.ts",
  // Real-inference Suite B (vllm): fails under parallel inference load from 16 workers
  "**/chat-project-read-commands.spec.ts",
  // Checks sidebar auto-title behaviour; sidebar conversation list is a shared UI region
  "**/chat-preset-switch.spec.ts",
  // Mutates localStorage (dark-mode); conflicts when multiple workers share a browser origin
  "**/css-rendering.spec.ts",
  // Runs docker exec for pymupdf geometry analysis — not safe to parallelise
  "**/css-pdf-quality.spec.ts",
  // Reads Docker container logs to verify SMTP delivery — not safe to parallelise
  "**/email-delivery.spec.ts",
  // Heavy real-inference with response caching; kept sequential conservatively
  "**/chat-anthropic-caching.spec.ts",
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
    // 1. Auth setup — inserts OTP into MySQL, saves admin session
    {
      name: "docker-setup",
      testMatch: "**/auth.docker.setup.ts",
      use: { ...devices["Desktop Chrome"] },
    },

    // 2. Worker users setup — creates 10 admin users + per-worker sessions
    {
      name: "workers-setup",
      testMatch: "**/workers.setup.ts",
      dependencies: ["docker-setup"],
      teardown: "workers-teardown",
      use: {
        ...devices["Desktop Chrome"],
        baseURL: process.env.PLAYWRIGHT_BASE_URL ?? "https://ai.myra.eu",
      },
    },

    // 3. Workers teardown — deletes the 10 e2e worker users after the suite
    {
      name: "workers-teardown",
      testMatch: "**/workers.teardown.ts",
      use: { ...devices["Desktop Chrome"] },
    },

    // 4. Permissions setup — creates isolated tenant/gateway/user fixtures + member session
    {
      name: "permissions-setup",
      testMatch: "**/permissions.docker.setup.ts",
      dependencies: ["docker-setup"],
      use: { ...devices["Desktop Chrome"] },
    },

    // 5. Parallel tests — up to 16 files concurrently; each worker uses its own session
    //    (tests importing from ./base get worker-{i}-session.json automatically)
    {
      name: "docker",
      dependencies: ["docker-setup", "workers-setup", "permissions-setup"],
      testIgnore: [
        "**/auth.setup.ts",
        "**/auth.docker.setup.ts",
        "**/auth.int.setup.ts",
        "**/workers.setup.ts",
        "**/workers.teardown.ts",
        "**/permissions.setup.ts",
        "**/permissions.docker.setup.ts",
        "**/permissions.teardown.ts",
        "**/tenant-scoping.spec.ts",
        "**/tenant-admin-scoping.spec.ts",
        "**/login.spec.ts",
        "**/input-perf.spec.ts",
        // Truly sequential tests — run after this pass via playwright.docker.sequential.config.ts
        ...SEQUENTIAL_TESTS,
      ],
      use: { ...devices["Desktop Chrome"], storageState: SESSION },
    },

    // 6. Screenshots — authenticated, wider viewport, 2× DPI
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

    // 7. UI review — dark + light mode capture
    {
      name: "ui-review",
      dependencies: ["docker-setup"],
      testMatch: "**/ui-review.spec.ts",
      timeout: 180_000,
      use: {
        ...devices["Desktop Chrome"],
        storageState: SESSION,
        viewport: { width: 1440, height: 900 },
        deviceScaleFactor: 2,
      },
    },
  ],
});
