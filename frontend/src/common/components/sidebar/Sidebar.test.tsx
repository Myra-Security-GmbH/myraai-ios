import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter } from "react-router-dom";
import Sidebar from "./Sidebar";
import { ThemeProvider } from "src/common/contexts/ThemeContext";

function renderSidebar() {
  return render(
    <MemoryRouter>
      <ThemeProvider>
        <Sidebar />
      </ThemeProvider>
    </MemoryRouter>
  );
}

beforeEach(() => {
  localStorage.clear();
  vi.clearAllMocks();
});

describe("Sidebar — nav links", () => {
  it("renders all primary nav links in expanded state", () => {
    renderSidebar();
    expect(screen.getByText("Dashboard")).toBeInTheDocument();
    expect(screen.getByText("Tenants")).toBeInTheDocument();
    expect(screen.getByText("Gateways")).toBeInTheDocument();
    expect(screen.getByText("Users")).toBeInTheDocument();
    expect(screen.getByText("Request Logs")).toBeInTheDocument();
    expect(screen.getByText("Live Monitor")).toBeInTheDocument();
    expect(screen.getByText("Cost Analytics")).toBeInTheDocument();
    expect(screen.getByText("Playground")).toBeInTheDocument();
    expect(screen.getByText("Model Prices")).toBeInTheDocument();
  });

  it("nav links point to the correct routes", () => {
    renderSidebar();
    expect(screen.getByRole("link", { name: /dashboard/i })).toHaveAttribute("href", "/dashboard");
    expect(screen.getByRole("link", { name: /tenants/i })).toHaveAttribute("href", "/tenants");
    expect(screen.getByRole("link", { name: /gateways/i })).toHaveAttribute("href", "/gateways");
    expect(screen.getByRole("link", { name: /users/i })).toHaveAttribute("href", "/users");
  });
});

describe("Sidebar — collapse / expand", () => {
  it("collapses on toggle button click — labels are hidden", async () => {
    const user = userEvent.setup();
    renderSidebar();

    const collapseBtn = screen.getByTitle("Collapse");
    await user.click(collapseBtn);

    // Nav labels should be removed from the DOM when collapsed
    expect(screen.queryByText("Dashboard")).not.toBeInTheDocument();
    expect(screen.queryByText("Tenants")).not.toBeInTheDocument();
  });

  it("persists collapsed state to localStorage", async () => {
    const user = userEvent.setup();
    renderSidebar();

    await user.click(screen.getByTitle("Collapse"));
    expect(localStorage.getItem("aig-sidebar-collapsed")).toBe("true");
  });

  it("expands again after second toggle click", async () => {
    const user = userEvent.setup();
    renderSidebar();

    await user.click(screen.getByTitle("Collapse"));
    await user.click(screen.getByTitle("Expand"));

    expect(screen.getByText("Dashboard")).toBeInTheDocument();
    expect(localStorage.getItem("aig-sidebar-collapsed")).toBe("false");
  });

  it("starts collapsed when localStorage flag is set", () => {
    localStorage.setItem("aig-sidebar-collapsed", "true");
    renderSidebar();
    expect(screen.queryByText("Dashboard")).not.toBeInTheDocument();
  });
});

describe("Sidebar — theme toggle", () => {
  it("renders a theme toggle button", () => {
    renderSidebar();
    // Title is either "Light mode" or "Dark mode"
    const btn = screen.getByTitle(/mode/i);
    expect(btn).toBeInTheDocument();
  });

  it("switches theme on click", async () => {
    const user = userEvent.setup();
    renderSidebar();

    const btn = screen.getByTitle(/mode/i);
    const titleBefore = btn.getAttribute("title");
    await user.click(btn);
    const titleAfter = screen.getByTitle(/mode/i).getAttribute("title");
    expect(titleBefore).not.toBe(titleAfter);
  });
});
