/**
 * email-delivery.spec.ts — Production smoke test for OTP email delivery.
 *
 * Triggers a login OTP request for a known user and verifies that the
 * sendmail process completed with SMTP status 250 by reading Docker logs.
 *
 * Runs sequentially (docker logs access; not safe to parallelise).
 */

import { test, expect } from "@playwright/test";
import { execSync } from "child_process";

const ADMIN_BASE  = process.env.PLAYWRIGHT_ADMIN_URL ?? "http://localhost:5173";
const CONTAINER   = "ai-gateway-gateway-1";

// A real user that exists in production — used only to trigger an OTP send.
// The code is stored in the DB and never verified by this test.
const TEST_EMAIL  = "sascha@schumann.net";

test.describe("Email delivery — OTP send smoke test", () => {
  test.setTimeout(30_000);

  test("OTP email is delivered via SMTP (smtpstatus=250)", async ({ page }) => {
    // Record time just before the request so we only inspect new log lines.
    const before = new Date();

    // Trigger the OTP request.
    const resp = await page.context().request.post(
      `${ADMIN_BASE}/admin/auth/otp/request`,
      { data: { email: TEST_EMAIL } },
    );
    expect(resp.ok(), `POST /admin/auth/otp/request: ${await resp.text()}`).toBeTruthy();

    // Give the async Lua timer (ngx.timer.at) a moment to fire and call sendmail.
    await page.waitForTimeout(5_000);

    // Read Docker logs only from after the OTP request was sent.
    // --since accepts a Unix timestamp (seconds).
    const sinceTs = Math.floor(before.getTime() / 1000);
    let afterLines: string;
    try {
      afterLines = execSync(
        `docker logs ${CONTAINER} --since ${sinceTs} 2>&1`,
        { timeout: 10_000 },
      ).toString();
    } catch (e) {
      throw new Error(`Failed to read Docker logs: ${e}`);
    }

    // Find the msmtp delivery summary line for our email.
    // email.lua forwards the msmtp log line via nginx: "email: msmtp: ... smtpstatus=250 ..."
    // Fallback: direct msmtp log "log info was: ... smtpstatus=250 ..."
    const deliveryLine = afterLines
      .split("\n")
      .find((l) => l.includes("smtpstatus=") && l.includes(TEST_EMAIL))
      ?? afterLines
        .split("\n")
        .find((l) => l.includes("smtpstatus=") && l.includes("noreply@myra.eu"));

    expect(
      deliveryLine,
      `No msmtp delivery log line found for ${TEST_EMAIL} after the OTP request.\n` +
        `This means either sendmail was not invoked or the relay rejected the message.\n` +
        `Recent Docker logs (last 50 lines):\n` +
        afterLines.split("\n").slice(-50).join("\n"),
    ).toBeTruthy();

    // Extract and assert the SMTP status code.
    const statusMatch = deliveryLine!.match(/smtpstatus=(\d+)/);
    expect(
      statusMatch,
      `Could not parse smtpstatus from delivery line:\n${deliveryLine}`,
    ).toBeTruthy();

    const smtpStatus = parseInt(statusMatch![1], 10);
    expect(
      smtpStatus,
      `Expected SMTP 250 (accepted) but got ${smtpStatus}.\n` +
        `Delivery line: ${deliveryLine}\n` +
        `Check that the SMTP relay is reachable and the sender IP is not banned.`,
    ).toBe(250);

    // Also assert the Lua-level "sent ok" log line exists.
    const sentOkLine = afterLines
      .split("\n")
      .find((l) => l.includes("email: sent ok") && l.includes(TEST_EMAIL));

    expect(
      sentOkLine,
      `msmtp reported 250 but Lua did not log "sent ok" — check email.lua error handling.\n` +
        `Delivery line: ${deliveryLine}`,
    ).toBeTruthy();
  });
});
