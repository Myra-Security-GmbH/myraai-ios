/**
 * reporters/progress.ts — Compact Playwright progress reporter.
 *
 * Progress line (updates in place, no ASCII art):
 *   [42/542] 8%   ✓ 41   ✘ 1   ~2m 30s left
 *
 * One permanent line per test (passed, skipped, or failed):
 *   ✓ 1.4s   tests/chat-memory.spec.ts · user memory is injected into system prompt
 *   · 0.0s   tests/chat-memory.spec.ts · memory_disabled suppresses injection  [skipped]
 *   ✘ 2.0s   tests/chat-presets.spec.ts · PATCH chat_presets → 200  [expect(200).toBe(200)]
 *
 * Full failure details (file, title, error) are printed after all tests complete.
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

function stripAnsi(str: string): string {
  return str.replace(/\x1b\[[0-9;]*m/g, "");
}

function extractFirstErrorLine(err?: TestError): string {
  if (!err?.message) return "";
  const first = stripAnsi(err.message)
    .split("\n")
    .map((l) => l.trim())
    .find((l) => l.length > 0) ?? "";
  return first.length > 80 ? first.slice(0, 77) + "…" : first;
}

function formatTestLine(test: TestCase, result: TestResult): string {
  const file = test.location.file.replace(/.*\/tests\//, "tests/");
  const segments = test.titlePath().slice(1);
  const name = segments.length > 1 ? segments[segments.length - 1] : segments[0] ?? "";
  const truncated = name.length > 72 ? name.slice(0, 69) + "…" : name;
  const dur = formatDuration(result.duration);

  if (result.status === "passed") {
    return `  \x1b[32m✓\x1b[0m ${dur.padEnd(6)}  ${file} · ${truncated}`;
  }
  if (result.status === "skipped") {
    return `  \x1b[2m·\x1b[0m ${dur.padEnd(6)}  \x1b[2m${file} · ${truncated}  [skipped]\x1b[0m`;
  }
  // failed / timedOut — append first error line on same line
  const errMsg = extractFirstErrorLine(result.errors[0]);
  const suffix = errMsg ? `  \x1b[2m[${errMsg}]\x1b[0m` : "";
  return `  \x1b[31m✘\x1b[0m ${dur.padEnd(6)}  ${file} · ${truncated}${suffix}`;
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
  private failures: Array<{ test: TestCase; result: TestResult }> = [];
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

    if (isFinalAttempt) {
      this.failures.push({ test, result });
    }

    this.clearBar();
    process.stdout.write(formatTestLine(test, result) + "\n");
    this.renderBar();
  }

  onEnd(result: FullResult): void {
    this.clearBar();

    // Print full failure details after all tests have completed
    for (const { test, result: r } of this.failures) {
      process.stdout.write(formatError(test, r));
    }

    process.stdout.write("\n");

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
    const pct = this.total === 0 ? 100 : Math.round((this.done / this.total) * 100);
    const eta = formatEta(elapsed, this.done, this.total);
    const pass  = `\x1b[32m✓ ${this.passed}\x1b[0m`;
    const fail  = this.failed > 0 ? `\x1b[31m✘ ${this.failed}\x1b[0m` : `✘ 0`;
    const flaky = this.flaky > 0  ? `\x1b[33m~ ${this.flaky}\x1b[0m`  : "";
    const etaPart = eta ? `\x1b[2m  ${eta}\x1b[0m` : "";
    const extra = [pass, fail, flaky].filter(Boolean).join("   ");
    const line = `  [${this.done}/${this.total}] ${pct}%   ${extra}${etaPart}`;
    process.stdout.write(`\r${line}`);
    this.lineActive = true;
  }
}

export default ProgressReporter;
