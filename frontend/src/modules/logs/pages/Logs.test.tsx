import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import Logs from "./Logs";
import type { LogEntry, Tenant } from "src/api/types";

vi.mock("src/api/client", () => ({
  api: {
    get: vi.fn(),
  },
}));

import { api } from "src/api/client";
const mockGet = api.get as ReturnType<typeof vi.fn>;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const TENANT: Tenant = {
  id: "t1", slug: "acme", plan: "standard", budget_usd: null,
  budget_period: "monthly", created_at: 1704067200,
};

const baseLog: LogEntry = {
  id: "l1", ts: 1710460800, tenant: "acme", tenant_id: "t1",
  gateway_id: "gw1", provider: "anthropic", model: "claude-3-haiku", status: 200,
  cached: 0, blocked: 0, blocked_by: null, block_reason: null,
  guardrail_verdict: null, guardrail_latency_ms: null,
  input_tokens: 100, output_tokens: 50, cost_usd: 0.02,
  latency_ms: 320, upstream_latency_ms: 280,
  upstream_attempts: 1, fallback_provider: null, fallback_model: null,
  saved_cost_usd: null, request_size_bytes: 256,
  detectors_fired: [], scrub_applied: 0,
  cache_creation_tokens: 0, cache_read_tokens: 0,
};

const blockedLog: LogEntry = {
  ...baseLog,
  id: "l2", provider: "openai", model: "gpt-4o", status: 200,
  blocked: 1, blocked_by: "keyword", block_reason: "profanity",
  guardrail_verdict: "block", guardrail_latency_ms: 15,
  detectors_fired: ["keyword", "regex"],
};

const cachedLog: LogEntry = {
  ...baseLog,
  id: "l3", cached: 1,
};

const scrubLog: LogEntry = {
  ...baseLog,
  id: "l4", scrub_applied: 1,
};

const fallbackLog: LogEntry = {
  ...baseLog,
  id: "l5", fallback_provider: "anthropic", upstream_attempts: 2,
};

const errorLog: LogEntry = {
  ...baseLog,
  id: "l6", status: 500,
};

const withResponseRaw: LogEntry = {
  ...baseLog,
  id: "l7", response_raw: "This is the raw response body",
};

const withTrace: LogEntry = {
  ...baseLog,
  id: "l8", trace_id: "trace-abc-123",
};

const manyDetectors: LogEntry = {
  ...baseLog,
  id: "l9", detectors_fired: ["regex", "keyword", "jailbreak"],
};

function setupMocks(logs: LogEntry[] = [baseLog], tenants: Tenant[] = [TENANT]) {
  mockGet.mockImplementation((path: string) => {
    if (path === "/tenants") return Promise.resolve(tenants);
    if (path.startsWith("/logs")) return Promise.resolve(logs);
    if (path.startsWith("/traces/")) return Promise.resolve({
      trace: { id: "trace-abc-123", gateway_id: "gw1", model: "claude-3-haiku", created_at: 1710499200, completed_at: 1710499200.5, status: "done", error: null, source: "sdk" },
      steps: [
        { id: 1, trace_id: "trace-abc-123", seq: 1, step: "request_received", data: { model: "claude-3-haiku", messages_count: 2, streaming: false, size_bytes: 256 }, ts: 1710499200 },
        { id: 2, trace_id: "trace-abc-123", seq: 2, step: "upstream_response", data: { status: 200, latency_ms: 280 }, ts: 1710499200.3 },
      ],
    });
    return Promise.resolve(null);
  });
}

function renderLogs() {
  return render(
    <MemoryRouter>
      <Logs />
    </MemoryRouter>
  );
}

beforeEach(() => {
  vi.clearAllMocks();
});

// ---------------------------------------------------------------------------

describe("Logs — initial render", () => {
  it("shows loading state initially", () => {
    mockGet.mockReturnValue(new Promise(() => {}));
    renderLogs();
    expect(screen.getByText(/loading/i)).toBeInTheDocument();
  });

  it("renders page title after load", async () => {
    setupMocks();
    renderLogs();
    await waitFor(() => expect(screen.getByText("Request Logs")).toBeInTheDocument());
  });

  it("shows entry count in subtitle", async () => {
    setupMocks([baseLog]);
    renderLogs();
    await waitFor(() => expect(screen.getByText("1 entries")).toBeInTheDocument());
  });

  it("shows Refresh button", async () => {
    setupMocks();
    renderLogs();
    await waitFor(() => expect(screen.getByRole("button", { name: "Refresh" })).toBeInTheDocument());
  });
});

describe("Logs — filter controls", () => {
  it("renders Tenant filter with All tenants option", async () => {
    setupMocks();
    renderLogs();
    await waitFor(() => {
      const select = screen.getAllByRole("combobox")[0];
      expect(within(select).getByText("All tenants")).toBeInTheDocument();
    });
  });

  it("populates tenant dropdown from fetched tenants", async () => {
    setupMocks();
    renderLogs();
    await waitFor(() => expect(screen.getByText("acme")).toBeInTheDocument());
  });

  it("renders Provider filter", async () => {
    setupMocks();
    renderLogs();
    await waitFor(() => expect(screen.getByText("All providers")).toBeInTheDocument());
  });

  it("renders Model text input", async () => {
    setupMocks();
    renderLogs();
    await waitFor(() => expect(screen.getByPlaceholderText("e.g. gpt-4o")).toBeInTheDocument());
  });

  it("renders Status filter with options", async () => {
    setupMocks();
    renderLogs();
    await waitFor(() => {
      expect(screen.getByText("200 OK")).toBeInTheDocument();
      expect(screen.getByText("500")).toBeInTheDocument();
    });
  });

  it("renders Blocked filter", async () => {
    setupMocks();
    renderLogs();
    await waitFor(() => expect(screen.getByText("Blocked only")).toBeInTheDocument());
  });

  it("renders Guardrail outcome filter", async () => {
    setupMocks();
    renderLogs();
    await waitFor(() => {
      expect(screen.getByText("Any hit")).toBeInTheDocument();
      expect(screen.getAllByText("Blocked").length).toBeGreaterThanOrEqual(1);
      expect(screen.getAllByText("Scrubbed").length).toBeGreaterThanOrEqual(1);
      expect(screen.getAllByText("Flagged").length).toBeGreaterThanOrEqual(1);
    });
  });

  it("renders Limit selector with options", async () => {
    setupMocks();
    renderLogs();
    await waitFor(() => {
      expect(screen.getByText("20")).toBeInTheDocument();
      expect(screen.getByText("100")).toBeInTheDocument();
      expect(screen.getByText("200")).toBeInTheDocument();
    });
  });
});

describe("Logs — table rendering", () => {
  it("renders table headers", async () => {
    setupMocks([baseLog]);
    renderLogs();
    await waitFor(() => {
      expect(screen.getAllByText("Provider").length).toBeGreaterThanOrEqual(1);
      expect(screen.getAllByText("Model").length).toBeGreaterThanOrEqual(1);
      expect(screen.getAllByText("Status").length).toBeGreaterThanOrEqual(1);
      expect(screen.getByText("Cost")).toBeInTheDocument();
      expect(screen.getByText("Latency")).toBeInTheDocument();
      expect(screen.getByText("Guardrail")).toBeInTheDocument();
      expect(screen.getByText("Detectors")).toBeInTheDocument();
    });
  });

  it("renders a row with provider and model", async () => {
    setupMocks([baseLog]);
    renderLogs();
    await waitFor(() => {
      expect(screen.getAllByText("anthropic").length).toBeGreaterThanOrEqual(1);
      expect(screen.getByText("claude-3-haiku")).toBeInTheDocument();
    });
  });

  it("shows cost formatted with 5 decimals", async () => {
    setupMocks([baseLog]);
    renderLogs();
    await waitFor(() => expect(screen.getByText("$0.02000")).toBeInTheDocument());
  });

  it("shows success badge for 200 status", async () => {
    setupMocks([baseLog]);
    renderLogs();
    await waitFor(() => {
      // 200 appears in the status badge AND in the Status filter option
      const badges = screen.getAllByText("200");
      const statusBadge = badges.find((el) => el.tagName === "SPAN");
      expect(statusBadge).toBeTruthy();
      expect(statusBadge!.className).toMatch(/success/i);
    });
  });

  it("shows error badge for 500 status", async () => {
    setupMocks([errorLog]);
    renderLogs();
    await waitFor(() => {
      const badges = screen.getAllByText("500");
      const statusBadge = badges.find((el) => el.tagName === "SPAN");
      expect(statusBadge).toBeTruthy();
      expect(statusBadge!.className).toMatch(/error/i);
    });
  });
});

describe("Logs — empty state", () => {
  it("shows 'No logs match your filters' when list is empty", async () => {
    setupMocks([]);
    renderLogs();
    await waitFor(() => expect(screen.getByText(/No logs match your filters/i)).toBeInTheDocument());
  });
});

describe("Logs — flag badges", () => {
  it("shows 'blocked' badge for blocked row", async () => {
    setupMocks([blockedLog]);
    renderLogs();
    await waitFor(() => expect(screen.getByText("blocked")).toBeInTheDocument());
  });

  it("shows 'cached' badge for cached row", async () => {
    setupMocks([cachedLog]);
    renderLogs();
    await waitFor(() => expect(screen.getByText("cached")).toBeInTheDocument());
  });

  it("shows 'scrubbed' badge for scrubbed row", async () => {
    setupMocks([scrubLog]);
    renderLogs();
    await waitFor(() => expect(screen.getByText("scrubbed")).toBeInTheDocument());
  });

  it("shows 'fallback' badge for row with fallback provider", async () => {
    setupMocks([fallbackLog]);
    renderLogs();
    await waitFor(() => expect(screen.getByText("fallback")).toBeInTheDocument());
  });

  it("shows '2 attempts' badge for row with multiple upstream attempts", async () => {
    setupMocks([fallbackLog]);
    renderLogs();
    await waitFor(() => expect(screen.getByText("2 attempts")).toBeInTheDocument());
  });
});

describe("Logs — detectors fired", () => {
  it("shows detector name badges when detectors_fired is non-empty", async () => {
    setupMocks([blockedLog]);
    renderLogs();
    await waitFor(() => {
      expect(screen.getByText("keyword")).toBeInTheDocument();
      expect(screen.getByText("regex")).toBeInTheDocument();
    });
  });

  it("shows +N overflow badge when more than 2 detectors fired", async () => {
    setupMocks([manyDetectors]);
    renderLogs();
    await waitFor(() => expect(screen.getByText("+1")).toBeInTheDocument());
  });
});

describe("Logs — guardrail column", () => {
  it("shows guardrail latency and verdict badge when guardrail ran", async () => {
    setupMocks([blockedLog]);
    renderLogs();
    await waitFor(() => {
      expect(screen.getByText("15 ms")).toBeInTheDocument();
      expect(screen.getByText("block")).toBeInTheDocument();
    });
  });
});

describe("Logs — response_raw expand", () => {
  it("clicking a row with response_raw expands it", async () => {
    const user = userEvent.setup();
    setupMocks([withResponseRaw]);
    renderLogs();
    await waitFor(() => expect(screen.getByText("anthropic")).toBeInTheDocument());

    const rows = screen.getAllByRole("row");
    const dataRow = rows.find((r) => within(r).queryByText("anthropic"))!;
    await user.click(dataRow);
    await waitFor(() => expect(screen.getByText("This is the raw response body")).toBeInTheDocument());
  });
});

describe("Logs — trace panel", () => {
  it("shows 'Trace ›' button for row with trace_id", async () => {
    setupMocks([withTrace]);
    renderLogs();
    await waitFor(() => expect(screen.getByRole("button", { name: "Trace ›" })).toBeInTheDocument());
  });

  it("opens TracePanel when Trace › is clicked", async () => {
    const user = userEvent.setup();
    setupMocks([withTrace]);
    renderLogs();
    await waitFor(() => screen.getByRole("button", { name: "Trace ›" }));
    await user.click(screen.getByRole("button", { name: "Trace ›" }));
    await waitFor(() => expect(screen.getByText("Request Trace")).toBeInTheDocument());
  });

  it("TracePanel shows step labels after fetch", async () => {
    const user = userEvent.setup();
    setupMocks([withTrace]);
    renderLogs();
    await waitFor(() => screen.getByRole("button", { name: "Trace ›" }));
    await user.click(screen.getByRole("button", { name: "Trace ›" }));
    await waitFor(() => {
      expect(screen.getByText("Received")).toBeInTheDocument();
      expect(screen.getByText("← Provider")).toBeInTheDocument();
    });
  });

  it("closes TracePanel when ✕ close button is clicked", async () => {
    const user = userEvent.setup();
    setupMocks([withTrace]);
    renderLogs();
    await waitFor(() => screen.getByRole("button", { name: "Trace ›" }));
    await user.click(screen.getByRole("button", { name: "Trace ›" }));
    await waitFor(() => expect(screen.getByText("Request Trace")).toBeInTheDocument());
    // The table row button now reads "Close" (toggled by traceId match)
    await user.click(screen.getByRole("button", { name: "Close" }));
    await waitFor(() => expect(screen.queryByText("Request Trace")).not.toBeInTheDocument());
  });

  it("TracePanel shows 'done' status badge", async () => {
    const user = userEvent.setup();
    setupMocks([withTrace]);
    renderLogs();
    await waitFor(() => screen.getByRole("button", { name: "Trace ›" }));
    await user.click(screen.getByRole("button", { name: "Trace ›" }));
    await waitFor(() => expect(screen.getByText("done")).toBeInTheDocument());
  });
});
