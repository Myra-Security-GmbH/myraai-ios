import { describe, it, expect, vi, beforeEach } from "vitest";

// reportError uses a module-level `seen` Map for deduplication.
// Re-import fresh each test group by resetting module registry.

describe("reportError", () => {
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(() => {
    fetchMock = vi.fn().mockResolvedValue(new Response());
    vi.stubGlobal("fetch", fetchMock);
    // Reset module so the dedup `seen` Map starts empty each suite.
    vi.resetModules();
  });

  it("sends a POST to /admin/v1/client-errors with the error message", async () => {
    const { reportError } = await import("./reportError");
    reportError("something broke", "stack trace here");

    expect(fetchMock).toHaveBeenCalledOnce();
    const [url, opts] = fetchMock.mock.calls[0];
    expect(url).toBe("/admin/v1/client-errors");
    expect(opts.method).toBe("POST");
    const body = JSON.parse(opts.body);
    expect(body.message).toBe("something broke");
    expect(body.stack).toBe("stack trace here");
    expect(body.ts).toBeTruthy();
  });

  it("includes url and user_agent in payload", async () => {
    const { reportError } = await import("./reportError");
    reportError("err");

    const body = JSON.parse(fetchMock.mock.calls[0][1].body);
    expect(typeof body.url).toBe("string");
    expect(typeof body.user_agent).toBe("string");
  });

  it("deduplicates: second call within 5 s does not fire fetch", async () => {
    vi.useFakeTimers();
    const { reportError } = await import("./reportError");

    reportError("dup error");
    reportError("dup error");

    expect(fetchMock).toHaveBeenCalledOnce();
    vi.useRealTimers();
  });

  it("allows the same message again after 5 s window expires", async () => {
    vi.useFakeTimers();
    const { reportError } = await import("./reportError");

    reportError("repeat error");
    vi.advanceTimersByTime(6000);
    reportError("repeat error");

    expect(fetchMock).toHaveBeenCalledTimes(2);
    vi.useRealTimers();
  });

  it("does not throw if fetch rejects (fire-and-forget)", async () => {
    fetchMock.mockRejectedValue(new Error("network down"));
    const { reportError } = await import("./reportError");
    expect(() => reportError("network error")).not.toThrow();
  });

  it("uses keepalive: true on the fetch call", async () => {
    const { reportError } = await import("./reportError");
    reportError("keepalive test");
    expect(fetchMock.mock.calls[0][1].keepalive).toBe(true);
  });
});
