import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import Monitor from "./Monitor";
import type { UsageStats, Tenant } from "src/api/types";

vi.mock("src/api/client", () => ({
  api: { get: vi.fn() },
}));

import { api } from "src/api/client";
const mockGet = api.get as ReturnType<typeof vi.fn>;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const emptyPeriod = {
  requests: 0, cached: 0, blocked: 0, scrubbed: 0, flagged: 0,
  input_tokens: 0, output_tokens: 0, cost_usd: 0, saved_cost_usd: 0,
  avg_latency_ms: 0, avg_upstream_latency_ms: 0,
};

const STATS: UsageStats = {
  today:     { ...emptyPeriod, requests: 55 },
  yesterday: emptyPeriod,
  last_7d:   emptyPeriod,
  hour:      { ...emptyPeriod, requests: 12 },
  last_min:  { ...emptyPeriod, requests: 3 },
  by_tenant: [
    { tenant_id: "t1", tenant: "acme", requests: 55, blocked: 0, cached: 0,
      input_tokens: 1000, output_tokens: 500, cost_usd: 0.5, saved_cost_usd: 0,
      avg_latency_ms: 300, errors: 0 },
  ],
  recent: [
    {
      id: "l1", ts: "2024-03-15T12:00:00Z", tenant: "acme", tenant_id: "t1",
      gateway_id: "gw1", provider: "anthropic", model: "claude-3-haiku", status: 200,
      cached: 0, blocked: 0, blocked_by: null, block_reason: null,
      guardrail_verdict: null, input_tokens: 80, output_tokens: 40,
      cost_usd: 0.02, latency_ms: 200, upstream_latency_ms: 170,
      upstream_attempts: 1, fallback_provider: null, fallback_model: null,
      saved_cost_usd: null, request_size_bytes: 256, detectors_fired: [],
      scrub_applied: 0,
    },
  ],
  recent_blocked: [],
};

const TENANTS: Tenant[] = [
  { id: "t1", slug: "acme", plan: "standard", budget_usd: null, budget_period: "monthly", created_at: "2024-01-01T00:00:00Z" },
];

function setupMocks(statsOverride?: Partial<UsageStats>) {
  mockGet.mockImplementation((path: string) => {
    if (path === "/tenants") return Promise.resolve(TENANTS);
    if (path.startsWith("/stats")) return Promise.resolve({ ...STATS, ...statsOverride });
    return Promise.resolve(null);
  });
}

function renderMonitor() {
  return render(
    <MemoryRouter>
      <Monitor />
    </MemoryRouter>
  );
}

beforeEach(() => {
  vi.clearAllMocks();
});

// ---------------------------------------------------------------------------

describe("Monitor — initial render", () => {
  it("shows page title", async () => {
    setupMocks();
    renderMonitor();
    await waitFor(() => expect(screen.getByText("Live Monitor")).toBeInTheDocument());
  });

  it("shows loading indicator before first fetch resolves", () => {
    mockGet.mockReturnValue(new Promise(() => {}));
    renderMonitor();
    expect(screen.getByText(/loading/i)).toBeInTheDocument();
  });

  it("renders period cards for Last minute, Last hour, Today", async () => {
    setupMocks();
    renderMonitor();
    await waitFor(() => {
      expect(screen.getByText("Last minute")).toBeInTheDocument();
      expect(screen.getByText("Last hour")).toBeInTheDocument();
      expect(screen.getByText("Today")).toBeInTheDocument();
    });
  });

  it("renders recent requests table", async () => {
    setupMocks();
    renderMonitor();
    await waitFor(() => {
      expect(screen.getByText("Last 10 Requests")).toBeInTheDocument();
      expect(screen.getByText("anthropic")).toBeInTheDocument();
    });
  });

  it("renders tenant breakdown when by_tenant is populated", async () => {
    setupMocks();
    renderMonitor();
    await waitFor(() => expect(screen.getByText("Tenants — Today")).toBeInTheDocument());
  });
});

describe("Monitor — pause / resume", () => {
  it("shows Pause button when running", async () => {
    setupMocks();
    renderMonitor();
    await waitFor(() => expect(screen.getByText(/⏸ Pause/)).toBeInTheDocument());
  });

  it("switches to Resume after clicking Pause", async () => {
    const user = userEvent.setup();
    setupMocks();
    renderMonitor();
    await waitFor(() => screen.getByText(/⏸ Pause/));

    await user.click(screen.getByText(/⏸ Pause/));
    expect(screen.getByText(/▶ Resume/)).toBeInTheDocument();
  });

  it("subtitle shows 'auto-refresh paused' after pause", async () => {
    const user = userEvent.setup();
    setupMocks();
    renderMonitor();
    await waitFor(() => screen.getByText(/⏸ Pause/));

    await user.click(screen.getByText(/⏸ Pause/));
    await waitFor(() => expect(screen.getByText(/paused/i)).toBeInTheDocument());
  });
});

describe("Monitor — tenant filter", () => {
  it("renders tenant dropdown when tenants are loaded", async () => {
    setupMocks();
    renderMonitor();
    await waitFor(() => expect(screen.getByText("All tenants")).toBeInTheDocument());
    expect(screen.getAllByText("acme").length).toBeGreaterThanOrEqual(1);
  });
});

describe("Monitor — error state", () => {
  it("shows error message when stats fetch fails", async () => {
    mockGet.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([]);
      return Promise.reject(new Error("network error"));
    });
    renderMonitor();
    await waitFor(() => expect(screen.getByText("network error")).toBeInTheDocument());
  });
});

describe("Monitor — empty requests", () => {
  it("shows 'No requests yet' when recent list is empty", async () => {
    setupMocks({ recent: [] });
    renderMonitor();
    await waitFor(() => expect(screen.getByText(/no requests yet/i)).toBeInTheDocument());
  });
});
