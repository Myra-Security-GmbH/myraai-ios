import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Routes, Route } from "react-router-dom";
import Gateways from "./Gateways";
import type { Gateway, Tenant } from "src/api/types";

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
const mockApi = api as {
  get: ReturnType<typeof vi.fn>;
  post: ReturnType<typeof vi.fn>;
  patch: ReturnType<typeof vi.fn>;
  delete: ReturnType<typeof vi.fn>;
};

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const TENANT: Tenant = { id: "t1", slug: "acme", plan: "standard", budget_usd: null, created_at: "2024-01-01T00:00:00Z" };
const TENANT2: Tenant = { id: "t2", slug: "globex", plan: "free", budget_usd: null, created_at: "2024-01-02T00:00:00Z" };

const GW1: Gateway = {
  id: "gw1", slug: "prod", tenant_id: "t1",
  config: { auth_required: true, cache_ttl: 300, retry_count: 2, timeout_ms: 120000, budget_usd: 50, rate_limit: { requests: 100, window_sec: 60 } },
  created_at: "2024-02-01T00:00:00Z",
};
const GW2: Gateway = {
  id: "gw2", slug: "staging", tenant_id: "t1",
  config: { auth_required: false, cache_ttl: 0, retry_count: 0, timeout_ms: 30000 },
  created_at: "2024-02-02T00:00:00Z",
};

const GW_WITH_DETECTORS: Gateway = {
  id: "gw4", slug: "secure", tenant_id: "t1",
  config: {
    auth_required: true,
    detectors: [{ type: "keyword", name: "kw-check", action: "flag", keywords: ["secret"] }],
  },
  created_at: "2024-02-04T00:00:00Z",
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function setupDefaultMocks(gateways: Gateway[] = [GW1, GW2]) {
  mockApi.get.mockImplementation((path: string) => {
    if (path === "/tenants") return Promise.resolve([TENANT, TENANT2]);
    if (path === `/tenants/${TENANT.id}/gateways`) return Promise.resolve(gateways);
    if (path === `/tenants/${TENANT2.id}/gateways`) return Promise.resolve([]);
    if (path.endsWith("/tokens")) return Promise.resolve([]);
    if (path.endsWith("/keys")) return Promise.resolve([]);
    if (path.endsWith("/rules")) return Promise.resolve([]);
    return Promise.resolve([]);
  });
}

function renderAtPath(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/tenants/:tenantId/gateways" element={<Gateways />} />
        <Route path="/tenants/:tenantId/gateways/:gatewayId" element={<Gateways />} />
        <Route path="/gateways" element={<Gateways />} />
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

describe("Gateways — list view", () => {
  it("shows page heading", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Gateways" })).toBeInTheDocument());
  });

  it("shows tenant subtitle when tenant is selected", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => expect(screen.getAllByText("acme").length).toBeGreaterThanOrEqual(1));
  });

  it("renders a row for each gateway", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => expect(screen.getByText("prod")).toBeInTheDocument());
    expect(screen.getByText("staging")).toBeInTheDocument();
  });

  it("shows tenant selector buttons", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => {
      const btns = screen.getAllByRole("button", { name: /acme|globex/ });
      expect(btns.length).toBeGreaterThanOrEqual(2);
    });
  });

  it("shows empty state when tenant has no gateways", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT2.id}/gateways`);
    await waitFor(() => expect(screen.getByText(/No gateways for/i)).toBeInTheDocument());
  });

  it("shows + New Gateway button when a tenant is selected", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => expect(screen.getByRole("button", { name: "+ New Gateway" })).toBeInTheDocument());
  });

  it("renders Open → button for each gateway", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => {
      const btns = screen.getAllByRole("button", { name: "Open →" });
      expect(btns).toHaveLength(2);
    });
  });
});

// ---------------------------------------------------------------------------
// Navigation to detail view
// ---------------------------------------------------------------------------

describe("Gateways — navigation to detail", () => {
  it("navigates to /tenants/:id/gateways/:gwId when Open → is clicked", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => expect(screen.getAllByRole("button", { name: "Open →" })).toHaveLength(2));
    await userEvent.click(screen.getAllByRole("button", { name: "Open →" })[0]);
    await waitFor(() => expect(screen.getByRole("heading", { level: 1, name: /acme \/ prod/i })).toBeInTheDocument());
  });

  it("navigates to detail when table row is clicked", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => expect(screen.getByText("prod")).toBeInTheDocument());
    const rows = screen.getAllByRole("row");
    const prodRow = rows.find((r) => within(r).queryByText("prod"))!;
    await userEvent.click(prodRow);
    await waitFor(() => expect(screen.getByRole("heading", { level: 1, name: /acme \/ prod/i })).toBeInTheDocument());
  });
});

// ---------------------------------------------------------------------------
// Detail view
// ---------------------------------------------------------------------------

describe("Gateways — detail view", () => {
  it("renders detail when gatewayId param matches", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("heading", { level: 1, name: /acme \/ prod/i })).toBeInTheDocument());
  });

  it("redirects to list when gatewayId not found", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/does-not-exist`);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Gateways" })).toBeInTheDocument());
  });

  it("shows ← Gateways back button in detail view", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "← Gateways" })).toBeInTheDocument());
  });

  it("navigates back to list when ← Gateways is clicked", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "← Gateways" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "← Gateways" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Gateways" })).toBeInTheDocument());
  });

  it("shows gateway config stats (budget, cache, retries, timeout, auth)", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByText(/\$50/)).toBeInTheDocument()); // budget
    expect(screen.getByText("300s")).toBeInTheDocument();  // cache ttl
    expect(screen.getByText("2")).toBeInTheDocument();     // retries
    expect(screen.getByText("120000ms")).toBeInTheDocument();
    expect(screen.getByText("required")).toBeInTheDocument();
  });

  it("shows Provider Keys card and Auth Tokens card", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Provider Keys" })).toBeInTheDocument());
    expect(screen.getByRole("heading", { name: "Auth Tokens" })).toBeInTheDocument();
  });

  it("shows Routing Rules card", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Routing Rules" })).toBeInTheDocument());
  });

  it("shows Detectors card on the detail page", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Detectors" })).toBeInTheDocument());
  });
});

// ---------------------------------------------------------------------------
// Edit modal — no longer contains DetectorBuilder
// ---------------------------------------------------------------------------

describe("Gateways — edit modal", () => {
  it("opens edit modal when Edit is clicked", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Edit" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Edit" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: /Edit Gateway: prod/i })).toBeInTheDocument());
  });

  it("edit modal contains basic settings fields", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Edit" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Edit" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: /Edit Gateway: prod/i })).toBeInTheDocument());
    expect(screen.getByLabelText(/Budget/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/Cache TTL/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/Retry Count/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/Timeout/i)).toBeInTheDocument();
  });

  it("edit modal does NOT contain DetectorBuilder", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Edit" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Edit" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: /Edit Gateway: prod/i })).toBeInTheDocument());
    // DetectorBuilder has a label "Detectors (N)" — should NOT be inside the modal
    const modal = screen.getByRole("heading", { name: /Edit Gateway: prod/i }).closest("div")!;
    expect(within(modal).queryByText(/Detectors \(\d+\)/)).not.toBeInTheDocument();
  });

  it("submits PATCH with correct config on save", async () => {
    setupDefaultMocks();
    mockApi.patch.mockResolvedValue({ ok: true });
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Edit" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Edit" }));
    await waitFor(() => expect(screen.getByLabelText(/Cache TTL/i)).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Save Changes" }));
    await waitFor(() => expect(mockApi.patch).toHaveBeenCalledWith(
      `/gateways/${GW1.id}`,
      expect.objectContaining({ config: expect.any(Object) })
    ));
  });

  it("closes modal on Cancel", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Edit" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Edit" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: /Edit Gateway: prod/i })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(screen.queryByRole("heading", { name: /Edit Gateway: prod/i })).not.toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Detectors card
// ---------------------------------------------------------------------------

describe("Gateways — Detectors card", () => {
  it("shows DetectorBuilder on the detail page", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Detectors" })).toBeInTheDocument());
    expect(screen.getByText(/Detectors \(0\)/)).toBeInTheDocument();
    expect(screen.getByText(/No detectors configured/i)).toBeInTheDocument();
  });

  it("Save Detectors button is disabled when no changes made", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Save Detectors" })).toBeInTheDocument());
    expect(screen.getByRole("button", { name: "Save Detectors" })).toBeDisabled();
  });

  it("Save Detectors button becomes enabled after adding a detector", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Save Detectors" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /\+ Keyword/i }));
    expect(screen.getByRole("button", { name: "Save Detectors" })).not.toBeDisabled();
  });

  it("calls PATCH /gateways/:id with detectors when Save Detectors is clicked", async () => {
    setupDefaultMocks();
    mockApi.patch.mockResolvedValue({ ok: true });
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Save Detectors" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /\+ Keyword/i }));
    await userEvent.click(screen.getByRole("button", { name: "Save Detectors" }));
    await waitFor(() => expect(mockApi.patch).toHaveBeenCalledWith(
      `/gateways/${GW1.id}`,
      expect.objectContaining({
        config: expect.objectContaining({ detectors: expect.any(Array) }),
      })
    ));
  });

  it("Save Detectors button becomes disabled again after successful save", async () => {
    setupDefaultMocks();
    mockApi.patch.mockResolvedValue({ ok: true });
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Save Detectors" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /\+ Keyword/i }));
    await userEvent.click(screen.getByRole("button", { name: "Save Detectors" }));
    await waitFor(() => expect(screen.getByRole("button", { name: "Save Detectors" })).toBeDisabled());
  });

  it("shows existing detectors from gateway config", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TENANT]);
      if (path === `/tenants/${TENANT.id}/gateways`) return Promise.resolve([GW_WITH_DETECTORS]);
      if (path.endsWith("/tokens")) return Promise.resolve([]);
      if (path.endsWith("/keys")) return Promise.resolve([]);
      if (path.endsWith("/rules")) return Promise.resolve([]);
      return Promise.resolve([]);
    });
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW_WITH_DETECTORS.id}`);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Detectors" })).toBeInTheDocument());
    expect(screen.getAllByText("kw-check")[0]).toBeInTheDocument();
    expect(screen.getByText(/Detectors \(1\)/)).toBeInTheDocument();
  });

});

// ---------------------------------------------------------------------------
// Create gateway modal
// ---------------------------------------------------------------------------

describe("Gateways — create gateway modal", () => {
  it("opens create modal when + New Gateway is clicked", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => expect(screen.getByRole("button", { name: "+ New Gateway" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ New Gateway" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: "New Gateway" })).toBeInTheDocument());
  });

  it("create modal contains slug field and DetectorBuilder", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => expect(screen.getByRole("button", { name: "+ New Gateway" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ New Gateway" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: "New Gateway" })).toBeInTheDocument());
    expect(screen.getByPlaceholderText("prod")).toBeInTheDocument();
    // DetectorBuilder is still in the create modal
    expect(screen.getByText(/Detectors \(0\)/)).toBeInTheDocument();
  });

  it("closes create modal on Cancel", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => expect(screen.getByRole("button", { name: "+ New Gateway" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ New Gateway" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: "New Gateway" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(screen.queryByRole("heading", { name: "New Gateway" })).not.toBeInTheDocument();
  });

  it("submits POST with slug and detectors", async () => {
    setupDefaultMocks();
    mockApi.post.mockResolvedValue({ id: "new-gw", slug: "dev" });
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => expect(screen.getByRole("button", { name: "+ New Gateway" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ New Gateway" }));
    await waitFor(() => expect(screen.getByPlaceholderText("prod")).toBeInTheDocument());
    await userEvent.type(screen.getByPlaceholderText("prod"), "dev");
    await userEvent.click(screen.getByRole("button", { name: "Create Gateway" }));
    await waitFor(() => expect(mockApi.post).toHaveBeenCalledWith(
      `/tenants/${TENANT.id}/gateways`,
      expect.objectContaining({ slug: "dev", config: expect.objectContaining({ detectors: [] }) })
    ));
  });
});

// ---------------------------------------------------------------------------
// Delete gateway
// ---------------------------------------------------------------------------

describe("Gateways — delete gateway", () => {
  it("calls DELETE /gateways/:id and navigates back on confirm", async () => {
    setupDefaultMocks();
    mockApi.delete.mockResolvedValue({ ok: true });
    vi.spyOn(window, "confirm").mockReturnValue(true);
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Delete" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Delete" }));
    await waitFor(() => expect(mockApi.delete).toHaveBeenCalledWith(`/gateways/${GW1.id}`));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Gateways" })).toBeInTheDocument());
  });

  it("does not delete when confirm is cancelled", async () => {
    setupDefaultMocks();
    vi.spyOn(window, "confirm").mockReturnValue(false);
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Delete" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Delete" }));
    expect(mockApi.delete).not.toHaveBeenCalled();
  });
});
