import type { Page } from "@playwright/test";

export const ADMIN_BASE =
  (process.env.PLAYWRIGHT_ADMIN_URL ?? "https://ai-api-admin.myra.eu") + "/admin/v1";

/**
 * Delete specific conversation IDs.
 * Logs a warning for any non-2xx response so orphaned rows are visible in CI output
 * rather than silently accumulating in the database.
 */
export async function deleteConversations(page: Page, ids: string[]): Promise<void> {
  if (ids.length === 0) return;
  const results = await Promise.allSettled(
    ids.map(id => page.request.delete(`${ADMIN_BASE}/conversations/${id}`)),
  );
  for (let i = 0; i < results.length; i++) {
    const r = results[i];
    if (r.status === "rejected") {
      console.warn(`[cleanup] DELETE conversation ${ids[i]} threw: ${r.reason}`);
    } else if (!r.value.ok()) {
      console.warn(`[cleanup] DELETE conversation ${ids[i]} returned ${r.value.status()}`);
    }
  }
}

/**
 * Extract the current conversation ID from the page URL (?conv=<uuid>).
 *
 * NOTE: only reliable immediately after a conversation is created or navigated to.
 * If the test navigates away before afterEach runs, the ID will be lost.
 * Prefer capturing the ID at creation time by pushing directly into convIds:
 *
 *   await page.waitForURL(/[?&]conv=/, { timeout: 5000 });
 *   const id = new URL(page.url()).searchParams.get("conv");
 *   if (id) convIds.push(id);
 */
export function captureConvId(page: Page): string | null {
  try { return new URL(page.url()).searchParams.get("conv"); }
  catch { return null; }
}

/**
 * Returns a helper that tracks conversation IDs created during a test and
 * cleans them up at the end.  Captures IDs immediately at push-time so cleanup
 * is not dependent on the URL still showing the right ?conv= param in afterEach.
 *
 * Usage:
 *   const tracker = makeConvTracker(page);
 *   // after creating a conversation:
 *   tracker.push(new URL(page.url()).searchParams.get("conv")!);
 *   // in afterEach:
 *   await tracker.cleanup();
 */
export function makeConvTracker(page: Page) {
  const ids: string[] = [];
  return {
    push(id: string | null | undefined) {
      if (id) ids.push(id);
    },
    pushFromUrl() {
      const id = captureConvId(page);
      if (id) ids.push(id);
    },
    async cleanup() {
      await deleteConversations(page, [...ids]);
      ids.length = 0;
    },
  };
}
