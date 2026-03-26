import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Routes, Route } from "react-router-dom";
import Users from "./Users";
import type { User, Tenant, Gateway, AuthToken } from "src/api/types";

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

vi.mock("src/common/contexts/AuthContext", () => ({
  useAuth: vi.fn(),
}));

import { api } from "src/api/client";
import { useAuth } from "src/common/contexts/AuthContext";
const mockApi = api as unknown as { get: ReturnType<typeof vi.fn>; post: ReturnType<typeof vi.fn>; patch: ReturnType<typeof vi.fn>; delete: ReturnType<typeof vi.fn> };
const mockUseAuth = useAuth as ReturnType<typeof vi.fn>;

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const TN1: Tenant = { id: "o1", slug: "acme", plan: "free", budget_usd: null, budget_period: "monthly", created_at: "2024-01-01T00:00:00Z" };
const TN2: Tenant = { id: "o2", slug: "globex", plan: "free", budget_usd: null, budget_period: "monthly", created_at: "2024-01-02T00:00:00Z" };

const USER1: User = { id: "u1", tenant_id: "o1", email: "alice@example.com", name: "Alice", role: "admin", created_at: "2024-01-10T00:00:00Z" };
const USER2: User = { id: "u2", tenant_id: "o1", email: "bob@example.com", name: null, role: "member", created_at: "2024-01-11T00:00:00Z" };
const USER3: User = { id: "u3", tenant_id: "o2", email: "carol@example.com", name: "Carol", role: "viewer", created_at: "2024-01-12T00:00:00Z" };

const GW: Gateway = { id: "gw1", slug: "main-gw", tenant_id: "t1", config: {}, created_at: "2024-01-05T00:00:00Z" };

const TOKEN: AuthToken = { id: "tok1", gateway_id: "gw1", token_hash: "abc", scopes: ["inference"], expires_at: null, created_at: "2024-02-01T00:00:00Z", user_id: "u1", label: "dev", rate_limit: null, budget_usd: null };

// Default admin logged-in user (platform admin)
const ADMIN_ME = { id: "me", email: "admin@example.com", role: "admin" as const, tenant_id: null };

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Default happy-path mock: two tenants, two users in o1, one in o2, one gateway */
function setupDefaultMocks() {
  mockUseAuth.mockReturnValue({ user: ADMIN_ME, loading: false, login: vi.fn(), logout: vi.fn() });
  mockApi.get.mockImplementation((path: string) => {
    if (path === "/tenants") return Promise.resolve([TN1, TN2]);
    if (path === "/tenants/o1/users") return Promise.resolve([USER1, USER2]);
    if (path === "/tenants/o2/users") return Promise.resolve([USER3]);
    if (path === "/tenants/o1/gateways") return Promise.resolve([GW]);
    if (path === "/tenants/o2/gateways") return Promise.resolve([]);
    if (path === "/users/u1/tokens") return Promise.resolve([TOKEN]);
    if (path === "/users/u2/tokens") return Promise.resolve([]);
    if (path === "/users/u3/tokens") return Promise.resolve([]);
    return Promise.resolve([]);
  });
}

function renderAtPath(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/users" element={<Users />} />
        <Route path="/users/:userId" element={<Users />} />
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

describe("Users — list view", () => {
  it("shows page title and user count", async () => {
    setupDefaultMocks();
    renderAtPath("/users");
    await waitFor(() => expect(screen.getByText("3 users")).toBeInTheDocument());
    expect(screen.getByRole("heading", { name: "Users" })).toBeInTheDocument();
  });

  it("renders a row for each user", async () => {
    setupDefaultMocks();
    renderAtPath("/users");
    await waitFor(() => expect(screen.getByText("alice@example.com")).toBeInTheDocument());
    expect(screen.getByText("bob@example.com")).toBeInTheDocument();
    expect(screen.getByText("carol@example.com")).toBeInTheDocument();
  });

  it("shows — for users without a name", async () => {
    setupDefaultMocks();
    renderAtPath("/users");
    await waitFor(() => expect(screen.getByText("bob@example.com")).toBeInTheDocument());
    const rows = screen.getAllByRole("row");
    const bobRow = rows.find((r) => within(r).queryByText("bob@example.com"));
    expect(bobRow).toBeDefined();
    expect(within(bobRow!).getByText("—")).toBeInTheDocument();
  });

  it("shows role badges", async () => {
    setupDefaultMocks();
    renderAtPath("/users");
    await waitFor(() => expect(screen.getByText("admin")).toBeInTheDocument());
    expect(screen.getByText("member")).toBeInTheDocument();
    expect(screen.getByText("viewer")).toBeInTheDocument();
  });

  it("shows tenant slugs in the table", async () => {
    setupDefaultMocks();
    renderAtPath("/users");
    await waitFor(() => expect(screen.getAllByText("acme")).not.toHaveLength(0));
    expect(screen.getAllByText("globex")).not.toHaveLength(0);
  });

  it("renders Open → buttons for each user", async () => {
    setupDefaultMocks();
    renderAtPath("/users");
    await waitFor(() => expect(screen.getAllByRole("button", { name: "Open →" })).toHaveLength(3));
  });

  it("shows empty state when no users", async () => {
    mockUseAuth.mockReturnValue({ user: ADMIN_ME, loading: false, login: vi.fn(), logout: vi.fn() });
    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TN1]);
      if (path === "/tenants/o1/users") return Promise.resolve([]);
      return Promise.resolve([]);
    });
    renderAtPath("/users");
    await waitFor(() => expect(screen.getByText(/No users yet/i)).toBeInTheDocument());
  });

  it("populates tenant filter dropdown (admin only)", async () => {
    setupDefaultMocks();
    renderAtPath("/users");
    await waitFor(() => expect(screen.getByRole("option", { name: "acme" })).toBeInTheDocument());
    expect(screen.getByRole("option", { name: "globex" })).toBeInTheDocument();
  });

  it("re-fetches when tenant filter changes", async () => {
    setupDefaultMocks();
    renderAtPath("/users");
    await waitFor(() => expect(screen.getByText("alice@example.com")).toBeInTheDocument());
    const select = screen.getByRole("combobox");
    await userEvent.selectOptions(select, "o1");
    await waitFor(() => {
      expect(screen.queryByText("carol@example.com")).not.toBeInTheDocument();
    });
  });
});

// ---------------------------------------------------------------------------
// Navigation from list
// ---------------------------------------------------------------------------

describe("Users — navigation from list", () => {
  it("navigates to /users/:id when Open → is clicked", async () => {
    setupDefaultMocks();
    renderAtPath("/users");
    await waitFor(() => expect(screen.getAllByRole("button", { name: "Open →" })).toHaveLength(3));
    const openButtons = screen.getAllByRole("button", { name: "Open →" });
    await userEvent.click(openButtons[0]);
    await waitFor(() => expect(screen.getByText("alice@example.com", { selector: "h1" })).toBeInTheDocument());
  });

  it("navigates to /users/:id when table row is clicked", async () => {
    setupDefaultMocks();
    renderAtPath("/users");
    await waitFor(() => expect(screen.getByText("bob@example.com")).toBeInTheDocument());
    const rows = screen.getAllByRole("row");
    const bobRow = rows.find((r) => within(r).queryByText("bob@example.com"))!;
    await userEvent.click(bobRow);
    await waitFor(() => expect(screen.getByText("bob@example.com", { selector: "h1" })).toBeInTheDocument());
  });
});

// ---------------------------------------------------------------------------
// Detail view (URL-driven)
// ---------------------------------------------------------------------------

describe("Users — detail view", () => {
  it("shows user detail when userId param matches", async () => {
    setupDefaultMocks();
    renderAtPath("/users/u1");
    await waitFor(() => expect(screen.getByText("alice@example.com", { selector: "h1" })).toBeInTheDocument());
    expect(screen.getByText("Alice")).toBeInTheDocument();
  });

  it("redirects to /users when userId not found (after loading)", async () => {
    setupDefaultMocks();
    renderAtPath("/users/does-not-exist");
    await waitFor(() => expect(screen.getByRole("heading", { name: "Users" })).toBeInTheDocument());
    expect(screen.queryByText("← Users")).not.toBeInTheDocument();
  });

  it("shows ← Users back button in detail view", async () => {
    setupDefaultMocks();
    renderAtPath("/users/u1");
    await waitFor(() => expect(screen.getByRole("button", { name: "← Users" })).toBeInTheDocument());
  });

  it("navigates back to list when ← Users is clicked", async () => {
    setupDefaultMocks();
    renderAtPath("/users/u1");
    await waitFor(() => expect(screen.getByRole("button", { name: "← Users" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "← Users" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Users" })).toBeInTheDocument());
  });

  it("shows user stats (email, name, role, tenant)", async () => {
    setupDefaultMocks();
    renderAtPath("/users/u1");
    await waitFor(() => expect(screen.getByText("alice@example.com", { selector: "h1" })).toBeInTheDocument());
    const main = screen.getByRole("main");
    expect(within(main).getAllByText("alice@example.com")).not.toHaveLength(0);
    expect(within(main).getByText("Alice")).toBeInTheDocument();
    expect(within(main).getByText("admin")).toBeInTheDocument();
    expect(within(main).getByText("acme")).toBeInTheDocument();
  });

  it("loads and displays tokens for the user", async () => {
    setupDefaultMocks();
    renderAtPath("/users/u1");
    await waitFor(() => expect(screen.getByText("dev")).toBeInTheDocument());
  });

  it("shows empty tokens state for user with no tokens", async () => {
    setupDefaultMocks();
    renderAtPath("/users/u2");
    await waitFor(() => expect(screen.getByText("bob@example.com", { selector: "h1" })).toBeInTheDocument());
    await waitFor(() => expect(screen.getByText(/No tokens yet/i)).toBeInTheDocument());
  });

  it("shows viewer message instead of token list for viewer users", async () => {
    setupDefaultMocks();
    renderAtPath("/users/u3");
    await waitFor(() => expect(screen.getByText("carol@example.com", { selector: "h1" })).toBeInTheDocument());
    await waitFor(() => expect(screen.getByText(/Viewer users cannot make inference requests/i)).toBeInTheDocument());
  });
});

// ---------------------------------------------------------------------------
// Create user modal
// ---------------------------------------------------------------------------

describe("Users — create user modal", () => {
  it("opens modal when + New User is clicked", async () => {
    setupDefaultMocks();
    renderAtPath("/users");
    await waitFor(() => expect(screen.getByRole("button", { name: "+ New User" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ New User" }));
    expect(screen.getByRole("heading", { name: "New User" })).toBeInTheDocument();
  });

  it("modal has tenant, email, name, role fields", async () => {
    setupDefaultMocks();
    renderAtPath("/users");
    await waitFor(() => expect(screen.getByRole("button", { name: "+ New User" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ New User" }));
    expect(screen.getByPlaceholderText("alice@example.com")).toBeInTheDocument();
    expect(screen.getByPlaceholderText("Alice")).toBeInTheDocument();
    expect(screen.getByRole("option", { name: /member/ })).toBeInTheDocument();
  });

  it("submits POST /tenants/:id/users with correct body", async () => {
    setupDefaultMocks();
    mockApi.post.mockResolvedValue({ id: "u-new", email: "dave@example.com" });
    renderAtPath("/users");
    await waitFor(() => expect(screen.getByRole("button", { name: "+ New User" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ New User" }));
    await userEvent.type(screen.getByPlaceholderText("alice@example.com"), "dave@example.com");
    await userEvent.click(screen.getByRole("button", { name: "Create User" }));
    await waitFor(() => expect(mockApi.post).toHaveBeenCalledWith(
      expect.stringMatching(/^\/tenants\/.+\/users$/),
      expect.objectContaining({ email: "dave@example.com", name: null })
    ));
  });

  it("submits with name: null when name field is empty", async () => {
    setupDefaultMocks();
    mockApi.post.mockResolvedValue({ id: "u-new", email: "eve@example.com" });
    renderAtPath("/users");
    await waitFor(() => expect(screen.getByRole("button", { name: "+ New User" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ New User" }));
    await userEvent.type(screen.getByPlaceholderText("alice@example.com"), "eve@example.com");
    await userEvent.click(screen.getByRole("button", { name: "Create User" }));
    await waitFor(() => expect(mockApi.post).toHaveBeenCalledWith(
      expect.any(String),
      expect.objectContaining({ name: null })
    ));
  });

  it("closes modal on Cancel", async () => {
    setupDefaultMocks();
    renderAtPath("/users");
    await waitFor(() => expect(screen.getByRole("button", { name: "+ New User" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ New User" }));
    expect(screen.getByRole("heading", { name: "New User" })).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(screen.queryByRole("heading", { name: "New User" })).not.toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// New Token modal — gateway list
// ---------------------------------------------------------------------------

describe("Users — New Token modal gateway list", () => {
  it("shows gateway in token modal when gateways load AFTER users (timing regression)", async () => {
    let resolveGateways!: (v: Gateway[]) => void;
    const delayedGateways = new Promise<Gateway[]>((res) => { resolveGateways = res; });

    mockUseAuth.mockReturnValue({ user: ADMIN_ME, loading: false, login: vi.fn(), logout: vi.fn() });
    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TN1]);
      if (path === "/tenants/o1/users") return Promise.resolve([USER1]);
      if (path === "/tenants/o1/gateways") return delayedGateways;
      if (path === "/users/u1/tokens") return Promise.resolve([]);
      return Promise.resolve([]);
    });

    renderAtPath("/users/u1");
    await waitFor(() => expect(screen.getByRole("button", { name: "+ New Token" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ New Token" }));

    expect(screen.queryByRole("option", { name: GW.slug })).not.toBeInTheDocument();

    resolveGateways([GW]);

    await waitFor(() => expect(screen.getByRole("option", { name: GW.slug })).toBeInTheDocument());
  });

  it("shows all tenant gateways in token modal", async () => {
    setupDefaultMocks();
    renderAtPath("/users/u1");
    await waitFor(() => expect(screen.getByRole("button", { name: "+ New Token" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ New Token" }));
    await waitFor(() => expect(screen.getByRole("option", { name: GW.slug })).toBeInTheDocument());
  });
});

// ---------------------------------------------------------------------------
// Edit user modal
// ---------------------------------------------------------------------------

describe("Users — edit user modal", () => {
  it("opens edit modal from detail view", async () => {
    setupDefaultMocks();
    renderAtPath("/users/u1");
    await waitFor(() => expect(screen.getByRole("button", { name: "Edit" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Edit" }));
    expect(screen.getByRole("heading", { name: /Edit: alice@example.com/i })).toBeInTheDocument();
  });

  it("pre-fills email, name, role in edit modal", async () => {
    setupDefaultMocks();
    renderAtPath("/users/u1");
    await waitFor(() => expect(screen.getByRole("button", { name: "Edit" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Edit" }));
    expect((screen.getByPlaceholderText("alice@example.com") as HTMLInputElement).value).toBe("alice@example.com");
    expect((screen.getByPlaceholderText("Alice") as HTMLInputElement).value).toBe("Alice");
  });
});

// ---------------------------------------------------------------------------
// Delete user
// ---------------------------------------------------------------------------

describe("Users — delete user", () => {
  it("calls DELETE /users/:id and navigates back on confirm", async () => {
    setupDefaultMocks();
    mockApi.delete.mockResolvedValue({ ok: true });
    vi.spyOn(window, "confirm").mockReturnValue(true);
    renderAtPath("/users/u1");
    await waitFor(() => expect(screen.getByRole("button", { name: "Delete User" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Delete User" }));
    await waitFor(() => expect(mockApi.delete).toHaveBeenCalledWith("/users/u1"));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Users" })).toBeInTheDocument());
  });

  it("does not delete when confirm is cancelled", async () => {
    setupDefaultMocks();
    vi.spyOn(window, "confirm").mockReturnValue(false);
    renderAtPath("/users/u1");
    await waitFor(() => expect(screen.getByRole("button", { name: "Delete User" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Delete User" }));
    expect(mockApi.delete).not.toHaveBeenCalled();
  });
});
