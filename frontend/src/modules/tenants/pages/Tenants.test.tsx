import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Routes, Route } from "react-router-dom";
import Tenants from "./Tenants";
import type { Tenant, Gateway } from "src/api/types";

vi.mock("src/api/client", () => ({
  api: {
    get: vi.fn(),
    post: vi.fn(),
    patch: vi.fn(),
    delete: vi.fn(),
  },
}));

import { api } from "src/api/client";
const mockApi = api as {
  get: ReturnType<typeof vi.fn>;
  post: ReturnType<typeof vi.fn>;
  patch: ReturnType<typeof vi.fn>;
  delete: ReturnType<typeof vi.fn>;
};

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const T1: Tenant = { id: "t1", slug: "acme", plan: "standard", budget_usd: 50, budget_period: "monthly", created_at: "2024-01-01T00:00:00Z" };
const T2: Tenant = { id: "t2", slug: "globex", plan: "enterprise", budget_usd: null, budget_period: "monthly", created_at: "2024-02-01T00:00:00Z" };
const T3: Tenant = { id: "t3", slug: "initech", plan: "free", budget_usd: null, budget_period: "monthly", created_at: "2024-03-01T00:00:00Z" };

const GW: Gateway = { id: "gw1", slug: "main", tenant_id: "t1", config: { auth_required: true, cache_ttl: 300 }, created_at: "2024-01-05T00:00:00Z" };

function setupDefaultMocks(tenants = [T1, T2, T3]) {
  mockApi.get.mockImplementation((path: string) => {
    if (path === "/tenants") return Promise.resolve(tenants);
    if (path === "/tenants/t1/gateways") return Promise.resolve([GW]);
    if (path === "/tenants/t2/gateways") return Promise.resolve([]);
    if (path === "/tenants/t3/gateways") return Promise.resolve([]);
    return Promise.resolve([]);
  });
}

function renderAtPath(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/tenants" element={<Tenants />} />
        <Route path="/tenants/:tenantId" element={<Tenants />} />
        <Route path="/tenants/:tenantId/gateways" element={<div>gateways page</div>} />
        <Route path="/tenants/:tenantId/gateways/:gwId" element={<div>gateway detail</div>} />
      </Routes>
    </MemoryRouter>
  );
}

beforeEach(() => {
  vi.clearAllMocks();
});

// ---------------------------------------------------------------------------
// List view
// ---------------------------------------------------------------------------

describe("Tenants — list view", () => {
  it("shows page title and tenant count", async () => {
    setupDefaultMocks();
    renderAtPath("/tenants");
    await waitFor(() => {
      expect(screen.getByText("Tenants")).toBeInTheDocument();
      expect(screen.getByText(/3 tenants/i)).toBeInTheDocument();
    });
  });

  it("lists all tenant slugs", async () => {
    setupDefaultMocks();
    renderAtPath("/tenants");
    await waitFor(() => {
      expect(screen.getByText("acme")).toBeInTheDocument();
      expect(screen.getByText("globex")).toBeInTheDocument();
      expect(screen.getByText("initech")).toBeInTheDocument();
    });
  });

  it("shows plan badges", async () => {
    setupDefaultMocks();
    renderAtPath("/tenants");
    await waitFor(() => {
      expect(screen.getByText("standard")).toBeInTheDocument();
      expect(screen.getByText("enterprise")).toBeInTheDocument();
      expect(screen.getByText("free")).toBeInTheDocument();
    });
  });

  it("shows budget for tenants that have one", async () => {
    setupDefaultMocks();
    renderAtPath("/tenants");
    await waitFor(() => expect(screen.getByText("$50.00")).toBeInTheDocument());
  });

  it("shows 'unlimited' for tenants without budget", async () => {
    setupDefaultMocks();
    renderAtPath("/tenants");
    await waitFor(() => {
      const unlimitedCells = screen.getAllByText(/unlimited/i);
      expect(unlimitedCells.length).toBeGreaterThanOrEqual(2);
    });
  });

  it("shows empty state when no tenants", async () => {
    setupDefaultMocks([]);
    renderAtPath("/tenants");
    await waitFor(() => expect(screen.getByText(/no tenants yet/i)).toBeInTheDocument());
  });

  it("shows 1 tenant (singular)", async () => {
    setupDefaultMocks([T1]);
    renderAtPath("/tenants");
    await waitFor(() => expect(screen.getByText(/1 tenant$/i)).toBeInTheDocument());
  });
});

// ---------------------------------------------------------------------------
// Create modal
// ---------------------------------------------------------------------------

describe("Tenants — create modal", () => {
  it("opens modal on '+ New Tenant' click", async () => {
    const user = userEvent.setup();
    setupDefaultMocks();
    renderAtPath("/tenants");
    await waitFor(() => screen.getByText("+ New Tenant"));

    await user.click(screen.getByText("+ New Tenant"));
    expect(screen.getByText("New Tenant")).toBeInTheDocument();
  });

  it("closes modal on Cancel click", async () => {
    const user = userEvent.setup();
    setupDefaultMocks();
    renderAtPath("/tenants");
    await waitFor(() => screen.getByText("+ New Tenant"));

    await user.click(screen.getByText("+ New Tenant"));
    await user.click(screen.getByText("Cancel"));
    expect(screen.queryByText("New Tenant")).not.toBeInTheDocument();
  });

  it("slug input enforces lowercase and strips non-slug chars", async () => {
    const user = userEvent.setup();
    setupDefaultMocks();
    renderAtPath("/tenants");
    await waitFor(() => screen.getByText("+ New Tenant"));

    await user.click(screen.getByText("+ New Tenant"));
    const slugInput = screen.getByPlaceholderText("my-company");
    // "Hello World!" → toLowerCase → "hello world!" → strip [^a-z0-9-] → "helloworld"
    await user.type(slugInput, "Hello World!");
    expect((slugInput as HTMLInputElement).value).toBe("helloworld");
  });

  it("submits POST to /tenants with correct payload", async () => {
    const user = userEvent.setup();
    mockApi.post.mockResolvedValue({ id: "t99", slug: "newco", plan: "standard", budget_usd: null, budget_period: "monthly", created_at: "2024-03-01T00:00:00Z" });
    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([T1]);
      return Promise.resolve([]);
    });
    renderAtPath("/tenants");
    await waitFor(() => screen.getByText("+ New Tenant"));

    await user.click(screen.getByText("+ New Tenant"));
    await user.type(screen.getByPlaceholderText("my-company"), "newco");
    await user.click(screen.getByText("Create Tenant"));

    await waitFor(() => expect(mockApi.post).toHaveBeenCalledWith("/tenants", expect.objectContaining({ slug: "newco" })));
  });

  it("shows API error in modal when create fails", async () => {
    const user = userEvent.setup();
    mockApi.post.mockRejectedValue(new Error("slug already taken"));
    setupDefaultMocks();
    renderAtPath("/tenants");
    await waitFor(() => screen.getByText("+ New Tenant"));

    await user.click(screen.getByText("+ New Tenant"));
    await user.type(screen.getByPlaceholderText("my-company"), "acme");
    await user.click(screen.getByText("Create Tenant"));

    await waitFor(() => expect(screen.getByText("slug already taken")).toBeInTheDocument());
  });
});

// ---------------------------------------------------------------------------
// Detail view
// ---------------------------------------------------------------------------

describe("Tenants — detail view", () => {
  it("renders tenant detail when navigating to /tenants/:id", async () => {
    setupDefaultMocks();
    renderAtPath("/tenants/t1");
    await waitFor(() => {
      expect(screen.getByText(/tenant:/i)).toBeInTheDocument();
      expect(screen.getAllByText("acme").length).toBeGreaterThan(0);
    });
  });

  it("shows tenant's gateways in detail view", async () => {
    setupDefaultMocks();
    renderAtPath("/tenants/t1");
    await waitFor(() => expect(screen.getByText("main")).toBeInTheDocument());
  });

  it("redirects to /tenants when tenant id not found in list", async () => {
    setupDefaultMocks([T1]);
    renderAtPath("/tenants/t-unknown");
    await waitFor(() => {
      // Navigate replaces with /tenants so the list heading appears
      expect(screen.getByText("Tenants")).toBeInTheDocument();
    });
  });

  it("shows no-gateways message when tenant has none", async () => {
    setupDefaultMocks();
    renderAtPath("/tenants/t2");
    await waitFor(() => expect(screen.getByText(/no gateways yet/i)).toBeInTheDocument());
  });
});
