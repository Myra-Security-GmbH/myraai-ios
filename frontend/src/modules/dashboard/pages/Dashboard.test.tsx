import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import Dashboard from "./Dashboard";
import type { UsageStats, TimeseriesPoint, AnalyticsDepth } from "src/api/types";

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
  today:     { ...emptyPeriod, requests: 42, cost_usd: 1.23, blocked: 3, cached: 5 },
  yesterday: { ...emptyPeriod, requests: 30 },
  last_7d:   { ...emptyPeriod, requests: 200 },
  hour:      { ...emptyPeriod, requests: 10 },
  last_min:  { ...emptyPeriod, requests: 2 },
  by_tenant: [],
  recent: [
    {
      id: "l1", ts: "2024-03-15T12:00:00Z", tenant: "acme", tenant_id: "t1",
      gateway_id: "gw1", provider: "openai", model: "gpt-4o", status: 200,
      cached: 0, blocked: 0, blocked_by: null, block_reason: null,
      guardrail_verdict: null, input_tokens: 100, output_tokens: 50,
      cost_usd: 0.05, latency_ms: 320, upstream_latency_ms: 280,
      upstream_attempts: 1, fallback_provider: null, fallback_model: null,
      saved_cost_usd: null, request_size_bytes: 512, detectors_fired: [],
      scrub_applied: 0,
    },
  ],
  recent_blocked: [],
};

const TIMESERIES: TimeseriesPoint[] = [
  { ts: Date.now() - 3600000, requests: 5, blocked: 0, cost_usd: 0.01 },
  { ts: Date.now(),           requests: 8, blocked: 1, cost_usd: 0.02 },
];

const ANALYTICS: AnalyticsDepth = {
  percentiles: { p50: 120, p95: 400, p99: 800 },
  top_models: [
    { model: "gpt-4o", provider: "openai", requests: 20, cost_usd: 0.5, avg_latency_ms: 350 },
  ],
  by_tenant: [
    { tenant_id: "t1", tenant: "acme", requests: 20, blocked: 1, cached: 2,
      input_tokens: 500, output_tokens: 300, cost_usd: 0.4, saved_cost_usd: 0,
      avg_latency_ms: 300, errors: 0 },
  ],
  by_gateway: [],
  by_user: [],
};

function setupMocks() {
  mockGet.mockImplementation((path: string) => {
    if (path === "/stats") return Promise.resolve(STATS);
    if (path.startsWith("/stats/timeseries")) return Promise.resolve(TIMESERIES);
    if (path.startsWith("/stats/analytics")) return Promise.resolve(ANALYTICS);
    return Promise.resolve(null);
  });
}

function renderDashboard() {
  return render(
    <MemoryRouter>
      <Dashboard />
    </MemoryRouter>
  );
}

beforeEach(() => {
  vi.clearAllMocks();
});

// ---------------------------------------------------------------------------

describe("Dashboard — initial render", () => {
  it("shows loading state before data arrives", () => {
    mockGet.mockReturnValue(new Promise(() => {})); // never resolves
    renderDashboard();
    expect(screen.getByText(/loading/i)).toBeInTheDocument();
  });

  it("renders page title after load", async () => {
    setupMocks();
    renderDashboard();
    await waitFor(() => expect(screen.getByText("Dashboard")).toBeInTheDocument());
  });

  it("renders hero cards for Requests, Cost, Guardrail Hits", async () => {
    setupMocks();
    renderDashboard();
    await waitFor(() => {
      // These labels appear exactly once in the hero grid
      expect(screen.getAllByText("Requests").length).toBeGreaterThanOrEqual(1);
      expect(screen.getAllByText("Cost").length).toBeGreaterThanOrEqual(1);
      expect(screen.getByText("Guardrail Hits")).toBeInTheDocument();
    });
  });

  it("shows request count from today period", async () => {
    setupMocks();
    renderDashboard();
    await waitFor(() => expect(screen.getAllByText("42").length).toBeGreaterThanOrEqual(1));
  });
});

describe("Dashboard — timeframe selector", () => {
  it("renders all five timeframe buttons", async () => {
    setupMocks();
    renderDashboard();
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Today" })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "Yesterday" })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "Last 7 days" })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "Last hour" })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "Last minute" })).toBeInTheDocument();
    });
  });

  it("switching to 'Last 7 days' shows different request count", async () => {
    const user = userEvent.setup();
    setupMocks();
    renderDashboard();
    await waitFor(() => screen.getByRole("button", { name: "Last 7 days" }));

    await user.click(screen.getByRole("button", { name: "Last 7 days" }));
    await waitFor(() => expect(screen.getAllByText("200").length).toBeGreaterThanOrEqual(1));
  });

  it("switching to 'Last minute' shows correct request count", async () => {
    const user = userEvent.setup();
    setupMocks();
    renderDashboard();
    await waitFor(() => screen.getByRole("button", { name: "Last minute" }));

    await user.click(screen.getByRole("button", { name: "Last minute" }));
    await waitFor(() => expect(screen.getAllByText("2").length).toBeGreaterThanOrEqual(1));
  });
});

describe("Dashboard — tables", () => {
  it("renders Recent Requests table with a row", async () => {
    setupMocks();
    renderDashboard();
    await waitFor(() => {
      expect(screen.getByText("Recent Requests")).toBeInTheDocument();
      expect(screen.getAllByText("openai").length).toBeGreaterThanOrEqual(1);
      expect(screen.getAllByText("acme").length).toBeGreaterThanOrEqual(1);
    });
  });

  it("renders Usage by Tenant section when analytics data present", async () => {
    setupMocks();
    renderDashboard();
    await waitFor(() => expect(screen.getByText(/usage by tenant/i)).toBeInTheDocument());
  });

  it("renders Top Models section when analytics data present", async () => {
    setupMocks();
    renderDashboard();
    await waitFor(() => expect(screen.getByText(/top models/i)).toBeInTheDocument());
  });
});

describe("Dashboard — empty state", () => {
  it("shows 'No requests yet' when recent list is empty", async () => {
    mockGet.mockImplementation((path: string) => {
      if (path === "/stats") return Promise.resolve({ ...STATS, recent: [] });
      if (path.startsWith("/stats/timeseries")) return Promise.resolve([]);
      if (path.startsWith("/stats/analytics")) return Promise.resolve({ ...ANALYTICS, by_tenant: [], top_models: [] });
      return Promise.resolve(null);
    });
    renderDashboard();
    await waitFor(() => expect(screen.getByText(/no requests yet/i)).toBeInTheDocument());
  });
});
