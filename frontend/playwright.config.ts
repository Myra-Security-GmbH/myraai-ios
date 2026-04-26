import { defineConfig, devices } from "@playwright/test";
import path from "path";

const SESSION              = path.resolve(__dirname, "tests/.auth/session.json");
const MEMBER_SESSION       = path.resolve(__dirname, "tests/.auth/member-session.json");
const TENANT_ADMIN_SESSION = path.resolve(__dirname, "tests/.auth/tenant-admin-session.json");

export default defineConfig({
  testDir: "./tests",
  timeout: 15000,
  retries: process.env.CI ? 2 : 0,
  workers: 16,
  reporter: [["./reporters/progress.ts"], ["html", { open: "never" }]],

  use: {
    baseURL: "http://localhost:5173",
    headless: true,
    screenshot: "only-on-failure",
    video: "off",
  },

  projects: [
    // 1. Auth setup — logs in once and saves admin session (no storageState)
    {
      name: "setup",
      testMatch: "**/auth.setup.ts",
      use: { ...devices["Desktop Chrome"] },
    },
    // 2. Worker users setup — creates 10 per-worker sessions (uses local ai_gateway DB)
    {
      name: "workers-setup",
      testMatch: "**/workers.setup.ts",
      dependencies: ["setup"],
      teardown: "workers-teardown",
      use: { ...devices["Desktop Chrome"] },
    },
    // 3. Workers teardown
    {
      name: "workers-teardown",
      testMatch: "**/workers.teardown.ts",
      use: { ...devices["Desktop Chrome"] },
    },
    // 4. Permissions setup — creates DB fixtures + member + tenant_admin sessions
    {
      name: "permissions-setup",
      testMatch: "**/permissions.setup.ts",
      dependencies: ["setup"],
      teardown: "permissions-teardown",
      use: { ...devices["Desktop Chrome"] },
    },
    // 5. Login-specific tests — run after setup; tests override storageState inline
    {
      name: "login",
      testMatch: "**/login.spec.ts",
      dependencies: ["setup"],
      use: { ...devices["Desktop Chrome"], storageState: SESSION },
    },
    // 6. Tenant-scoping permission tests — need both sessions
    {
      name: "permissions",
      testMatch: ["**/tenant-scoping.spec.ts", "**/tenant-admin-scoping.spec.ts"],
      dependencies: ["setup", "permissions-setup"],
      use: { ...devices["Desktop Chrome"], storageState: MEMBER_SESSION },
    },
    // 7. Permissions teardown — removes DB fixtures after "permissions" tests finish
    {
      name: "permissions-teardown",
      testMatch: "**/permissions.teardown.ts",
      use: { ...devices["Desktop Chrome"] },
    },
    // 8. All other tests — workers:1 so no parallelism here; admin session as fallback
    {
      name: "chromium",
      testIgnore: [
        "**/auth.setup.ts",
        "**/workers.setup.ts",
        "**/workers.teardown.ts",
        "**/permissions.setup.ts",
        "**/login.spec.ts",
        "**/tenant-scoping.spec.ts",
        "**/tenant-admin-scoping.spec.ts",
      ],
      dependencies: ["setup", "workers-setup"],
      use: { ...devices["Desktop Chrome"], storageState: SESSION },
    },
  ],
});
