/**
 * reporters/progress.ts — Compact Playwright progress-bar reporter.
 *
 * Shows a single updating bar line:
 *   [42/542] ████████░░░░░░░░░░░░ 8%   ✓ 41   ✘ 1   ~2m 30s left
 *
 * After each test completes, a permanent one-liner scrolls above the bar:
 *   ✓ 1.4s   chat-memory.spec.ts · user memory is injected into system prompt
 *   · 0.0s   chat-memory.spec.ts · memory_disabled suppresses injection  [skipped]
 *
 * Failures are printed in full immediately; a full summary is printed at the end.
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

const BAR_WIDTH = 28;

function bar(done: number, total: number): string {
  const pct = total === 0 ? 100 : Math.round((done / total) * 100);
  const filled = total === 0 ? BAR_WIDTH : Math.min(BAR_WIDTH, Math.max(0, Math.round((done / total) * BAR_WIDTH)));
  return "█".repeat(filled) + "░".repeat(BAR_WIDTH - filled) + ` ${String(pct).padStart(3)}%`;
}

function formatEta(elapsedMs: number, done: number, total: number): string {
  if (done === 0 || done >= total) return "";
  const avgMs = elapsedMs / done;
  const etaMs = avgMs * (total - done);
  const s = Math.round(etaMs / 1000);
  if (s < 2)  return "~1s left";
  if (s < 60) return `~${s}s left`;
  const m = Math.floor(s / 60);
  const r = s % 60;
  if (m < 60) return r > 0 ? `~${m}m ${r}s left` : `~${m}m left`;
  const h = Math.floor(m / 60);
  const rm = m % 60;
  return rm > 0 ? `~${h}h ${rm}m left` : `~${h}h left`;
}

function formatDuration(ms: number): string {
  if (ms < 60000) return `${(ms / 1000).toFixed(1)}s`;
  const m = Math.floor(ms / 60000);
  const s = Math.round((ms % 60000) / 1000);
  return s > 0 ? `${m}m ${s}s` : `${m}m`;
}

function formatTestLine(test: TestCase, result: TestResult): string {
  const file = test.location.file.replace(/.*\/tests\//, "tests/");
  // Last meaningful title segment (skip describe wrappers if name is long enough)
  const segments = test.titlePath().slice(1); // drop file root
  const name = segments.length > 1 ? segments[segments.length - 1] : segments[0] ?? "";
  const truncated = name.length > 72 ? name.slice(0, 69) + "…" : name;
  const dur = formatDuration(result.duration);

  if (result.status === "passed") {
    return `  \x1b[32m✓\x1b[0m ${dur.padEnd(6)}  ${file} · ${truncated}`;
  }
  if (result.status === "skipped") {
    return `  \x1b[2m·\x1b[0m ${dur.padEnd(6)}  \x1b[2m${file} · ${truncated}  [skipped]\x1b[0m`;
  }
  // failed / timedOut — the full error block is printed separately; show a compact line too
  return `  \x1b[31m✘\x1b[0m ${dur.padEnd(6)}  ${file} · ${truncated}`;
}

function formatError(test: TestCase, result: TestResult): string {
  const title = test.titlePath().slice(1).join(" › ");
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
  private failedTitles = new Set<string>();
  private lineActive = false;
  private startTime = 0;

  onBegin(_config: FullConfig, suite: Suite): void {
    this.total = suite.allTests().length;
    this.startTime = Date.now();
    process.stdout.write(`\nRunning ${this.total} tests\n\n`);
    this.renderBar();
  }

  onTestEnd(test: TestCase, result: TestResult): void {
    this.done++;

    const isRetry = result.retry > 0;
    const title = test.titlePath().join(" › ");

    if (result.status === "passed") {
      if (isRetry && this.failedTitles.has(title)) {
        this.failed--;
        this.flaky++;
        this.failedTitles.delete(title);
      } else {
        this.passed++;
      }
    } else if (result.status === "skipped") {
      this.skipped++;
    } else {
      if (!isRetry) {
        this.failed++;
        this.failedTitles.add(title);
      }
    }

    const isFinalAttempt =
      result.status !== "passed" &&
      result.status !== "skipped" &&
      result.retry >= (test.retries ?? 0);

    // Clear the bar line before printing permanent output
    this.clearBar();

    // Full failure block
    if (isFinalAttempt) {
      process.stdout.write(formatError(test, result));
    }

    // Per-test one-liner (always printed)
    process.stdout.write(formatTestLine(test, result) + "\n");

    this.renderBar();
  }

  onEnd(result: FullResult): void {
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

  private clearBar(): void {
    if (this.lineActive) {
      process.stdout.write("\r" + " ".repeat(80) + "\r");
      this.lineActive = false;
    }
  }

  private renderBar(): void {
    const elapsed = Date.now() - this.startTime;
    const eta = formatEta(elapsed, this.done, this.total);
    const b = bar(this.done, this.total);
    const pass  = `\x1b[32m✓ ${this.passed}\x1b[0m`;
    const fail  = this.failed > 0 ? `\x1b[31m✘ ${this.failed}\x1b[0m` : `✘ 0`;
    const flaky = this.flaky > 0  ? `\x1b[33m~ ${this.flaky}\x1b[0m`  : "";
    const etaPart = eta ? `\x1b[2m  ${eta}\x1b[0m` : "";
    const extra = [pass, fail, flaky].filter(Boolean).join("   ");
    const line = `  [${this.done}/${this.total}] ${b}   ${extra}${etaPart}`;
    process.stdout.write(`\r${line}`);
    this.lineActive = true;
  }
}

export default ProgressReporter;
