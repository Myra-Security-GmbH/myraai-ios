import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { MemoryRouter, Routes, Route } from "react-router-dom";
import Playground from "./Playground";
import type { Gateway, ModelPrice, PlaygroundToken, Tenant } from "src/api/types";

// ---------------------------------------------------------------------------
// API mock
// ---------------------------------------------------------------------------

vi.mock("src/api/client", () => ({
  api: {
    get: vi.fn(),
    post: vi.fn(),
  },
}));

import { api } from "src/api/client";
const mockApi = api as {
  get: ReturnType<typeof vi.fn>;
  post: ReturnType<typeof vi.fn>;
};

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const TENANT1: Tenant = { id: "t1", slug: "acme", plan: "standard", budget_usd: null, created_at: "2024-01-01T00:00:00Z" };
const TENANT2: Tenant = { id: "t2", slug: "globex", plan: "free", budget_usd: null, created_at: "2024-01-02T00:00:00Z" };

const GW1: Gateway = { id: "gw1", slug: "main-gw", tenant_id: "t1", config: {}, created_at: "2024-01-05T00:00:00Z" };
const GW2: Gateway = { id: "gw2", slug: "dev-gw", tenant_id: "t1", config: {}, created_at: "2024-01-06T00:00:00Z" };

const PLAY_TOKEN: PlaygroundToken = {
  token: "tok-abc123",
  expires_at: new Date(Date.now() + 600_000).toISOString(),
  tenant_slug: "acme",
  gateway_slug: "main-gw",
};

const MODELS: ModelPrice[] = [
  { provider: "openai", model: "gpt-4o", input_per_1k: 0.005, output_per_1k: 0.015, cache_write_per_1k: null, cache_read_per_1k: null, updated_at: "2024-01-01T00:00:00Z" },
  { provider: "anthropic", model: "claude-sonnet-4-6", input_per_1k: 0.003, output_per_1k: 0.015, cache_write_per_1k: null, cache_read_per_1k: null, updated_at: "2024-01-01T00:00:00Z" },
  { provider: "gemini", model: "gemini-2.0-flash", input_per_1k: 0.00015, output_per_1k: 0.0006, cache_write_per_1k: null, cache_read_per_1k: null, updated_at: "2024-01-01T00:00:00Z" },
];

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function setupDefaultMocks() {
  mockApi.get.mockImplementation((path: string) => {
    if (path === "/tenants") return Promise.resolve([TENANT1, TENANT2]);
    if (path === "/models") return Promise.resolve(MODELS);
    if (path === "/tenants/t1/gateways") return Promise.resolve([GW1, GW2]);
    if (path === "/tenants/t2/gateways") return Promise.resolve([]);
    return Promise.resolve([]);
  });
  mockApi.post.mockResolvedValue(PLAY_TOKEN);
}

function renderPlayground() {
  return render(
    <MemoryRouter initialEntries={["/playground"]}>
      <Routes>
        <Route path="/playground" element={<Playground />} />
      </Routes>
    </MemoryRouter>
  );
}

/** Build a fake SSE streaming response for fetch mock. */
function makeSseResponse(content: string, status = 200): Response {
  const chatId = "chatcmpl-test";
  const lines = [
    `data: ${JSON.stringify({ id: chatId, object: "chat.completion.chunk", model: "gpt-4o", choices: [{ index: 0, delta: { role: "assistant", content: "" }, finish_reason: null }] })}`,
    `data: ${JSON.stringify({ id: chatId, object: "chat.completion.chunk", model: "gpt-4o", choices: [{ index: 0, delta: { content }, finish_reason: null }] })}`,
    `data: ${JSON.stringify({ id: chatId, object: "chat.completion.chunk", model: "gpt-4o", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}`,
    "data: [DONE]",
  ].join("\n") + "\n";
  return new Response(lines, { status, headers: { "Content-Type": "text/event-stream" } });
}

beforeEach(() => {
  vi.clearAllMocks();
  vi.spyOn(global, "fetch").mockResolvedValue(makeSseResponse("Hello from model!"));
});

// ---------------------------------------------------------------------------
// Initial render
// ---------------------------------------------------------------------------

describe("Playground — initial render", () => {
  it("shows page heading", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("heading", { name: "Playground" })).toBeInTheDocument());
  });

  it("shows Run button", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).toBeInTheDocument());
  });

  it("loads and displays model count hint", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText(/3 models available/i)).toBeInTheDocument());
  });

  it("shows Tenant and Gateway selectors", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText("Tenant")).toBeInTheDocument());
    expect(screen.getByText("Gateway")).toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Tenant / gateway loading
// ---------------------------------------------------------------------------

describe("Playground — tenant and gateway loading", () => {
  it("populates tenant selector with tenant slugs", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("option", { name: "acme" })).toBeInTheDocument());
    expect(screen.getByRole("option", { name: "globex" })).toBeInTheDocument();
  });

  it("auto-selects first tenant and loads its gateways", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(mockApi.get).toHaveBeenCalledWith("/tenants/t1/gateways"));
  });

  it("shows gateways for the auto-selected tenant", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("option", { name: "main-gw" })).toBeInTheDocument());
    expect(screen.getByRole("option", { name: "dev-gw" })).toBeInTheDocument();
  });

  it("fetches gateways for a new tenant when tenant select changes", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("option", { name: "acme" })).toBeInTheDocument());

    const selects = screen.getAllByRole("combobox");
    const tenantSelect = selects[0];
    await userEvent.selectOptions(tenantSelect, "t2");

    await waitFor(() => expect(mockApi.get).toHaveBeenCalledWith("/tenants/t2/gateways"));
  });
});

// ---------------------------------------------------------------------------
// Playground token
// ---------------------------------------------------------------------------

describe("Playground — token management", () => {
  it("requests a playground token when a gateway is selected", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() =>
      expect(mockApi.post).toHaveBeenCalledWith("/playground/token", { gateway_id: "gw1" })
    );
  });

  it("shows 'token active' badge after token is created", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
  });

  it("requests new token when gateway select changes", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("option", { name: "main-gw" })).toBeInTheDocument());

    const selects = screen.getAllByRole("combobox");
    const gatewaySelect = selects[1];
    await userEvent.selectOptions(gatewaySelect, "gw2");

    await waitFor(() =>
      expect(mockApi.post).toHaveBeenCalledWith("/playground/token", { gateway_id: "gw2" })
    );
  });
});

// ---------------------------------------------------------------------------
// Panel management
// ---------------------------------------------------------------------------

describe("Playground — panel management", () => {
  it("starts with one panel", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText("Playground")).toBeInTheDocument());
    // One response area
    expect(screen.getAllByLabelText("Response")).toHaveLength(1);
  });

  it("shows '+ Add Model' button when fewer than 4 panels", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("button", { name: "+ Add Model" })).toBeInTheDocument());
  });

  it("adds a second panel when '+ Add Model' is clicked", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("button", { name: "+ Add Model" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ Add Model" }));
    await waitFor(() => expect(screen.getAllByLabelText("Response")).toHaveLength(2));
  });

  it("hides '+ Add Model' when 4 panels exist", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("button", { name: "+ Add Model" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ Add Model" }));
    await userEvent.click(screen.getByRole("button", { name: "+ Add Model" }));
    await userEvent.click(screen.getByRole("button", { name: "+ Add Model" }));
    await waitFor(() => expect(screen.queryByRole("button", { name: "+ Add Model" })).not.toBeInTheDocument());
  });

  it("removes a panel when ✕ is clicked on a multi-panel view", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("button", { name: "+ Add Model" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ Add Model" }));
    await waitFor(() => expect(screen.getAllByLabelText("Response")).toHaveLength(2));
    const removeBtns = screen.getAllByRole("button", { name: "Remove panel" });
    await userEvent.click(removeBtns[0]);
    await waitFor(() => expect(screen.getAllByLabelText("Response")).toHaveLength(1));
  });

  it("does not show Remove panel button when only one panel exists", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getAllByLabelText("Response")).toHaveLength(1));
    expect(screen.queryByRole("button", { name: "Remove panel" })).not.toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Run button state
// ---------------------------------------------------------------------------

describe("Playground — Run button state", () => {
  it("Run button is disabled when message is empty", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    const runBtn = screen.getByRole("button", { name: "Run" });
    expect(runBtn).toBeDisabled();
  });

  it("Run button is disabled when no model is selected", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    await userEvent.type(screen.getByLabelText("User message"), "Hello");
    // No model selected yet → still disabled
    expect(screen.getByRole("button", { name: "Run" })).toBeDisabled();
  });
});

// ---------------------------------------------------------------------------
// ModelPicker
// ---------------------------------------------------------------------------

describe("Playground — ModelPicker", () => {
  it("opens dropdown when model button is clicked", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getAllByRole("button", { name: /Select model|gpt-4o|claude|gemini/i })[0]).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"));
    expect(pickerBtn).toBeDefined();
    await userEvent.click(pickerBtn!);
    await waitFor(() => expect(screen.getByRole("listbox")).toBeInTheDocument());
  });

  it("shows search input in open dropdown", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText(/models available/)).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"));
    await userEvent.click(pickerBtn!);
    await waitFor(() => expect(screen.getByLabelText("Search models")).toBeInTheDocument());
  });

  it("filters models by search text", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText(/models available/)).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"));
    await userEvent.click(pickerBtn!);
    await waitFor(() => expect(screen.getByLabelText("Search models")).toBeInTheDocument());
    await userEvent.type(screen.getByLabelText("Search models"), "gpt");
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    expect(screen.queryByRole("option", { name: "claude-sonnet-4-6" })).not.toBeInTheDocument();
  });

  it("shows 'No models match' when search has no results", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText(/models available/)).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"));
    await userEvent.click(pickerBtn!);
    await waitFor(() => expect(screen.getByLabelText("Search models")).toBeInTheDocument());
    await userEvent.type(screen.getByLabelText("Search models"), "zzz-no-match");
    await waitFor(() => expect(screen.getByText("No models match")).toBeInTheDocument());
  });

  it("selects a model and closes dropdown on option click", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText(/models available/)).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"));
    await userEvent.click(pickerBtn!);
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "gpt-4o" }));
    await waitFor(() => expect(screen.queryByRole("listbox")).not.toBeInTheDocument());
    // Button now shows selected model name
    expect(screen.getAllByRole("button").some((b) => b.textContent?.includes("gpt-4o"))).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// System prompt toggle
// ---------------------------------------------------------------------------

describe("Playground — system prompt", () => {
  it("system prompt textarea hidden by default", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText("Playground")).toBeInTheDocument());
    expect(screen.queryByLabelText("System prompt")).not.toBeInTheDocument();
  });

  it("shows system prompt textarea after toggle", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("button", { name: "System prompt" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "System prompt" }));
    expect(screen.getByLabelText("System prompt")).toBeInTheDocument();
  });

  it("button label toggles to 'Hide system' when open", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("button", { name: "System prompt" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "System prompt" }));
    expect(screen.getByRole("button", { name: "Hide system" })).toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Parameters toggle
// ---------------------------------------------------------------------------

describe("Playground — parameters", () => {
  it("parameters panel hidden by default", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText("Playground")).toBeInTheDocument());
    expect(screen.queryByLabelText("Temperature")).not.toBeInTheDocument();
  });

  it("shows temperature and max_tokens inputs after toggle", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("button", { name: "Parameters" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Parameters" }));
    expect(screen.getByLabelText("Temperature")).toBeInTheDocument();
    expect(screen.getByLabelText("Max tokens")).toBeInTheDocument();
  });

  it("button label toggles to 'Hide params' when open", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("button", { name: "Parameters" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Parameters" }));
    expect(screen.getByRole("button", { name: "Hide params" })).toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Run — fetch completions
// ---------------------------------------------------------------------------

describe("Playground — streaming UX", () => {
  it("shows partial content while the stream is still in progress", async () => {
    setupDefaultMocks();

    // A fetch that yields two chunks with a resolvable pause between them
    let sendSecondChunk!: () => void;
    const secondChunkReady = new Promise<void>((res) => { sendSecondChunk = res; });

    const chatId = "chatcmpl-stream-test";
    const chunk1 = `data: ${JSON.stringify({ id: chatId, object: "chat.completion.chunk", model: "gpt-4o", choices: [{ index: 0, delta: { content: "Hello" }, finish_reason: null }] })}\n`;
    const chunk2 = `data: ${JSON.stringify({ id: chatId, object: "chat.completion.chunk", model: "gpt-4o", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}\ndata: [DONE]\n`;

    vi.spyOn(global, "fetch").mockResolvedValue(
      new Response(
        new ReadableStream({
          async start(controller) {
            controller.enqueue(new TextEncoder().encode(chunk1));
            await secondChunkReady;
            controller.enqueue(new TextEncoder().encode(chunk2));
            controller.close();
          },
        }),
        { status: 200, headers: { "Content-Type": "text/event-stream" } }
      )
    );

    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "gpt-4o" }));
    await userEvent.type(screen.getByLabelText("User message"), "hi");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).not.toBeDisabled());
    await userEvent.click(screen.getByRole("button", { name: "Run" }));

    // First chunk should appear BEFORE stream ends
    await waitFor(() => expect(screen.getByLabelText("Response").textContent).toContain("Hello"));

    // Release second chunk to finish the stream
    sendSecondChunk();
    await waitFor(() => expect(screen.queryByText("Running…")).not.toBeInTheDocument());
  });

  it("shows 'Running…' only before the first token, not during streaming", async () => {
    setupDefaultMocks();

    let sendContent!: () => void;
    const contentReady = new Promise<void>((res) => { sendContent = res; });
    const chatId = "chatcmpl-x";
    const chunk = `data: ${JSON.stringify({ id: chatId, object: "chat.completion.chunk", model: "gpt-4o", choices: [{ index: 0, delta: { content: "hi" }, finish_reason: null }] })}\ndata: [DONE]\n`;

    vi.spyOn(global, "fetch").mockResolvedValue(
      new Response(
        new ReadableStream({
          async start(controller) {
            await contentReady;
            controller.enqueue(new TextEncoder().encode(chunk));
            controller.close();
          },
        }),
        { status: 200, headers: { "Content-Type": "text/event-stream" } }
      )
    );

    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "gpt-4o" }));
    await userEvent.type(screen.getByLabelText("User message"), "hi");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).not.toBeDisabled());
    await userEvent.click(screen.getByRole("button", { name: "Run" }));

    // Before any content: spinner shown inside the response area
    const responseArea = await screen.findByLabelText("Response");
    await waitFor(() => expect(responseArea.textContent).toContain("Running…"));

    // Content arrives — spinner disappears from response area, content shows
    sendContent();
    await waitFor(() => expect(responseArea.textContent).not.toContain("Running…"));
    expect(responseArea.textContent).toContain("hi");
  });
});

describe("Playground — run completions", () => {
  async function setupAndSelectModel() {
    setupDefaultMocks();
    renderPlayground();
    // Wait for token active
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    // Open model picker and select gpt-4o
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "gpt-4o" }));
    // Type a message
    await userEvent.type(screen.getByLabelText("User message"), "Hello!");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).not.toBeDisabled());
  }

  it("calls fetch with correct URL and auth header", async () => {
    await setupAndSelectModel();
    await userEvent.click(screen.getByRole("button", { name: "Run" }));
    await waitFor(() => expect(global.fetch).toHaveBeenCalledWith(
      "/v1/acme/main-gw/compat/chat/completions",
      expect.objectContaining({
        method: "POST",
        headers: expect.objectContaining({ Authorization: "Bearer tok-abc123" }),
      })
    ));
  });

  it("shows response content in panel after successful run", async () => {
    await setupAndSelectModel();
    await userEvent.click(screen.getByRole("button", { name: "Run" }));
    await waitFor(() => expect(screen.getByText("Hello from model!")).toBeInTheDocument());
  });

  it("shows error message in panel when fetch returns non-OK", async () => {
    setupDefaultMocks();
    vi.spyOn(global, "fetch").mockResolvedValue(new Response(
      JSON.stringify({ error: { message: "Rate limit exceeded" } }),
      { status: 429, headers: { "Content-Type": "application/json" } }
    ) as Response);
    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "gpt-4o" }));
    await userEvent.type(screen.getByLabelText("User message"), "Hello!");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).not.toBeDisabled());
    await userEvent.click(screen.getByRole("button", { name: "Run" }));
    await waitFor(() => expect(screen.getByText("Rate limit exceeded")).toBeInTheDocument());
  });

  it("shows error when no model is selected for a panel", async () => {
    setupDefaultMocks();
    renderPlayground();
    // Add a second panel (it will have no model)
    await waitFor(() => expect(screen.getByRole("button", { name: "+ Add Model" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "+ Add Model" }));
    // Select model only for first panel
    const pickerBtns = screen.getAllByRole("button").filter((b) => b.textContent?.includes("Select model"));
    await userEvent.click(pickerBtns[0]);
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "gpt-4o" }));
    // Run button still disabled because panel 2 has no model
    await userEvent.type(screen.getByLabelText("User message"), "Hello!");
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    // With unselected model on panel 2, canRun is false
    expect(screen.getByRole("button", { name: "Run" })).toBeDisabled();
  });

  it("shows global error when no token exists", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TENANT1]);
      if (path === "/models") return Promise.resolve(MODELS);
      if (path === "/tenants/t1/gateways") return Promise.resolve([GW1]);
      return Promise.resolve([]);
    });
    mockApi.post.mockRejectedValue(new Error("Network error"));
    renderPlayground();
    await waitFor(() => expect(screen.getByText(/Could not create playground token/i)).toBeInTheDocument());
  });
});

// ---------------------------------------------------------------------------
// Response format contract (guards against wrong port / missing compat conversion)
// ---------------------------------------------------------------------------

describe("Playground — response format contract", () => {
  // If the gateway compat endpoint returns Anthropic-native format instead of
  // OpenAI format, the panel shows "(no content)" because choices[0] is absent.
  // This test documents that contract explicitly.
  it("shows content from SSE delta chunks (OpenAI streaming format)", async () => {
    setupDefaultMocks();
    // Simulate a correct OpenAI streaming response (what gateway compat must return)
    vi.spyOn(global, "fetch").mockResolvedValue(makeSseResponse("Two."));
    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "gpt-4o" }));
    await userEvent.type(screen.getByLabelText("User message"), "what is 1+1");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).not.toBeDisabled());
    await userEvent.click(screen.getByRole("button", { name: "Run" }));
    await waitFor(() => expect(screen.getByText("Two.")).toBeInTheDocument());
  });

  it("shows (no content) when SSE stream contains no delta content", async () => {
    // Documents the fallback when the SSE stream has no content deltas.
    setupDefaultMocks();
    // SSE with only role chunk and DONE — no content delta
    const emptyStream = "data: " + JSON.stringify({
      id: "chatcmpl-x", object: "chat.completion.chunk", model: "gpt-4o",
      choices: [{ index: 0, delta: { role: "assistant", content: "" }, finish_reason: null }],
    }) + "\ndata: [DONE]\n";
    vi.spyOn(global, "fetch").mockResolvedValue(
      new Response(emptyStream, { status: 200, headers: { "Content-Type": "text/event-stream" } })
    );
    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "gpt-4o" }));
    await userEvent.type(screen.getByLabelText("User message"), "what is 1+1");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).not.toBeDisabled());
    await userEvent.click(screen.getByRole("button", { name: "Run" }));
    await waitFor(() => expect(screen.getByText("(no content)")).toBeInTheDocument());
  });
});

// ---------------------------------------------------------------------------
// Markdown rendering
// ---------------------------------------------------------------------------

describe("Playground — markdown rendering", () => {
  /** Run the playground, select gpt-4o, type a message, click Run, wait for content. */
  async function runAndWaitForContent(responseContent: string) {
    vi.spyOn(global, "fetch").mockResolvedValue(makeSseResponse(responseContent));
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "gpt-4o" }));
    await userEvent.type(screen.getByLabelText("User message"), "test");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).not.toBeDisabled());
    await userEvent.click(screen.getByRole("button", { name: "Run" }));
    // Wait until the response area shows something other than the placeholder
    await waitFor(() =>
      expect(screen.queryByText("Response will appear here")).not.toBeInTheDocument()
    );
  }

  it("renders heading markdown as an h2 element", async () => {
    await runAndWaitForContent("## Hello World");
    await waitFor(() => expect(screen.getByRole("heading", { name: "Hello World" })).toBeInTheDocument());
  });

  it("renders bold text as a strong element", async () => {
    await runAndWaitForContent("This is **important** text.");
    await waitFor(() => expect(screen.getByText("important").tagName).toBe("STRONG"));
  });

  it("renders a bullet list as ul/li elements", async () => {
    await runAndWaitForContent("- Alpha\n- Beta\n- Gamma");
    await waitFor(() => {
      expect(screen.getByText("Alpha").closest("li")).toBeInTheDocument();
      expect(screen.getByText("Beta").closest("li")).toBeInTheDocument();
      expect(screen.getByText("Gamma").closest("li")).toBeInTheDocument();
    });
  });

  it("renders inline code in a code element", async () => {
    await runAndWaitForContent("Use `npm install` to install.");
    await waitFor(() => expect(screen.getByText("npm install").tagName).toBe("CODE"));
  });

  it("renders a fenced code block in a code element", async () => {
    await runAndWaitForContent("```\nconsole.log('hi')\n```");
    await waitFor(() => expect(screen.getByText("console.log('hi')").tagName).toBe("CODE"));
  });

  it("renders a GFM table (remark-gfm)", async () => {
    const table = "| Name | Score |\n|------|-------|\n| Alice | 95 |\n| Bob | 87 |";
    await runAndWaitForContent(table);
    await waitFor(() => {
      expect(screen.getByRole("table")).toBeInTheDocument();
      expect(screen.getByText("Alice")).toBeInTheDocument();
      expect(screen.getByText("Bob")).toBeInTheDocument();
    });
  });

  it("does not render markdown in raw mode — shows raw asterisks", async () => {
    await runAndWaitForContent("This is **bold** text.");
    // Switch to raw mode
    const rawBtn = screen.getByRole("button", { name: "Show raw" });
    await userEvent.click(rawBtn);
    // Raw text should contain the asterisks literally
    await waitFor(() => expect(screen.getByLabelText("Response").textContent).toContain("**bold**"));
    // No <strong> element
    expect(screen.queryByText("bold")?.tagName).not.toBe("STRONG");
  });

  it("shows 'Raw' button only after content arrives, not before", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    // Before running — no Raw/Rendered toggle
    expect(screen.queryByRole("button", { name: "Show raw" })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Show rendered" })).not.toBeInTheDocument();
  });

  it("toggle button label switches between 'Raw' and 'Rendered'", async () => {
    await runAndWaitForContent("## Title");
    const rawBtn = screen.getByRole("button", { name: "Show raw" });
    expect(rawBtn).toBeInTheDocument();
    await userEvent.click(rawBtn);
    expect(screen.getByRole("button", { name: "Show rendered" })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Show raw" })).not.toBeInTheDocument();
  });

  it("toggling back to rendered re-renders markdown", async () => {
    await runAndWaitForContent("## Section");
    // Switch to raw
    await userEvent.click(screen.getByRole("button", { name: "Show raw" }));
    expect(screen.queryByRole("heading", { name: "Section" })).not.toBeInTheDocument();
    // Switch back to rendered
    await userEvent.click(screen.getByRole("button", { name: "Show rendered" }));
    await waitFor(() => expect(screen.getByRole("heading", { name: "Section" })).toBeInTheDocument());
  });

  it("does not show Raw toggle when panel has an error", async () => {
    setupDefaultMocks();
    vi.spyOn(global, "fetch").mockResolvedValue(
      new Response(JSON.stringify({ error: { message: "fail" } }), {
        status: 500,
        headers: { "Content-Type": "application/json" },
      })
    );
    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "gpt-4o" }));
    await userEvent.type(screen.getByLabelText("User message"), "test");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).not.toBeDisabled());
    await userEvent.click(screen.getByRole("button", { name: "Run" }));
    await waitFor(() => expect(screen.getByText("fail")).toBeInTheDocument());
    expect(screen.queryByRole("button", { name: "Show raw" })).not.toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Message input keyboard shortcut
// ---------------------------------------------------------------------------

describe("Playground — keyboard shortcut", () => {
  it("shows Cmd+Enter tip in the input area", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText(/⌘↵ \/ Ctrl↵ to run/i)).toBeInTheDocument());
  });
});
