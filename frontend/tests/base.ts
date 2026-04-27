/**
 * base.ts — Custom test fixture that routes each parallel worker to its own
 * pre-authenticated session (worker-{i}-session.json).
 *
 * Usage: import { test, expect } from "./base";   (instead of @playwright/test)
 *
 * Workers are created by workers.setup.ts (one per Playwright parallel slot,
 * mod NUM_WORKERS).  This keeps each worker's conversation/project namespace
 * isolated so cleanup never touches another worker's in-flight fixtures.
 */

import { test as base, expect } from "@playwright/test";
import type {
  Page, Browser, BrowserContext, APIRequestContext,
  Route, Download, Locator, Request,
} from "@playwright/test";
import path from "path";
import fs from "fs";

const NUM_WORKERS = 10;
const AUTH_DIR    = path.resolve(__dirname, ".auth");

interface WorkerMeta {
  tenantId:    string;
  gatewayId:   string;
  gatewaySlug: string;
}

function loadMeta(i: number): WorkerMeta {
  const p = path.join(AUTH_DIR, `worker-${i}-meta.json`);
  if (!fs.existsSync(p)) throw new Error(`worker-${i}-meta.json missing — run workers.setup.ts first`);
  return JSON.parse(fs.readFileSync(p, "utf8")) as WorkerMeta;
}

export const test = base.extend<{ workerSuffix: string; workerTenantId: string; workerGatewayId: string; workerGatewaySlug: string }>({
  storageState: async ({}, use, workerInfo) => {
    const i = workerInfo.parallelIndex % NUM_WORKERS;
    await use(path.join(AUTH_DIR, `worker-${i}-session.json`));
  },
  // Auto-acknowledge the first-run AI disclosure modal so it doesn't intercept
  // clicks in any UI test. The modal is verified by its own dedicated test.
  context: async ({ context }, use) => {
    await context.addInitScript(() => {
      try { localStorage.setItem("aig:ai-disclosure-acknowledged-v1", "1"); } catch {}
    });
    await use(context);
  },
  // Unique prefix for test data created in parallel; use to avoid cross-worker collisions.
  // Example: const name = `gw-${workerSuffix}-${Date.now()}`;
  workerSuffix: async ({}, use, workerInfo) => {
    await use(`w${workerInfo.parallelIndex}`);
  },
  // ID of e2e-tenant-{i} — the worker's isolated test tenant.
  workerTenantId: async ({}, use, workerInfo) => {
    const i = workerInfo.parallelIndex % NUM_WORKERS;
    await use(loadMeta(i).tenantId);
  },
  // ID of e2e-gateway-{i} — the worker's isolated test gateway.
  workerGatewayId: async ({}, use, workerInfo) => {
    const i = workerInfo.parallelIndex % NUM_WORKERS;
    await use(loadMeta(i).gatewayId);
  },
  // Slug of e2e-gateway-{i} — e.g. "e2e-gateway-3".
  workerGatewaySlug: async ({}, use, workerInfo) => {
    const i = workerInfo.parallelIndex % NUM_WORKERS;
    await use(loadMeta(i).gatewaySlug);
  },
});

export { expect };
export type { Page, Browser, BrowserContext, APIRequestContext, Route, Download, Locator, Request };
