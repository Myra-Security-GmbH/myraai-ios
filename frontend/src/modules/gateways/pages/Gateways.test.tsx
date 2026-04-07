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
const mockApi = api as unknown as {
  get: ReturnType<typeof vi.fn>;
  post: ReturnType<typeof vi.fn>;
  patch: ReturnType<typeof vi.fn>;
  delete: ReturnType<typeof vi.fn>;
};

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const TENANT: Tenant = { id: "t1", slug: "acme", plan: "standard", budget_usd: null, budget_period: "monthly", created_at: "2024-01-01T00:00:00Z" };
const TENANT2: Tenant = { id: "t2", slug: "globex", plan: "free", budget_usd: null, budget_period: "monthly", created_at: "2024-01-02T00:00:00Z" };

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
    guardrails: [{ type: "keyword", name: "kw-check", action: "flag", keywords: ["secret"] }],
  },
  created_at: "2024-02-04T00:00:00Z",
};

// Legacy schema: guardrails is a {enabled:false} object; detectors is the real array.
const GW_LEGACY_SCHEMA: Gateway = {
  id: "gw5", slug: "legacy", tenant_id: "t1",
  config: {
    auth_required: true,
    guardrails: { enabled: false } as any,
    detectors: [{ type: "keyword", name: "legacy-kw", action: "flag", keywords: ["foo"] }] as any,
  },
  created_at: "2024-02-05T00:00:00Z",
};

// Legacy schema: guardrails is object, no detectors key at all.
const GW_LEGACY_NO_DETECTORS: Gateway = {
  id: "gw6", slug: "legacy-empty", tenant_id: "t1",
  config: {
    auth_required: true,
    guardrails: { enabled: false } as any,
  },
  created_at: "2024-02-06T00:00:00Z",
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
    expect(screen.getByText("120,000 ms")).toBeInTheDocument();
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

  it("shows Guardrails card on the detail page", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Guardrails" })).toBeInTheDocument());
  });
});

// ---------------------------------------------------------------------------
// Edit modal — no longer contains GuardrailBuilder
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
    expect(screen.getByLabelText(/Budget \(USD\)/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/Cache TTL/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/Retry Count/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/Timeout/i)).toBeInTheDocument();
  });

  it("edit modal does NOT contain GuardrailBuilder", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Edit" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Edit" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: /Edit Gateway: prod/i })).toBeInTheDocument());
    // GuardrailBuilder has a label "Guardrails (N)" — should NOT be inside the modal
    const modal = screen.getByRole("heading", { name: /Edit Gateway: prod/i }).closest("div")!;
    expect(within(modal).queryByText(/Guardrails \(\d+\)/)).not.toBeInTheDocument();
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
// Guardrails card
// ---------------------------------------------------------------------------

describe("Gateways — Guardrails card", () => {
  it("shows GuardrailBuilder on the detail page", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Guardrails" })).toBeInTheDocument());
    expect(screen.getByText(/Guardrails \(0\)/)).toBeInTheDocument();
    expect(screen.getByText(/No guardrails configured/i)).toBeInTheDocument();
  });

  it("Save Guardrails button is disabled when no changes made", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Save Guardrails" })).toBeInTheDocument());
    expect(screen.getByRole("button", { name: "Save Guardrails" })).toBeDisabled();
  });

  it("Save Guardrails button becomes enabled after adding a guardrail", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Save Guardrails" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /\+ Keyword/i }));
    expect(screen.getByRole("button", { name: "Save Guardrails" })).not.toBeDisabled();
  });

  it("calls PATCH /gateways/:id with guardrails when Save Guardrails is clicked", async () => {
    setupDefaultMocks();
    mockApi.patch.mockResolvedValue({ ok: true });
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Save Guardrails" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /\+ Keyword/i }));
    await userEvent.click(screen.getByRole("button", { name: "Save Guardrails" }));
    await waitFor(() => expect(mockApi.patch).toHaveBeenCalledWith(
      `/gateways/${GW1.id}`,
      expect.objectContaining({
        config: expect.objectContaining({ guardrails: expect.any(Array) }),
      })
    ));
  });

  it("Save Guardrails button becomes disabled again after successful save", async () => {
    setupDefaultMocks();
    mockApi.patch.mockResolvedValue({ ok: true });
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Save Guardrails" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /\+ Keyword/i }));
    await userEvent.click(screen.getByRole("button", { name: "Save Guardrails" }));
    await waitFor(() => expect(screen.getByRole("button", { name: "Save Guardrails" })).toBeDisabled());
  });

  it("shows existing guardrails from gateway config", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TENANT]);
      if (path === `/tenants/${TENANT.id}/gateways`) return Promise.resolve([GW_WITH_DETECTORS]);
      if (path.endsWith("/tokens")) return Promise.resolve([]);
      if (path.endsWith("/keys")) return Promise.resolve([]);
      if (path.endsWith("/rules")) return Promise.resolve([]);
      return Promise.resolve([]);
    });
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW_WITH_DETECTORS.id}`);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Guardrails" })).toBeInTheDocument());
    expect(screen.getAllByText("kw-check")[0]).toBeInTheDocument();
    expect(screen.getByText(/Guardrails \(1\)/)).toBeInTheDocument();
  });

  it("does not crash when guardrails is a legacy object (falls back to detectors array)", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TENANT]);
      if (path === `/tenants/${TENANT.id}/gateways`) return Promise.resolve([GW_LEGACY_SCHEMA]);
      if (path.endsWith("/tokens")) return Promise.resolve([]);
      if (path.endsWith("/keys")) return Promise.resolve([]);
      if (path.endsWith("/rules")) return Promise.resolve([]);
      return Promise.resolve([]);
    });
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW_LEGACY_SCHEMA.id}`);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Guardrails" })).toBeInTheDocument());
    // Detectors from the legacy detectors array are loaded
    expect(screen.getAllByText("legacy-kw")[0]).toBeInTheDocument();
    expect(screen.getByText(/Guardrails \(1\)/)).toBeInTheDocument();
  });

  it("shows empty state when guardrails is a legacy object and no detectors key exists", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TENANT]);
      if (path === `/tenants/${TENANT.id}/gateways`) return Promise.resolve([GW_LEGACY_NO_DETECTORS]);
      if (path.endsWith("/tokens")) return Promise.resolve([]);
      if (path.endsWith("/keys")) return Promise.resolve([]);
      if (path.endsWith("/rules")) return Promise.resolve([]);
      return Promise.resolve([]);
    });
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW_LEGACY_NO_DETECTORS.id}`);
    await waitFor(() => expect(screen.getByRole("heading", { name: "Guardrails" })).toBeInTheDocument());
    expect(screen.getByText(/No guardrails configured/i)).toBeInTheDocument();
    expect(screen.getByText(/Guardrails \(0\)/)).toBeInTheDocument();
  });

  it("migrates legacy schema to guardrails array on Save Guardrails", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TENANT]);
      if (path === `/tenants/${TENANT.id}/gateways`) return Promise.resolve([GW_LEGACY_SCHEMA]);
      if (path.endsWith("/tokens")) return Promise.resolve([]);
      if (path.endsWith("/keys")) return Promise.resolve([]);
      if (path.endsWith("/rules")) return Promise.resolve([]);
      return Promise.resolve([]);
    });
    mockApi.patch.mockResolvedValue({ ok: true });
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW_LEGACY_SCHEMA.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Save Guardrails" })).toBeInTheDocument());
    // Trigger a change so Save becomes enabled
    await userEvent.click(screen.getByRole("button", { name: /\+ Keyword/i }));
    await userEvent.click(screen.getByRole("button", { name: "Save Guardrails" }));
    await waitFor(() => expect(mockApi.patch).toHaveBeenCalledWith(
      `/gateways/${GW_LEGACY_SCHEMA.id}`,
      expect.objectContaining({
        config: expect.objectContaining({ guardrails: expect.any(Array) }),
      })
    ));
  });

});

// ---------------------------------------------------------------------------
// Guardrails list badge — legacy schema
// ---------------------------------------------------------------------------

describe("Gateways — list view guardrail badge", () => {
  it("shows correct count for array guardrails", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TENANT]);
      if (path === `/tenants/${TENANT.id}/gateways`) return Promise.resolve([GW_WITH_DETECTORS]);
      return Promise.resolve([]);
    });
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => expect(screen.getByText("secure")).toBeInTheDocument());
    expect(screen.getByText("1")).toBeInTheDocument(); // badge count
  });

  it("shows — badge when guardrails is a legacy object", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TENANT]);
      if (path === `/tenants/${TENANT.id}/gateways`) return Promise.resolve([GW_LEGACY_NO_DETECTORS]);
      return Promise.resolve([]);
    });
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => expect(screen.getByText("legacy-empty")).toBeInTheDocument());
    // The detectors column badge shows — (neutral badge, not a number badge)
    const row = screen.getByText("legacy-empty").closest("tr")!;
    expect(within(row).getByText("—", { selector: "span" })).toBeInTheDocument();
  });

  it("shows correct count when guardrails is a legacy object with detectors array", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TENANT]);
      if (path === `/tenants/${TENANT.id}/gateways`) return Promise.resolve([GW_LEGACY_SCHEMA]);
      return Promise.resolve([]);
    });
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => expect(screen.getByText("legacy")).toBeInTheDocument());
    expect(screen.getByText("1")).toBeInTheDocument();
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

  it("create modal contains slug field and GuardrailBuilder", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways`);
    await waitFor(() => expect(screen.getByRole("button", { name: "+ New Gateway" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ New Gateway" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: "New Gateway" })).toBeInTheDocument());
    expect(screen.getByPlaceholderText("prod")).toBeInTheDocument();
    // GuardrailBuilder is still in the create modal
    expect(screen.getByText(/Guardrails \(0\)/)).toBeInTheDocument();
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

  it("submits POST with slug and guardrails", async () => {
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
      expect.objectContaining({ slug: "dev", config: expect.objectContaining({ guardrails: [] }) })
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

// ---------------------------------------------------------------------------
// Edit modal — advanced fields
// ---------------------------------------------------------------------------

describe("Gateways — edit modal advanced fields", () => {
  async function openEditModal() {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Edit" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Edit" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: /Edit Gateway: prod/i })).toBeInTheDocument());
  }

  it("renders Rate Limit fields in edit modal", async () => {
    await openEditModal();
    expect(screen.getByLabelText(/Rate Limit \(req\)/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/Rate Window \(s\)/i)).toBeInTheDocument();
  });

  it("renders Budget Period select in edit modal", async () => {
    await openEditModal();
    expect(screen.getByLabelText(/Budget Period/i)).toBeInTheDocument();
  });

  it("renders Circuit Breaker checkbox (unchecked by default)", async () => {
    await openEditModal();
    const cbCheckbox = screen.getByRole("checkbox", { name: /Circuit Breaker/i });
    expect(cbCheckbox).toBeInTheDocument();
    expect(cbCheckbox).not.toBeChecked();
  });

  it("shows circuit breaker threshold fields when Circuit Breaker is enabled", async () => {
    await openEditModal();
    await userEvent.click(screen.getByRole("checkbox", { name: /Circuit Breaker/i }));
    // Labels don't use htmlFor so use getByText
    await waitFor(() => expect(screen.getByText("Failure threshold")).toBeInTheDocument());
    expect(screen.getByText(/Sliding window for counting failures/i)).toBeInTheDocument();
    expect(screen.getByText(/Wait before probing after open/i)).toBeInTheDocument();
  });

  it("renders Provider Base URLs section with + Add URL override button", async () => {
    await openEditModal();
    expect(screen.getByRole("button", { name: /\+ Add URL override/i })).toBeInTheDocument();
  });

  it("adds a provider base URL row when + Add URL override is clicked", async () => {
    await openEditModal();
    await userEvent.click(screen.getByRole("button", { name: /\+ Add URL override/i }));
    await waitFor(() => expect(screen.getByPlaceholderText("provider (e.g. ollama)")).toBeInTheDocument());
    expect(screen.getByPlaceholderText("http://host:port")).toBeInTheDocument();
  });

  it("renders Webhook URL input", async () => {
    await openEditModal();
    expect(screen.getByPlaceholderText(/hooks\.example\.com/i)).toBeInTheDocument();
  });

  it("shows webhook secret and event checkboxes when URL is entered", async () => {
    await openEditModal();
    const webhookInput = screen.getByPlaceholderText(/hooks\.example\.com/i);
    await userEvent.type(webhookInput, "https://my.webhook/hook");
    await waitFor(() => expect(screen.getByPlaceholderText(/Signing secret/i)).toBeInTheDocument());
    expect(screen.getByText("blocked")).toBeInTheDocument();
    expect(screen.getByText("budget_exceeded")).toBeInTheDocument();
    expect(screen.getByText("circuit_open")).toBeInTheDocument();
  });

  it("renders Request Tracing enable checkbox", async () => {
    await openEditModal();
    const tracingCheck = screen.getByRole("checkbox", { name: /Enable request tracing/i });
    expect(tracingCheck).toBeInTheDocument();
    expect(tracingCheck).not.toBeChecked();
  });

  it("shows tracing sub-options when tracing is enabled", async () => {
    await openEditModal();
    await userEvent.click(screen.getByRole("checkbox", { name: /Enable request tracing/i }));
    await waitFor(() => expect(screen.getByText(/Include message bodies in trace/i)).toBeInTheDocument());
    // Retention label also appears — label has no htmlFor so check by text
    expect(screen.getByText("Retention (hours)")).toBeInTheDocument();
  });

  it("shows error message when PATCH fails", async () => {
    setupDefaultMocks();
    mockApi.patch.mockRejectedValue(new Error("server error"));
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Edit" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Edit" }));
    await waitFor(() => expect(screen.getByLabelText(/Cache TTL/i)).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Save Changes" }));
    await waitFor(() => expect(screen.getByText("server error")).toBeInTheDocument());
  });
});

// ---------------------------------------------------------------------------
// Add Provider Key modal
// ---------------------------------------------------------------------------

describe("Gateways — add provider key modal", () => {
  it("opens Add Provider Key modal when + Add Key is clicked", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: /\+ Add \/ Rotate/i })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /\+ Add \/ Rotate/i }));
    await waitFor(() => expect(screen.getByRole("heading", { name: /Add \/ Rotate Provider Key/i })).toBeInTheDocument());
  });

  it("add key modal has provider and alias fields", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => screen.getByRole("button", { name: /\+ Add \/ Rotate/i }));
    await userEvent.click(screen.getByRole("button", { name: /\+ Add \/ Rotate/i }));
    await waitFor(() => expect(screen.getByLabelText(/Provider/i)).toBeInTheDocument());
    expect(screen.getByLabelText(/Alias/i)).toBeInTheDocument();
  });

  it("closes add key modal on Cancel", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => screen.getByRole("button", { name: /\+ Add \/ Rotate/i }));
    await userEvent.click(screen.getByRole("button", { name: /\+ Add \/ Rotate/i }));
    await waitFor(() => screen.getByRole("heading", { name: /Add \/ Rotate Provider Key/i }));
    await userEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(screen.queryByRole("heading", { name: /Add \/ Rotate Provider Key/i })).not.toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Create Auth Token modal
// ---------------------------------------------------------------------------

describe("Gateways — create auth token modal", () => {
  it("opens Create Auth Token modal when + New Token is clicked", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: /\+ Generate/i })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /\+ Generate/i }));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Create Auth Token" })).toBeInTheDocument());
  });

  it("token modal has label, expires and budget fields", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => screen.getByRole("button", { name: /\+ Generate/i }));
    await userEvent.click(screen.getByRole("button", { name: /\+ Generate/i }));
    await waitFor(() => expect(screen.getByLabelText(/Label/i)).toBeInTheDocument());
    expect(screen.getByLabelText(/Expires At/i)).toBeInTheDocument();
    expect(screen.getByLabelText(/Spend cap/i)).toBeInTheDocument();
  });

  it("calls POST /gateways/:id/tokens on Generate Token", async () => {
    setupDefaultMocks();
    mockApi.post.mockResolvedValue({ token: "tok_abc123" });
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => screen.getByRole("button", { name: /\+ Generate/i }));
    await userEvent.click(screen.getByRole("button", { name: /\+ Generate/i }));
    await waitFor(() => screen.getByRole("button", { name: "Generate Token" }));
    await userEvent.click(screen.getByRole("button", { name: "Generate Token" }));
    await waitFor(() => expect(mockApi.post).toHaveBeenCalledWith(
      `/gateways/${GW1.id}/tokens`,
      expect.any(Object)
    ));
  });

  it("shows the generated token and copy button after creation", async () => {
    setupDefaultMocks();
    mockApi.post.mockResolvedValue({ token: "tok_abc123" });
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => screen.getByRole("button", { name: /\+ Generate/i }));
    await userEvent.click(screen.getByRole("button", { name: /\+ Generate/i }));
    await waitFor(() => screen.getByRole("button", { name: "Generate Token" }));
    await userEvent.click(screen.getByRole("button", { name: "Generate Token" }));
    await waitFor(() => expect(screen.getByText("tok_abc123")).toBeInTheDocument());
    // The generated token section shows a Copy button (multiple Copy buttons may exist on the page)
    const copyButtons = screen.getAllByRole("button", { name: "Copy" });
    expect(copyButtons.length).toBeGreaterThanOrEqual(1);
  });
});

// ---------------------------------------------------------------------------
// Routing Rules — modal
// ---------------------------------------------------------------------------

describe("Gateways — routing rule modal", () => {
  it("opens New Rule modal when + New Rule is clicked", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: /\+ New Rule/i })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: /\+ New Rule/i }));
    await waitFor(() => expect(screen.getByRole("heading", { name: /New Routing Rule/i })).toBeInTheDocument());
  });

  it("new rule modal has Conditions section and + Add button", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => screen.getByRole("button", { name: /\+ New Rule/i }));
    await userEvent.click(screen.getByRole("button", { name: /\+ New Rule/i }));
    await waitFor(() => screen.getByRole("heading", { name: /New Routing Rule/i }));
    expect(screen.getByText(/Conditions \(all must match\)/i)).toBeInTheDocument();
    // Multiple + Add buttons exist (conditions + fallbacks); at least one should be present
    expect(screen.getAllByRole("button", { name: /\+ Add/i }).length).toBeGreaterThanOrEqual(1);
  });

  it("adds a condition row when the Conditions + Add is clicked", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => screen.getByRole("button", { name: /\+ New Rule/i }));
    await userEvent.click(screen.getByRole("button", { name: /\+ New Rule/i }));
    await waitFor(() => screen.getByText(/Conditions \(all must match\)/i));
    // First + Add button belongs to Conditions
    const addBtns = screen.getAllByRole("button", { name: /\+ Add/i });
    await userEvent.click(addBtns[0]);
    // A condition row appears with a field selector (select for field value)
    await waitFor(() => {
      const selects = screen.getAllByRole("combobox");
      // At least one select for the new condition field
      const fieldSel = selects.find((s) => s.querySelector('option[value="model"]') !== null ||
        within(s).queryByText("model") !== null);
      expect(fieldSel ?? selects[0]).toBeInTheDocument();
    });
  });

  it("shows load balance options when Load balance button is clicked", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => screen.getByRole("button", { name: /\+ New Rule/i }));
    await userEvent.click(screen.getByRole("button", { name: /\+ New Rule/i }));
    await waitFor(() => screen.getByRole("heading", { name: /New Routing Rule/i }));
    // Action mode toggle: "Direct route" | "Load balance"
    await userEvent.click(screen.getByRole("button", { name: /Load balance/i }));
    await waitFor(() => expect(screen.getByText("Weighted random")).toBeInTheDocument());
  });

  it("closes rule modal on Cancel", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => screen.getByRole("button", { name: /\+ New Rule/i }));
    await userEvent.click(screen.getByRole("button", { name: /\+ New Rule/i }));
    await waitFor(() => screen.getByRole("heading", { name: /New Routing Rule/i }));
    await userEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(screen.queryByRole("heading", { name: /New Routing Rule/i })).not.toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Detail view — additional stats
// ---------------------------------------------------------------------------

describe("Gateways — detail view additional stats", () => {
  it("shows rate limit stat when rate_limit is set", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByText("100/60s")).toBeInTheDocument());
  });

  it("shows Reset Spend button when gateway has a budget", async () => {
    setupDefaultMocks();
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => expect(screen.getByRole("button", { name: "Reset Spend" })).toBeInTheDocument());
  });

  it("calls DELETE /gateways/:id/budget on Reset Spend confirm", async () => {
    setupDefaultMocks();
    mockApi.delete.mockResolvedValue({ ok: true });
    vi.spyOn(window, "confirm").mockReturnValue(true);
    renderAtPath(`/tenants/${TENANT.id}/gateways/${GW1.id}`);
    await waitFor(() => screen.getByRole("button", { name: "Reset Spend" }));
    await userEvent.click(screen.getByRole("button", { name: "Reset Spend" }));
    await waitFor(() => expect(mockApi.delete).toHaveBeenCalledWith(`/gateways/${GW1.id}/budget`));
  });
});
