import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Routes, Route } from "react-router-dom";
import TenantAnalytics from "./TenantAnalytics";
import type {
  AnalyticsDepth, Tenant, TenantAnalyticsDetail, SpendRecord, TimeseriesPoint,
} from "src/api/types";

// ---------------------------------------------------------------------------
// API mock
// ---------------------------------------------------------------------------

vi.mock("src/api/client", () => ({
  api: {
    get: vi.fn(),
    post: vi.fn(),
    patch: vi.fn(),
    delete: vi.fn(),
  },
}));

import { api } from "src/api/client";
const mockApi = api as { get: ReturnType<typeof vi.fn> };

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const TENANT1: Tenant = {
  id: "t1", slug: "acme", plan: "enterprise",
  budget_usd: 100, budget_period: "monthly",
  created_at: "2024-01-01T00:00:00Z",
};
const TENANT2: Tenant = {
  id: "t2", slug: "devteam", plan: "standard",
  budget_usd: null, budget_period: "monthly",
  created_at: "2024-01-02T00:00:00Z",
};

const GLOBAL_TS: TimeseriesPoint[] = Array.from({ length: 30 }, (_, i) => ({
  ts:       Date.now() - (29 - i) * 86400000,
  requests: (i + 1) * 10,
  blocked:  0,
  cost_usd: (i + 1) * 0.20,
}));

const ANALYTICS: AnalyticsDepth = {
  percentiles: { p50: 400, p95: 1200, p99: 2500 },
  top_models: [
    { model: "gpt-4o",           provider: "openai",    requests: 500, cost_usd: 8.50, avg_latency_ms: 620 },
    { model: "claude-sonnet-4",  provider: "anthropic", requests: 200, cost_usd: 3.20, avg_latency_ms: 890 },
    { model: "mistral-large",    provider: "mistral",   requests: 100, cost_usd: 1.10, avg_latency_ms: 450 },
  ],
  by_tenant: [
    {
      tenant_id: "t1", tenant: "acme",
      requests: 500, blocked: 4, cached: 50,
      input_tokens: 800000, output_tokens: 200000,
      cost_usd: 8.50, saved_cost_usd: 0.42, avg_latency_ms: 620,
      errors: 5,
    },
    {
      tenant_id: "t2", tenant: "devteam",
      requests: 200, blocked: 0, cached: 20,
      input_tokens: 300000, output_tokens: 80000,
      cost_usd: 3.20, saved_cost_usd: 0.18, avg_latency_ms: 890,
      errors: 0,
    },
  ],
  by_gateway: [
    {
      gateway_id: "g1", gateway: "prod-gw", tenant: "acme",
      requests: 300, blocked: 2, cached: 30,
      input_tokens: 500000, output_tokens: 120000,
      cost_usd: 5.10, saved_cost_usd: 0.25, avg_latency_ms: 580,
      errors: 3,
    },
    {
      gateway_id: "g2", gateway: "dev-gw", tenant: "devteam",
      requests: 200, blocked: 0, cached: 20,
      input_tokens: 300000, output_tokens: 80000,
      cost_usd: 3.20, saved_cost_usd: 0.18, avg_latency_ms: 890,
      errors: 0,
    },
  ],
  by_user: [
    {
      user_id: "alice@example.com",
      tenant_id: "t1",                          // acme
      requests: 300, blocked: 1, cached: 30,
      input_tokens: 400000, output_tokens: 100000,
      cost_usd: 5.40, saved_cost_usd: 0.21, avg_latency_ms: 600,
      errors: 2,
    },
    {
      user_id: "bob@example.com",
      tenant_id: "t2",                          // devteam
      requests: 100, blocked: 0, cached: 5,
      input_tokens: 150000, output_tokens: 40000,
      cost_usd: 1.80, saved_cost_usd: 0.05, avg_latency_ms: 750,
      errors: 0,
    },
  ],
};

const EMPTY_ANALYTICS: AnalyticsDepth = {
  percentiles: { p50: null, p95: null, p99: null },
  top_models: [],
  by_tenant: [],
  by_gateway: [],
  by_user: [],
};

const DETAIL: TenantAnalyticsDetail = {
  timeseries: Array.from({ length: 30 }, (_, i) => ({
    ts:       Date.now() - (29 - i) * 86400000,
    requests: (i + 1) * 5,
    blocked:  0,
    cost_usd: (i + 1) * 0.10,
  })),
  top_models: [
    { model: "gpt-4o", provider: "openai", requests: 400, cost_usd: 6.80, avg_latency_ms: 600 },
  ],
};

const SPEND: SpendRecord[] = [
  { period: "2026-03", amount_micro: 8500000, amount_usd: 8.50,  updated_at: 1742000000 },
  { period: "2026-02", amount_micro: 7200000, amount_usd: 7.20,  updated_at: 1739000000 },
  { period: "2026-01", amount_micro: 6100000, amount_usd: 6.10,  updated_at: 1736000000 },
  { period: "2026-03-22", amount_micro: 300000, amount_usd: 0.30, updated_at: 1742000000 },
  { period: "total",    amount_micro: 21800000, amount_usd: 21.80, updated_at: 1742000000 },
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function setupDefaultMocks() {
  mockApi.get.mockImplementation((path: string) => {
    if (path.startsWith("/stats/analytics"))  return Promise.resolve(ANALYTICS);
    if (path === "/tenants")                  return Promise.resolve([TENANT1, TENANT2]);
    if (path === "/stats/timeseries?bucket=1d&n=30") return Promise.resolve(GLOBAL_TS);
    if (path.includes("/analytics"))          return Promise.resolve(DETAIL);
    if (path.includes("/spend"))              return Promise.resolve(SPEND);
    return Promise.resolve([]);
  });
}

function renderPage() {
  return render(
    <MemoryRouter initialEntries={["/analytics"]}>
      <Routes>
        <Route path="/analytics" element={<TenantAnalytics />} />
      </Routes>
    </MemoryRouter>
  );
}

beforeEach(() => {
  vi.clearAllMocks();
});

// ---------------------------------------------------------------------------
// Page structure
// ---------------------------------------------------------------------------

describe("TenantAnalytics — page structure", () => {
  it("renders the page heading", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() =>
      expect(screen.getByRole("heading", { name: "Cost Analytics" })).toBeInTheDocument()
    );
  });

  it("renders the period selector with three options", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "Today" })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "Last 7 days" })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "Last 30 days" })).toBeInTheDocument();
    });
  });

  it("renders five tab buttons", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => {
      expect(screen.getByRole("button", { name: "By Tenant" })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "By Gateway" })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "By Provider" })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "By Model" })).toBeInTheDocument();
      expect(screen.getByRole("button", { name: "By User" })).toBeInTheDocument();
    });
  });

  it("fetches analytics, tenants, and timeseries on mount", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => expect(mockApi.get).toHaveBeenCalledWith(
      expect.stringContaining("/stats/analytics")
    ));
    expect(mockApi.get).toHaveBeenCalledWith("/tenants");
    expect(mockApi.get).toHaveBeenCalledWith("/stats/timeseries?bucket=1d&n=30");
  });
});

// ---------------------------------------------------------------------------
// Overview chart
// ---------------------------------------------------------------------------

describe("TenantAnalytics — overview chart", () => {
  it("renders the 30-day overview chart when timeseries has data", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() =>
      expect(screen.getByText("30-Day Overview")).toBeInTheDocument()
    );
  });

  it("shows cost and requests legend labels", async () => {
    setupDefaultMocks();
    renderPage();
    // "Cost" and "Requests" also appear as table column headers — use getAllByText
    await waitFor(() => {
      expect(screen.getAllByText("Cost").length).toBeGreaterThanOrEqual(1);
      expect(screen.getAllByText("Requests").length).toBeGreaterThanOrEqual(1);
    });
  });

  it("renders SVG chart element when data is present", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() =>
      expect(screen.getByLabelText("30-day overview chart")).toBeInTheDocument()
    );
  });

  it("does not show chart heading when timeseries is empty", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path.startsWith("/stats/analytics")) return Promise.resolve(ANALYTICS);
      if (path === "/tenants")                 return Promise.resolve([TENANT1, TENANT2]);
      if (path === "/stats/timeseries?bucket=1d&n=30") return Promise.resolve([]);
      return Promise.resolve([]);
    });
    renderPage();
    // wait for load then verify chart heading absent
    await waitFor(() => screen.getByRole("heading", { name: "Cost Analytics" }));
    expect(screen.queryByText("30-Day Overview")).not.toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Latency strip
// ---------------------------------------------------------------------------

describe("TenantAnalytics — latency strip", () => {
  it("shows p50 / p95 / p99 chips", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => {
      expect(screen.getByText("p50")).toBeInTheDocument();
      expect(screen.getByText("p95")).toBeInTheDocument();
      expect(screen.getByText("p99")).toBeInTheDocument();
    });
  });

  it("shows latency values in ms", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => {
      expect(screen.getByText("400 ms")).toBeInTheDocument();  // p50
      expect(screen.getByText("1200 ms")).toBeInTheDocument(); // p95
      expect(screen.getByText("2500 ms")).toBeInTheDocument(); // p99
    });
  });

  it("hides strip when all percentiles are null", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path.startsWith("/stats/analytics")) return Promise.resolve(EMPTY_ANALYTICS);
      if (path === "/tenants")                 return Promise.resolve([]);
      return Promise.resolve([]);
    });
    renderPage();
    await waitFor(() => screen.getByRole("heading", { name: "Cost Analytics" }));
    expect(screen.queryByText("p50")).not.toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Hero cards
// ---------------------------------------------------------------------------

describe("TenantAnalytics — hero cards", () => {
  it("shows total spend across all tenants", async () => {
    setupDefaultMocks();
    renderPage();
    // 8.50 + 3.20 = 11.70
    await waitFor(() => expect(screen.getByText("$11.70")).toBeInTheDocument());
  });

  it("shows cache savings", async () => {
    setupDefaultMocks();
    renderPage();
    // 0.42 + 0.18 = 0.60
    await waitFor(() => expect(screen.getByText("$0.60")).toBeInTheDocument());
  });

  it("shows total requests", async () => {
    setupDefaultMocks();
    renderPage();
    // 500 + 200 = 700
    await waitFor(() => expect(screen.getByText("700")).toBeInTheDocument());
  });

  it("shows error rate", async () => {
    setupDefaultMocks();
    renderPage();
    // 5 errors / 700 requests = 0.71%
    await waitFor(() => expect(screen.getByText("0.7%")).toBeInTheDocument());
  });

  it("shows top spender tenant slug", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => expect(screen.getAllByText("acme").length).toBeGreaterThanOrEqual(1));
  });

  it("shows budget warnings count", async () => {
    setupDefaultMocks();
    renderPage();
    // acme has budget_usd=100, cost=8.50 → 8.5% → under 80%, 0 warnings
    await waitFor(() => expect(screen.getByText("0")).toBeInTheDocument());
  });

  it("shows warning count when tenant exceeds 80% budget", async () => {
    mockApi.get.mockImplementation((path: string) => {
      const tenant1Over: Tenant = { ...TENANT1, budget_usd: 10 }; // 8.50/10 = 85%
      if (path.startsWith("/stats/analytics")) return Promise.resolve(ANALYTICS);
      if (path === "/tenants")                 return Promise.resolve([tenant1Over, TENANT2]);
      return Promise.resolve([]);
    });
    renderPage();
    await waitFor(() => expect(screen.getByText("1")).toBeInTheDocument());
  });
});

// ---------------------------------------------------------------------------
// By Tenant tab
// ---------------------------------------------------------------------------

describe("TenantAnalytics — By Tenant tab", () => {
  it("shows a row for each tenant", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => {
      expect(screen.getAllByText("acme").length).toBeGreaterThanOrEqual(1);
      expect(screen.getByText("devteam")).toBeInTheDocument();
    });
  });

  it("shows cost for each tenant", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => {
      // $8.50 appears in hero card AND table row — use getAllByText
      expect(screen.getAllByText("$8.50").length).toBeGreaterThanOrEqual(1);
      expect(screen.getByText("$3.20")).toBeInTheDocument();
    });
  });

  it("shows error rate badge for tenant with errors", async () => {
    setupDefaultMocks();
    renderPage();
    // acme has 5 errors / 500 requests = 1.0%
    await waitFor(() => expect(screen.getByText("1.0%")).toBeInTheDocument());
  });

  it("shows blocked badge when tenant has blocked requests", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => expect(screen.getByText("4")).toBeInTheDocument());
  });

  it("shows budget bar for tenant with a budget set", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => expect(screen.getByText("$100.00")).toBeInTheDocument());
  });

  it("shows 'unlimited' for tenant with no budget", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => expect(screen.getByText("unlimited")).toBeInTheDocument());
  });

  it("shows cache percentage column", async () => {
    setupDefaultMocks();
    renderPage();
    // acme: 50/500 = 10%, devteam: 20/200 = 10% — both show 10%
    await waitFor(() => expect(screen.getAllByText("10%").length).toBeGreaterThanOrEqual(1));
  });

  it("shows empty state when no tenants have data", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path.startsWith("/stats/analytics")) return Promise.resolve(EMPTY_ANALYTICS);
      if (path === "/tenants")                 return Promise.resolve([TENANT1]);
      return Promise.resolve([]);
    });
    renderPage();
    await waitFor(() =>
      expect(screen.getByText(/No data for this period/i)).toBeInTheDocument()
    );
  });
});

// ---------------------------------------------------------------------------
// Period selector
// ---------------------------------------------------------------------------

describe("TenantAnalytics — period selector", () => {
  it("refetches analytics when period changes", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("heading", { name: "Cost Analytics" }));

    const callsBefore = mockApi.get.mock.calls.length;
    await userEvent.click(screen.getByRole("button", { name: "Today" }));
    await waitFor(() => expect(mockApi.get.mock.calls.length).toBeGreaterThan(callsBefore));
    const analyticsCalls = mockApi.get.mock.calls.filter(
      ([p]: [string]) => p.includes("/stats/analytics")
    );
    expect(analyticsCalls.length).toBeGreaterThanOrEqual(2);
  });

  it("shows selected period label in table heading", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() =>
      expect(screen.getByText(/Tenant Breakdown — Last 7 days/i)).toBeInTheDocument()
    );
    await userEvent.click(screen.getByRole("button", { name: "Today" }));
    await waitFor(() =>
      expect(screen.getByText(/Tenant Breakdown — Today/i)).toBeInTheDocument()
    );
  });
});

// ---------------------------------------------------------------------------
// Tab switching
// ---------------------------------------------------------------------------

describe("TenantAnalytics — tab switching", () => {
  it("By Gateway tab shows gateway rows", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By Gateway" }));
    await userEvent.click(screen.getByRole("button", { name: "By Gateway" }));
    await waitFor(() => {
      expect(screen.getByText("prod-gw")).toBeInTheDocument();
      expect(screen.getByText("dev-gw")).toBeInTheDocument();
    });
  });

  it("By Gateway tab shows section heading with period", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By Gateway" }));
    await userEvent.click(screen.getByRole("button", { name: "By Gateway" }));
    await waitFor(() => expect(screen.getByText(/Gateway Breakdown/)).toBeInTheDocument());
  });

  it("By Gateway tab shows error rate for gateway with errors", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By Gateway" }));
    await userEvent.click(screen.getByRole("button", { name: "By Gateway" }));
    // prod-gw: 3 errors / 300 requests = 1.0%
    await waitFor(() => expect(screen.getAllByText("1.0%").length).toBeGreaterThanOrEqual(1));
  });

  it("By Provider tab shows provider rows", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By Provider" }));
    await userEvent.click(screen.getByRole("button", { name: "By Provider" }));
    await waitFor(() => {
      expect(screen.getByText("openai")).toBeInTheDocument();
      expect(screen.getByText("anthropic")).toBeInTheDocument();
      expect(screen.getByText("mistral")).toBeInTheDocument();
    });
  });

  it("By Provider tab shows section heading", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By Provider" }));
    await userEvent.click(screen.getByRole("button", { name: "By Provider" }));
    await waitFor(() => expect(screen.getByText(/Provider Breakdown/)).toBeInTheDocument());
  });

  it("By Provider tab shows model count column", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By Provider" }));
    await userEvent.click(screen.getByRole("button", { name: "By Provider" }));
    await waitFor(() => expect(screen.getByText("Models")).toBeInTheDocument());
  });

  it("By Model tab shows model rows", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By Model" }));
    await userEvent.click(screen.getByRole("button", { name: "By Model" }));
    await waitFor(() => {
      expect(screen.getByText("gpt-4o")).toBeInTheDocument();
      expect(screen.getByText("openai")).toBeInTheDocument();
    });
  });

  it("By Model tab shows section heading", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By Model" }));
    await userEvent.click(screen.getByRole("button", { name: "By Model" }));
    await waitFor(() => expect(screen.getByText(/Model Breakdown/)).toBeInTheDocument());
  });

  it("By User tab shows user rows", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By User" }));
    await userEvent.click(screen.getByRole("button", { name: "By User" }));
    await waitFor(() => {
      expect(screen.getByText("alice@example.com")).toBeInTheDocument();
      expect(screen.getByText("bob@example.com")).toBeInTheDocument();
    });
  });

  it("By User tab shows section heading", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By User" }));
    await userEvent.click(screen.getByRole("button", { name: "By User" }));
    await waitFor(() => expect(screen.getByText(/User Breakdown/)).toBeInTheDocument());
  });

  it("By User tab shows error rate for user with errors", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By User" }));
    await userEvent.click(screen.getByRole("button", { name: "By User" }));
    // alice: 2 errors / 300 requests = 0.7%
    await waitFor(() => expect(screen.getAllByText("0.7%").length).toBeGreaterThanOrEqual(1));
  });

  it("By User tab shows empty state when no user data", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path.startsWith("/stats/analytics")) return Promise.resolve(EMPTY_ANALYTICS);
      if (path === "/tenants")                 return Promise.resolve([TENANT1]);
      return Promise.resolve([]);
    });
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By User" }));
    await userEvent.click(screen.getByRole("button", { name: "By User" }));
    await waitFor(() =>
      expect(screen.getByText(/No data for this period/i)).toBeInTheDocument()
    );
  });

  it("switching back to By Tenant shows tenant data again", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By Gateway" }));
    await userEvent.click(screen.getByRole("button", { name: "By Gateway" }));
    await userEvent.click(screen.getByRole("button", { name: "By Tenant" }));
    await waitFor(() => expect(screen.getByText("devteam")).toBeInTheDocument());
  });

  // ── Tenant-scoped user filtering ─────────────────────────────────────────
  // Regression: by_user had no tenant_id field and filteredByUser never
  // applied a tenant filter. Clicking "acme" in By Tenant then switching to
  // By User showed ALL users globally (or nothing for tenants like "myratest"
  // whose requests carried no user_id). These tests pin the contract that:
  //   1. by_user rows include tenant_id from the backend
  //   2. When a tenant row is selected, By User shows ONLY that tenant's users
  //   3. Users from other tenants are excluded from the scoped view
  //   4. Deselecting the tenant row restores the global view

  it("By User tab shows only the selected tenant's users when a tenant row is clicked", async () => {
    setupDefaultMocks();
    renderPage();
    // "acme" also appears in the Top Spender hero card — scope to the tenant
    // breakdown table so we hit the row that has the setSelected onClick handler.
    await waitFor(() => expect(screen.getByRole("button", { name: "By User" })).toBeInTheDocument());
    await userEvent.click(within(screen.getAllByRole("table")[0]).getByText("acme"));

    await userEvent.click(screen.getByRole("button", { name: "By User" }));

    await waitFor(() => {
      // alice belongs to t1 (acme) — must appear
      expect(screen.getByText("alice@example.com")).toBeInTheDocument();
      // bob belongs to t2 (devteam) — must NOT appear when acme is selected
      expect(screen.queryByText("bob@example.com")).not.toBeInTheDocument();
    });
  });

  it("By User tab shows the other tenant's user when that tenant row is selected", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => expect(screen.getByRole("button", { name: "By User" })).toBeInTheDocument());
    await userEvent.click(within(screen.getAllByRole("table")[0]).getByText("devteam"));

    await userEvent.click(screen.getByRole("button", { name: "By User" }));

    await waitFor(() => {
      expect(screen.getByText("bob@example.com")).toBeInTheDocument();
      expect(screen.queryByText("alice@example.com")).not.toBeInTheDocument();
    });
  });

  it("By User tab shows all users globally when no tenant row is selected", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => expect(screen.getByRole("button", { name: "By User" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "By User" }));

    await waitFor(() => {
      expect(screen.getByText("alice@example.com")).toBeInTheDocument();
      expect(screen.getByText("bob@example.com")).toBeInTheDocument();
    });
  });

  it("deselecting a tenant row (clicking it again) restores the global By User view", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => expect(screen.getByRole("button", { name: "By User" })).toBeInTheDocument());
    // Select acme, then toggle off by clicking again.
    // Scope to the tenant table to avoid hitting the Top Spender hero card.
    await userEvent.click(within(screen.getAllByRole("table")[0]).getByText("acme"));
    // After first click the detail panel opens; getAllByRole("table")[0] is still the tenant table.
    await userEvent.click(within(screen.getAllByRole("table")[0]).getByText("acme"));

    await userEvent.click(screen.getByRole("button", { name: "By User" }));

    await waitFor(() => {
      expect(screen.getByText("alice@example.com")).toBeInTheDocument();
      expect(screen.getByText("bob@example.com")).toBeInTheDocument();
    });
  });

  it("By User tab shows empty state when selected tenant has no user-attributed requests", async () => {
    // t2 (devteam) has by_tenant/by_gateway entries but its user (bob) is
    // removed from by_user — simulates a tenant whose requests all used
    // gateway-level tokens with no user_id set.
    mockApi.get.mockImplementation((path: string) => {
      if (path.startsWith("/stats/analytics")) return Promise.resolve({
        ...ANALYTICS,
        by_user: [
          // Only alice from t1; t2 (devteam) has zero user-attributed requests
          { user_id: "alice@example.com", tenant_id: "t1",
            requests: 300, blocked: 1, cached: 30,
            input_tokens: 400000, output_tokens: 100000,
            cost_usd: 5.40, saved_cost_usd: 0.21, avg_latency_ms: 600, errors: 2 },
        ],
      });
      if (path === "/tenants")                          return Promise.resolve([TENANT1, TENANT2]);
      if (path === "/stats/timeseries?bucket=1d&n=30") return Promise.resolve(GLOBAL_TS);
      if (path.includes("/analytics"))                  return Promise.resolve(DETAIL);
      if (path.includes("/spend"))                      return Promise.resolve(SPEND);
      return Promise.resolve([]);
    });
    renderPage();

    await waitFor(() => expect(screen.getByRole("button", { name: "By User" })).toBeInTheDocument());
    await userEvent.click(within(screen.getAllByRole("table")[0]).getByText("devteam"));

    await userEvent.click(screen.getByRole("button", { name: "By User" }));

    await waitFor(() => {
      // devteam has no user-attributed requests → empty state
      expect(screen.getByText(/No data for this period/i)).toBeInTheDocument();
      // alice (from acme, a different tenant) must NOT bleed in
      expect(screen.queryByText("alice@example.com")).not.toBeInTheDocument();
    });
  });
});

// ---------------------------------------------------------------------------
// Filter bar
// ---------------------------------------------------------------------------

describe("TenantAnalytics — filter bar", () => {
  it("renders the filter input", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() =>
      expect(screen.getByRole("textbox", { name: "Filter rows" })).toBeInTheDocument()
    );
  });

  it("filters By Tenant rows by text", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => expect(screen.getByText("devteam")).toBeInTheDocument());
    const input = screen.getByRole("textbox", { name: "Filter rows" });
    await userEvent.type(input, "acme");
    await waitFor(() => {
      expect(screen.getAllByText("acme").length).toBeGreaterThanOrEqual(1);
      expect(screen.queryByText("devteam")).not.toBeInTheDocument();
    });
  });

  it("shows Clear button when filter text is entered", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("textbox", { name: "Filter rows" }));
    expect(screen.queryByRole("button", { name: "Clear" })).not.toBeInTheDocument();
    const input = screen.getByRole("textbox", { name: "Filter rows" });
    await userEvent.type(input, "x");
    await waitFor(() => expect(screen.getByRole("button", { name: "Clear" })).toBeInTheDocument());
  });

  it("Clear button resets filter and shows all rows", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => expect(screen.getByText("devteam")).toBeInTheDocument());
    const input = screen.getByRole("textbox", { name: "Filter rows" });
    await userEvent.type(input, "acme");
    await waitFor(() => expect(screen.queryByText("devteam")).not.toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Clear" }));
    await waitFor(() => expect(screen.getByText("devteam")).toBeInTheDocument());
  });

  it("filter resets when switching tabs", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => expect(screen.getByText("devteam")).toBeInTheDocument());
    const input = screen.getByRole("textbox", { name: "Filter rows" });
    await userEvent.type(input, "acme");
    await waitFor(() => expect(input).toHaveValue("acme"));
    await userEvent.click(screen.getByRole("button", { name: "By Gateway" }));
    await waitFor(() => expect(input).toHaveValue(""));
  });

  it("filters By User rows by user id text", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By User" }));
    await userEvent.click(screen.getByRole("button", { name: "By User" }));
    await waitFor(() => expect(screen.getByText("alice@example.com")).toBeInTheDocument());
    const input = screen.getByRole("textbox", { name: "Filter rows" });
    await userEvent.type(input, "bob");
    await waitFor(() => {
      expect(screen.getByText("bob@example.com")).toBeInTheDocument();
      expect(screen.queryByText("alice@example.com")).not.toBeInTheDocument();
    });
  });

  it("filters By Model rows by model name", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By Model" }));
    await userEvent.click(screen.getByRole("button", { name: "By Model" }));
    await waitFor(() => expect(screen.getByText("gpt-4o")).toBeInTheDocument());
    const input = screen.getByRole("textbox", { name: "Filter rows" });
    await userEvent.type(input, "gpt");
    await waitFor(() => {
      expect(screen.getByText("gpt-4o")).toBeInTheDocument();
      expect(screen.queryByText("claude-sonnet-4")).not.toBeInTheDocument();
    });
  });
});

// ---------------------------------------------------------------------------
// Detail panel
// ---------------------------------------------------------------------------

describe("TenantAnalytics — detail panel", () => {
  it("opens detail panel when a tenant row is clicked", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => expect(screen.getByText("devteam")).toBeInTheDocument());
    const rows   = screen.getAllByRole("row");
    const acmeRow = rows.find(r => within(r).queryByText("acme") !== null);
    expect(acmeRow).toBeDefined();
    await userEvent.click(acmeRow!);
    await waitFor(() =>
      expect(mockApi.get).toHaveBeenCalledWith(
        expect.stringContaining("/tenants/t1/analytics")
      )
    );
    expect(mockApi.get).toHaveBeenCalledWith(
      expect.stringContaining("/tenants/t1/spend")
    );
  });

  it("shows tenant slug in detail panel header", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => expect(screen.getAllByText("acme").length).toBeGreaterThanOrEqual(1));
    const rows    = screen.getAllByRole("row");
    const acmeRow = rows.find(r => within(r).queryByText("acme") !== null);
    await userEvent.click(acmeRow!);
    await waitFor(() => expect(screen.getAllByText("acme").length).toBeGreaterThanOrEqual(2));
  });

  it("shows plan badge in detail panel", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByText("devteam"));
    const rows    = screen.getAllByRole("row");
    const acmeRow = rows.find(r => within(r).queryByText("acme") !== null);
    await userEvent.click(acmeRow!);
    await waitFor(() => expect(screen.getByText("enterprise")).toBeInTheDocument());
  });

  it("shows top model in detail panel", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByText("devteam"));
    const rows    = screen.getAllByRole("row");
    const acmeRow = rows.find(r => within(r).queryByText("acme") !== null);
    await userEvent.click(acmeRow!);
    await waitFor(() => expect(screen.getAllByText("gpt-4o").length).toBeGreaterThanOrEqual(1));
  });

  it("shows monthly spend history (not daily or total periods)", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByText("devteam"));
    const rows    = screen.getAllByRole("row");
    const acmeRow = rows.find(r => within(r).queryByText("acme") !== null);
    await userEvent.click(acmeRow!);
    await waitFor(() => expect(screen.getByText("2026-03")).toBeInTheDocument());
    expect(screen.getByText("2026-02")).toBeInTheDocument();
    expect(screen.queryByText("2026-03-22")).not.toBeInTheDocument();
    expect(screen.queryByText("total")).not.toBeInTheDocument();
  });

  it("closes the detail panel when close button is clicked", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByText("devteam"));
    const rows    = screen.getAllByRole("row");
    const acmeRow = rows.find(r => within(r).queryByText("acme") !== null);
    await userEvent.click(acmeRow!);
    await waitFor(() => expect(screen.getByLabelText("Close")).toBeInTheDocument());
    await userEvent.click(screen.getByLabelText("Close"));
    await waitFor(() => expect(screen.queryByLabelText("Close")).not.toBeInTheDocument());
  });

  it("shows budget gauge when tenant has a budget", async () => {
    setupDefaultMocks();
    renderPage();
    await waitFor(() => screen.getByText("devteam"));
    const rows    = screen.getAllByRole("row");
    const acmeRow = rows.find(r => within(r).queryByText("acme") !== null);
    await userEvent.click(acmeRow!);
    await waitFor(() => expect(screen.getByText("Budget Utilization")).toBeInTheDocument());
  });
});

// ---------------------------------------------------------------------------
// Empty states
// ---------------------------------------------------------------------------

describe("TenantAnalytics — empty states", () => {
  it("By Gateway tab shows empty state when no gateway data", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path.startsWith("/stats/analytics")) return Promise.resolve({
        ...EMPTY_ANALYTICS,
        by_tenant:  ANALYTICS.by_tenant,
        top_models: ANALYTICS.top_models,
      });
      if (path === "/tenants") return Promise.resolve([TENANT1, TENANT2]);
      return Promise.resolve([]);
    });
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By Gateway" }));
    await userEvent.click(screen.getByRole("button", { name: "By Gateway" }));
    await waitFor(() =>
      expect(screen.getByText(/No data for this period/i)).toBeInTheDocument()
    );
  });

  it("By Model tab shows empty state when no model data", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path.startsWith("/stats/analytics")) return Promise.resolve(EMPTY_ANALYTICS);
      if (path === "/tenants") return Promise.resolve([TENANT1]);
      return Promise.resolve([]);
    });
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By Model" }));
    await userEvent.click(screen.getByRole("button", { name: "By Model" }));
    await waitFor(() =>
      expect(screen.getByText(/No data for this period/i)).toBeInTheDocument()
    );
  });

  it("By Provider tab shows empty state when no model data to aggregate", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path.startsWith("/stats/analytics")) return Promise.resolve(EMPTY_ANALYTICS);
      if (path === "/tenants") return Promise.resolve([TENANT1]);
      return Promise.resolve([]);
    });
    renderPage();
    await waitFor(() => screen.getByRole("button", { name: "By Provider" }));
    await userEvent.click(screen.getByRole("button", { name: "By Provider" }));
    await waitFor(() =>
      expect(screen.getByText(/No data for this period/i)).toBeInTheDocument()
    );
  });
});
