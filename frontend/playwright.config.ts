import { defineConfig, devices } from "@playwright/test";
import path from "path";

const SESSION     = path.resolve(__dirname, "tests/.auth/session.json");
const ORG_SESSION = path.resolve(__dirname, "tests/.auth/org-session.json");

export default defineConfig({
  testDir: "./tests",
  timeout: 15000,
  retries: 1,
  workers: 1,
  reporter: [["list"], ["html", { open: "never" }]],

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
    // 2. Permissions setup — creates DB fixtures + admin_org session
    {
      name: "permissions-setup",
      testMatch: "**/permissions.setup.ts",
      dependencies: ["setup"],
      teardown: "permissions-teardown",
      use: { ...devices["Desktop Chrome"] },
    },
    // 3. Login-specific tests — run after setup; tests override storageState inline
    {
      name: "login",
      testMatch: "**/login.spec.ts",
      dependencies: ["setup"],
      use: { ...devices["Desktop Chrome"], storageState: SESSION },
    },
    // 4. Org-scoping permission tests — need both sessions
    {
      name: "permissions",
      testMatch: "**/org-scoping.spec.ts",
      dependencies: ["setup", "permissions-setup"],
      use: { ...devices["Desktop Chrome"], storageState: ORG_SESSION },
    },
    // 5. Permissions teardown — removes DB fixtures after "permissions" tests finish
    {
      name: "permissions-teardown",
      testMatch: "**/permissions.teardown.ts",
      use: { ...devices["Desktop Chrome"] },
    },
    // 6. All other tests — use the saved admin session
    {
      name: "chromium",
      testIgnore: ["**/auth.setup.ts", "**/permissions.setup.ts", "**/login.spec.ts", "**/org-scoping.spec.ts"],
      dependencies: ["setup"],
      use: { ...devices["Desktop Chrome"], storageState: SESSION },
    },
  ],
});
