/**
 * reporters/progress.ts — Compact Playwright progress-bar reporter.
 *
 * Shows a single updating line:
 *   [42/542] ████████░░░░░░░░░░░░ 8%   ✓ 41   ✘ 1
 *
 * Failures are printed immediately below the bar as they occur.
 * A full summary is printed at the end.
 */

import type {
  Reporter,
  FullConfig,
  Suite,
  TestCase,
  TestResult,
  FullResult,
  TestError,
} from "@playwright/test/reporter";

const WIDTH = 28; // bar character width

function bar(done: number, total: number): string {
  const pct = total === 0 ? 100 : Math.round((done / total) * 100);
  const filled = total === 0 ? WIDTH : Math.min(WIDTH, Math.max(0, Math.round((done / total) * WIDTH)));
  return "█".repeat(filled) + "░".repeat(WIDTH - filled) + ` ${String(pct).padStart(3)}%`;
}

function formatError(test: TestCase, result: TestResult): string {
  const title = test.titlePath().slice(1).join(" › "); // skip file root
  const file = test.location.file.replace(/.*\/tests\//, "tests/");
  const lines: string[] = [
    ``,
    `  \x1b[31m✘ FAILED\x1b[0m  ${file}:${test.location.line}`,
    `           ${title}`,
  ];
  for (const err of result.errors) {
    const msg = formatTestError(err);
    if (msg) lines.push(``, ...msg.split("\n").map((l) => `    ${l}`));
  }
  lines.push("");
  return lines.join("\n");
}

function formatTestError(err: TestError): string {
  const parts: string[] = [];
  if (err.message) parts.push(err.message.split("\n").slice(0, 6).join("\n"));
  if (err.snippet) parts.push(err.snippet);
  return parts.join("\n");
}

class ProgressReporter implements Reporter {
  private total = 0;
  private done = 0;
  private passed = 0;
  private failed = 0;
  private flaky = 0;
  private skipped = 0;
  /** Tracks test titles that already failed once (for flaky detection) */
  private failedTitles = new Set<string>();
  /** Whether a progress line is currently on stdout (needs \r to overwrite) */
  private lineActive = false;

  onBegin(_config: FullConfig, suite: Suite): void {
    this.total = suite.allTests().length;
    process.stdout.write(`\nRunning ${this.total} tests\n\n`);
    this.renderBar();
  }

  onTestEnd(test: TestCase, result: TestResult): void {
    this.done++;

    const isRetry = result.retry > 0;
    const title = test.titlePath().join(" › ");

    if (result.status === "passed") {
      if (isRetry && this.failedTitles.has(title)) {
        // Previously failed, now passed → flaky
        this.failed--;
        this.flaky++;
        this.failedTitles.delete(title);
      } else {
        this.passed++;
      }
    } else if (result.status === "skipped") {
      this.skipped++;
    } else {
      // failed or timedOut
      if (!isRetry) {
        this.failed++;
        this.failedTitles.add(title);
      }
      // On retry it's still counted as failed until it passes
    }

    // Print failure detail — clear bar line first
    const isFinalAttempt =
      result.status !== "passed" &&
      result.status !== "skipped" &&
      result.retry >= (test.retries ?? 0);

    if (isFinalAttempt) {
      if (this.lineActive) {
        process.stdout.write("\r" + " ".repeat(this.lineActive ? 60 : 0) + "\r");
        this.lineActive = false;
      }
      process.stdout.write(formatError(test, result));
    }

    this.renderBar();
  }

  onEnd(result: FullResult): void {
    // Final newlines after bar
    process.stdout.write("\n\n");

    const duration = Math.round(result.duration / 1000);
    const mins = Math.floor(duration / 60);
    const secs = duration % 60;
    const timeStr = mins > 0 ? `${mins}m ${secs}s` : `${secs}s`;

    const parts: string[] = [];
    if (this.passed)  parts.push(`\x1b[32m${this.passed} passed\x1b[0m`);
    if (this.flaky)   parts.push(`\x1b[33m${this.flaky} flaky\x1b[0m`);
    if (this.failed)  parts.push(`\x1b[31m${this.failed} failed\x1b[0m`);
    if (this.skipped) parts.push(`${this.skipped} skipped`);

    process.stdout.write(`  ${parts.join("  ")}  (${timeStr})\n\n`);
  }

  private renderBar(): void {
    const b = bar(this.done, this.total);
    const pass = `\x1b[32m✓ ${this.passed}\x1b[0m`;
    const fail = this.failed > 0 ? `\x1b[31m✘ ${this.failed}\x1b[0m` : `✘ 0`;
    const flaky = this.flaky > 0 ? `\x1b[33m~ ${this.flaky}\x1b[0m` : "";
    const extra = [pass, fail, flaky].filter(Boolean).join("   ");
    const line = `  [${this.done}/${this.total}] ${b}   ${extra}`;
    process.stdout.write(`\r${line}`);
    this.lineActive = true;
  }
}

export default ProgressReporter;
