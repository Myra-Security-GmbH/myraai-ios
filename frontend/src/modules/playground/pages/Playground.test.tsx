import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen, waitFor, fireEvent } from "@testing-library/react";
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

/** Build an SSE response that includes a usage chunk (as emitted by the gateway). */
function makeSseResponseWithUsage(
  content: string,
  usage: { prompt_tokens: number; completion_tokens: number; cache_creation_tokens?: number; cache_read_tokens?: number }
): Response {
  const chatId = "chatcmpl-test";
  const lines = [
    `data: ${JSON.stringify({ id: chatId, object: "chat.completion.chunk", model: "gpt-4o", choices: [{ index: 0, delta: { role: "assistant", content: "" }, finish_reason: null }] })}`,
    `data: ${JSON.stringify({ id: chatId, object: "chat.completion.chunk", model: "gpt-4o", choices: [{ index: 0, delta: { content }, finish_reason: null }] })}`,
    `data: ${JSON.stringify({ id: chatId, object: "chat.completion.chunk", model: "gpt-4o", choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}`,
    `data: ${JSON.stringify({ id: chatId, object: "chat.completion.chunk", model: "gpt-4o", usage: { ...usage, total_tokens: usage.prompt_tokens + usage.completion_tokens } })}`,
    "data: [DONE]",
  ].join("\n") + "\n";
  return new Response(lines, { status: 200, headers: { "Content-Type": "text/event-stream" } });
}

beforeEach(() => {
  vi.clearAllMocks();
  localStorage.clear();
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
// State persistence (localStorage)
// ---------------------------------------------------------------------------

describe("Playground — state persistence", () => {
  it("saves selected tenant, gateway, and panel model to localStorage", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    // Select a model
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "gpt-4o" }));

    await waitFor(() => {
      const raw = localStorage.getItem("aig_playground_v1");
      expect(raw).not.toBeNull();
      const saved = JSON.parse(raw!);
      expect(saved.tenantId).toBe("t1");
      expect(saved.gatewayId).toBe("gw1");
      expect(saved.panelModels).toContain("gpt-4o");
    });
  });

  it("saves system prompt and temperature to localStorage", async () => {
    setupDefaultMocks();
    const { container } = renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    // Open system prompt and type
    await userEvent.click(screen.getByRole("button", { name: "System prompt" }));
    await userEvent.type(screen.getByLabelText("System prompt"), "Be concise.");
    // Open params and change temperature via fireEvent (range input)
    await userEvent.click(screen.getByRole("button", { name: "Parameters" }));
    const tempInput = container.querySelector<HTMLInputElement>('input[type="range"][aria-label="Temperature"]')!;
    fireEvent.change(tempInput, { target: { value: "0.3" } });

    await waitFor(() => {
      const raw = localStorage.getItem("aig_playground_v1");
      const saved = JSON.parse(raw!);
      expect(saved.systemPrompt).toBe("Be concise.");
      expect(Number(saved.temperature)).toBeCloseTo(0.3, 1);
    });
  });

  it("restores tenant, gateway, and panel model on remount", async () => {
    // Pre-seed localStorage
    localStorage.setItem("aig_playground_v1", JSON.stringify({
      tenantId: "t1",
      gatewayId: "gw2",
      panelModels: ["claude-sonnet-4-6"],
      systemPrompt: "",
      temperature: 0.7,
      maxTokens: 1024,
    }));
    setupDefaultMocks();
    renderPlayground();
    // Should auto-select tenant t1 and restore gateway gw2
    await waitFor(() => expect(mockApi.post).toHaveBeenCalledWith(
      "/playground/token", { gateway_id: "gw2" }
    ));
    // Panel model should be restored from catalog
    await waitFor(() => expect(screen.getByText("claude-sonnet-4-6")).toBeInTheDocument());
  });

  it("restores system prompt on remount", async () => {
    localStorage.setItem("aig_playground_v1", JSON.stringify({
      tenantId: "t1", gatewayId: "gw1",
      panelModels: [], systemPrompt: "You are helpful.",
      temperature: 0.7, maxTokens: 1024,
    }));
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    // System prompt section should be open (non-empty prompt) and contain saved text
    await waitFor(() => expect(screen.getByDisplayValue("You are helpful.")).toBeInTheDocument());
  });

  it("falls back to first tenant/gateway when saved IDs no longer exist", async () => {
    localStorage.setItem("aig_playground_v1", JSON.stringify({
      tenantId: "t-gone", gatewayId: "gw-gone",
      panelModels: [], systemPrompt: "", temperature: 0.7, maxTokens: 1024,
    }));
    setupDefaultMocks();
    renderPlayground();
    // Should fall back to first tenant (t1) and first gateway (gw1)
    await waitFor(() => expect(mockApi.post).toHaveBeenCalledWith(
      "/playground/token", { gateway_id: "gw1" }
    ));
  });

  it("skips restoring panel models that no longer exist in catalog", async () => {
    localStorage.setItem("aig_playground_v1", JSON.stringify({
      tenantId: "t1", gatewayId: "gw1",
      panelModels: ["model-that-was-deleted"],
      systemPrompt: "", temperature: 0.7, maxTokens: 1024,
    }));
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    // Invalid model not restored — panel should show "Select model"
    expect(screen.getAllByRole("button").some((b) => b.textContent?.includes("Select model"))).toBe(true);
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
// Metrics (tokens, cost, latency)
// ---------------------------------------------------------------------------

describe("Playground — metrics", () => {
  async function setupAndRun(response: Response) {
    setupDefaultMocks();
    vi.spyOn(global, "fetch").mockResolvedValue(response);
    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "gpt-4o" }));
    await userEvent.type(screen.getByLabelText("User message"), "hi");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).not.toBeDisabled());
    await userEvent.click(screen.getByRole("button", { name: "Run" }));
  }

  it("shows input and output token counts from usage chunk", async () => {
    await setupAndRun(makeSseResponseWithUsage("answer", { prompt_tokens: 42, completion_tokens: 17 }));
    await waitFor(() => expect(screen.getByLabelText("Input tokens")).toBeInTheDocument());
    expect(screen.getByLabelText("Input tokens").textContent).toMatch(/42/);
    expect(screen.getByLabelText("Output tokens").textContent).toMatch(/17/);
  });

  it("shows cache write and cache read tokens when non-zero", async () => {
    await setupAndRun(makeSseResponseWithUsage("answer", {
      prompt_tokens: 100, completion_tokens: 20,
      cache_creation_tokens: 50, cache_read_tokens: 30,
    }));
    await waitFor(() => expect(screen.getByLabelText("Cache write tokens")).toBeInTheDocument());
    expect(screen.getByLabelText("Cache write tokens").textContent).toMatch(/50/);
    expect(screen.getByLabelText("Cache read tokens").textContent).toMatch(/30/);
  });

  it("does not show cache token spans when counts are zero/absent", async () => {
    await setupAndRun(makeSseResponseWithUsage("answer", { prompt_tokens: 10, completion_tokens: 5 }));
    await waitFor(() => expect(screen.getByLabelText("Input tokens")).toBeInTheDocument());
    expect(screen.queryByLabelText("Cache write tokens")).not.toBeInTheDocument();
    expect(screen.queryByLabelText("Cache read tokens")).not.toBeInTheDocument();
  });

  it("shows cost estimate when model price is known", async () => {
    // gpt-4o: input_per_1k=0.005, output_per_1k=0.015
    // 1000 input + 1000 output = 0.005 + 0.015 = 0.020
    await setupAndRun(makeSseResponseWithUsage("answer", { prompt_tokens: 1000, completion_tokens: 1000 }));
    await waitFor(() => expect(screen.getByLabelText("Estimated cost")).toBeInTheDocument());
    expect(screen.getByLabelText("Estimated cost").textContent).toMatch(/0\.0200/);
  });

  it("shows latency in ms after completion", async () => {
    await setupAndRun(makeSseResponse("done"));
    await waitFor(() => expect(screen.getByLabelText("Latency")).toBeInTheDocument());
    // Just check the unit is shown — exact value depends on test timing
    expect(screen.getByLabelText("Latency").textContent).toMatch(/ms/);
  });

  it("shows live elapsed time (with '…') while loading", async () => {
    setupDefaultMocks();
    let sendChunk!: () => void;
    const contentReady = new Promise<void>((res) => { sendChunk = res; });
    const chunk = `data: ${JSON.stringify({ id: "x", object: "chat.completion.chunk", model: "gpt-4o", choices: [{ index: 0, delta: { content: "hi" }, finish_reason: null }] })}\ndata: [DONE]\n`;
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
    // While streaming, latency span should show "…"
    await waitFor(() => expect(screen.getByLabelText("Latency")).toBeInTheDocument());
    expect(screen.getByLabelText("Latency").textContent).toMatch(/…/);
    // Release the stream
    sendChunk();
    await waitFor(() => expect(screen.getByLabelText("Latency").textContent).not.toMatch(/…/));
  });
});

// ---------------------------------------------------------------------------
// Error handling
// ---------------------------------------------------------------------------

describe("Playground — error handling", () => {
  /** Set up, select gpt-4o, type a message, click Run, then wait for the error badge. */
  async function runWithError(status: number, body: unknown) {
    setupDefaultMocks();
    vi.spyOn(global, "fetch").mockResolvedValue(
      new Response(JSON.stringify(body), {
        status,
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
  }

  it("shows RATE LIMITED badge and hint for 429", async () => {
    await runWithError(429, { error: { message: "Too many requests" } });
    await waitFor(() => expect(screen.getByText("RATE LIMITED")).toBeInTheDocument());
    expect(screen.getByText(/Try again in a moment/i)).toBeInTheDocument();
  });

  it("shows AUTH ERROR badge and hint for 401", async () => {
    await runWithError(401, { error: "Unauthorized" });
    await waitFor(() => expect(screen.getByText("AUTH ERROR")).toBeInTheDocument());
    expect(screen.getByText(/Check your gateway token/i)).toBeInTheDocument();
  });

  it("shows AUTH ERROR badge for 403", async () => {
    await runWithError(403, { error: "Forbidden" });
    await waitFor(() => expect(screen.getByText("AUTH ERROR")).toBeInTheDocument());
  });

  it("shows NOT FOUND badge for 404", async () => {
    await runWithError(404, { error: "model not found" });
    await waitFor(() => expect(screen.getByText("NOT FOUND")).toBeInTheDocument());
  });

  it("shows SERVER ERROR badge for 500", async () => {
    await runWithError(500, { error: "internal server error" });
    await waitFor(() => expect(screen.getByText("SERVER ERROR 500")).toBeInTheDocument());
    expect(screen.getByText(/Try again in a moment/i)).toBeInTheDocument();
  });

  it("shows HTTP status badge for unexpected status codes", async () => {
    await runWithError(422, { error: "Unprocessable entity" });
    await waitFor(() => expect(screen.getByText("HTTP 422")).toBeInTheDocument());
  });

  it("extracts message from OpenAI-shaped error body", async () => {
    await runWithError(400, { error: { message: "invalid model" } });
    await waitFor(() => expect(screen.getByText("invalid model")).toBeInTheDocument());
  });

  it("extracts message from plain string error field", async () => {
    await runWithError(400, { error: "bad request" });
    await waitFor(() => expect(screen.getByText("bad request")).toBeInTheDocument());
  });

  it("shows network error message when fetch throws TypeError", async () => {
    setupDefaultMocks();
    vi.spyOn(global, "fetch").mockRejectedValue(new TypeError("Failed to fetch"));
    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "gpt-4o" }));
    await userEvent.type(screen.getByLabelText("User message"), "test");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).not.toBeDisabled());
    await userEvent.click(screen.getByRole("button", { name: "Run" }));
    await waitFor(() => expect(screen.getByText(/Network error/i)).toBeInTheDocument());
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

// ---------------------------------------------------------------------------
// Web search agentic loop
// ---------------------------------------------------------------------------

const CLAUDE_MODEL: ModelPrice = {
  provider: "anthropic",
  model: "claude-haiku-4-5",
  input_per_1k: 0.0008,
  output_per_1k: 0.004,
  cache_write_per_1k: null,
  cache_read_per_1k: null,
  updated_at: "2024-01-01T00:00:00Z",
};

const MODELS_WITH_CLAUDE = [...MODELS, CLAUDE_MODEL];

/** Non-streaming Anthropic response with a tool_use block. */
function makeAnthropicToolUseResponse(toolId: string, query: string): Response {
  return new Response(
    JSON.stringify({
      id: "msg_01",
      type: "message",
      role: "assistant",
      content: [
        { type: "text", text: "I'll search the web for that." },
        { type: "tool_use", id: toolId, name: "web_search", input: { query } },
      ],
      stop_reason: "tool_use",
      usage: { input_tokens: 50, output_tokens: 20 },
    }),
    { status: 200, headers: { "Content-Type": "application/json" } }
  );
}

/** Non-streaming Anthropic response with plain text (no tool call). */
function makeAnthropicTextResponse(text: string): Response {
  return new Response(
    JSON.stringify({
      id: "msg_02",
      type: "message",
      role: "assistant",
      content: [{ type: "text", text }],
      stop_reason: "end_turn",
      usage: { input_tokens: 30, output_tokens: 15 },
    }),
    { status: 200, headers: { "Content-Type": "application/json" } }
  );
}

/** Anthropic native SSE streaming response. */
function makeAnthropicSseResponse(content: string): Response {
  const lines = [
    `data: ${JSON.stringify({ type: "message_start", message: { usage: { input_tokens: 120, output_tokens: 1 } } })}`,
    `data: ${JSON.stringify({ type: "content_block_start", index: 0, content_block: { type: "text", text: "" } })}`,
    `data: ${JSON.stringify({ type: "content_block_delta", index: 0, delta: { type: "text_delta", text: content } })}`,
    `data: ${JSON.stringify({ type: "content_block_stop", index: 0 })}`,
    `data: ${JSON.stringify({ type: "message_delta", delta: { stop_reason: "end_turn" }, usage: { output_tokens: 60 } })}`,
    `data: ${JSON.stringify({ type: "message_stop" })}`,
  ].join("\n") + "\n";
  return new Response(lines, { status: 200, headers: { "Content-Type": "text/event-stream" } });
}

function setupWebSearchMocks(opts: {
  toolId: string;
  searchQuery: string;
  finalAnswer: string;
}) {
  mockApi.get.mockImplementation((path: string) => {
    if (path === "/tenants") return Promise.resolve([TENANT1]);
    if (path === "/models") return Promise.resolve(MODELS_WITH_CLAUDE);
    if (path === "/tenants/t1/gateways") return Promise.resolve([GW1]);
    return Promise.resolve([]);
  });
  mockApi.post.mockResolvedValue(PLAY_TOKEN);

  let leg2Body: any = null;

  vi.spyOn(global, "fetch").mockImplementation(async (url, init) => {
    const urlStr = String(url);
    const body = init?.body ? JSON.parse(String(init.body)) : null;

    if (urlStr.includes("/anthropic/v1/messages") && body && !body.stream) {
      return makeAnthropicToolUseResponse(opts.toolId, opts.searchQuery);
    }
    if (urlStr.includes("/playground/search")) {
      return new Response(
        JSON.stringify({ results: [{ title: "Result", url: "https://x.com", snippet: "snippet" }], query: opts.searchQuery }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    }
    if (urlStr.includes("/anthropic/v1/messages") && body?.stream) {
      leg2Body = body;
      return makeAnthropicSseResponse(opts.finalAnswer);
    }
    return new Response("", { status: 404 });
  });

  return { getLeg2Body: () => leg2Body };
}

async function setupAndRunWebSearch(finalAnswerText: string) {
  const TOOL_ID = "toolu_reg_001";
  const mocks = setupWebSearchMocks({ toolId: TOOL_ID, searchQuery: "ai news", finalAnswer: finalAnswerText });

  renderPlayground();
  await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());

  // Select claude-haiku-4-5
  const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
  await userEvent.click(pickerBtn);
  await waitFor(() => expect(screen.getByRole("option", { name: "claude-haiku-4-5" })).toBeInTheDocument());
  await userEvent.click(screen.getByRole("option", { name: "claude-haiku-4-5" }));

  // Enable web search
  await userEvent.click(screen.getByRole("button", { name: "Web Search" }));

  // Type and run
  await userEvent.type(screen.getByLabelText("User message"), "What is the latest AI news?");
  await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).not.toBeDisabled());
  await userEvent.click(screen.getByRole("button", { name: "Run" }));

  return { toolId: TOOL_ID, ...mocks };
}

describe("Playground — web search", () => {
  it("shows Web Search toggle button", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("button", { name: "Web Search" })).toBeInTheDocument());
  });

  it("toggle changes label to 'Web Search ON' when active", async () => {
    setupDefaultMocks();
    renderPlayground();
    await waitFor(() => expect(screen.getByRole("button", { name: "Web Search" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("button", { name: "Web Search" }));
    expect(screen.getByRole("button", { name: "Web Search ON" })).toBeInTheDocument();
  });

  it("regression: leg 2 must include tools array — missing tools caused Anthropic 400", async () => {
    const { getLeg2Body } = await setupAndRunWebSearch("Here are the results.");
    await waitFor(() => expect(screen.getByLabelText("Response").textContent).toContain("Here are the results."));

    const leg2 = getLeg2Body();
    expect(leg2).not.toBeNull();

    // This is the regression: leg 2 was sent without tools, causing:
    // "messages.2: tool_use ids were found without tool_result blocks immediately after"
    expect(leg2.tools).toBeDefined();
    expect(Array.isArray(leg2.tools)).toBe(true);
    expect(leg2.tools.length).toBeGreaterThan(0);
    expect(leg2.tools[0].name).toBe("web_search");
  });

  it("regression: multiple tool_use blocks (Opus parallel calls) all get tool_result entries", async () => {
    // Opus-4-6 can emit 2+ tool_use blocks in one response. Previously only the first
    // was handled, causing: "tool_use ids found without tool_result blocks immediately after"
    const ID1 = "toolu_multi_A";
    const ID2 = "toolu_multi_B";

    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TENANT1]);
      if (path === "/models") return Promise.resolve(MODELS_WITH_CLAUDE);
      if (path === "/tenants/t1/gateways") return Promise.resolve([GW1]);
      return Promise.resolve([]);
    });
    mockApi.post.mockResolvedValue(PLAY_TOKEN);

    let leg2Body: any = null;
    const searchQueries: string[] = [];

    vi.spyOn(global, "fetch").mockImplementation(async (url, init) => {
      const urlStr = String(url);
      const body = init?.body ? JSON.parse(String(init.body)) : null;

      if (urlStr.includes("/anthropic/v1/messages") && body && !body.stream) {
        // Return two tool_use blocks
        return new Response(JSON.stringify({
          id: "msg_multi",
          type: "message",
          role: "assistant",
          content: [
            { type: "text", text: "Let me search both of those." },
            { type: "tool_use", id: ID1, name: "web_search", input: { query: "AI news" } },
            { type: "tool_use", id: ID2, name: "web_search", input: { query: "tech trends" } },
          ],
          stop_reason: "tool_use",
          usage: { input_tokens: 60, output_tokens: 30 },
        }), { status: 200, headers: { "Content-Type": "application/json" } });
      }
      if (urlStr.includes("/playground/search")) {
        const q = new URL(urlStr, "http://x").searchParams.get("q") ?? "";
        searchQueries.push(q);
        return new Response(JSON.stringify({ results: [], query: q }), { status: 200, headers: { "Content-Type": "application/json" } });
      }
      if (urlStr.includes("/anthropic/v1/messages") && body?.stream) {
        leg2Body = body;
        return makeAnthropicSseResponse("Combined answer.");
      }
      return new Response("", { status: 404 });
    });

    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "claude-haiku-4-5" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "claude-haiku-4-5" }));
    await userEvent.click(screen.getByRole("button", { name: "Web Search" }));
    await userEvent.type(screen.getByLabelText("User message"), "latest AI and tech news");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).not.toBeDisabled());
    await userEvent.click(screen.getByRole("button", { name: "Run" }));
    await waitFor(() => expect(screen.getByLabelText("Response").textContent).toContain("Combined answer."));

    // Both searches must have been called
    expect(searchQueries).toContain("AI news");
    expect(searchQueries).toContain("tech trends");

    // Leg 2 must have a tool_result for EACH tool_use id
    const lastUser = [...leg2Body.messages].reverse().find((m: any) => m.role === "user");
    const toolResults = Array.isArray(lastUser?.content)
      ? lastUser.content.filter((b: any) => b.type === "tool_result")
      : [];
    expect(toolResults).toHaveLength(2);
    const ids = toolResults.map((r: any) => r.tool_use_id);
    expect(ids).toContain(ID1);
    expect(ids).toContain(ID2);
  });

  it("leg 2 tool_result tool_use_id matches the id from leg 1 tool_use block", async () => {
    const TOOL_ID = "toolu_reg_001";
    const { getLeg2Body } = await setupAndRunWebSearch("Answer after search.");
    await waitFor(() => expect(screen.getByLabelText("Response").textContent).toContain("Answer after search."));

    const leg2 = getLeg2Body();
    const assistantMsg = leg2.messages.find((m: any) => m.role === "assistant");
    const toolUse = assistantMsg?.content?.find((b: any) => b.type === "tool_use");
    expect(toolUse?.id).toBe(TOOL_ID);

    const lastUserMsg = [...leg2.messages].reverse().find((m: any) => m.role === "user");
    const toolResult = Array.isArray(lastUserMsg?.content)
      ? lastUserMsg.content.find((b: any) => b.type === "tool_result")
      : null;
    expect(toolResult).toBeDefined();
    expect(toolResult.tool_use_id).toBe(TOOL_ID);
  });

  it("shows 'searching' chip while leg 2 is streaming", async () => {
    await setupAndRunWebSearch("Answer.");
    // At some point during the run the search indicator must appear
    await waitFor(() => {
      const response = screen.getByLabelText("Response");
      expect(response.textContent).toMatch(/searching|searched/i);
    });
  });

  it("displays final streamed answer in response panel", async () => {
    await setupAndRunWebSearch("Final grounded answer from web.");
    await waitFor(() =>
      expect(screen.getByLabelText("Response").textContent).toContain("Final grounded answer from web.")
    );
  });

  it("fix 1: leg 1 system field contains web search instruction", async () => {
    const TOOL_ID = "toolu_fix1";
    let leg1Body: any = null;

    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TENANT1]);
      if (path === "/models") return Promise.resolve(MODELS_WITH_CLAUDE);
      if (path === "/tenants/t1/gateways") return Promise.resolve([GW1]);
      return Promise.resolve([]);
    });
    mockApi.post.mockResolvedValue(PLAY_TOKEN);

    vi.spyOn(global, "fetch").mockImplementation(async (url, init) => {
      const urlStr = String(url);
      const body = init?.body ? JSON.parse(String(init.body)) : null;
      if (urlStr.includes("/anthropic/v1/messages") && body && !body.stream) {
        leg1Body = body;
        return makeAnthropicToolUseResponse(TOOL_ID, "ai news");
      }
      if (urlStr.includes("/playground/search")) {
        return new Response(JSON.stringify({ results: [], query: "ai news" }), { status: 200 });
      }
      if (urlStr.includes("/anthropic/v1/messages") && body?.stream) {
        return makeAnthropicSseResponse("Done.");
      }
      return new Response("", { status: 404 });
    });

    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "claude-haiku-4-5" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "claude-haiku-4-5" }));
    await userEvent.click(screen.getByRole("button", { name: "Web Search" }));
    await userEvent.type(screen.getByLabelText("User message"), "latest AI news");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).not.toBeDisabled());
    await userEvent.click(screen.getByRole("button", { name: "Run" }));
    await waitFor(() => expect(screen.getByLabelText("Response").textContent).toContain("Done."));

    expect(leg1Body?.system).toBeDefined();
    expect(leg1Body.system).toMatch(/web_search/i);
  });

  it("fix 1: user system prompt is preserved alongside the injected instruction", async () => {
    const TOOL_ID = "toolu_fix1b";
    let leg1Body: any = null;

    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TENANT1]);
      if (path === "/models") return Promise.resolve(MODELS_WITH_CLAUDE);
      if (path === "/tenants/t1/gateways") return Promise.resolve([GW1]);
      return Promise.resolve([]);
    });
    mockApi.post.mockResolvedValue(PLAY_TOKEN);

    vi.spyOn(global, "fetch").mockImplementation(async (url, init) => {
      const urlStr = String(url);
      const body = init?.body ? JSON.parse(String(init.body)) : null;
      if (urlStr.includes("/anthropic/v1/messages") && body && !body.stream) {
        leg1Body = body;
        return makeAnthropicToolUseResponse(TOOL_ID, "ai news");
      }
      if (urlStr.includes("/playground/search")) {
        return new Response(JSON.stringify({ results: [], query: "ai news" }), { status: 200 });
      }
      if (urlStr.includes("/anthropic/v1/messages") && body?.stream) {
        return makeAnthropicSseResponse("Done.");
      }
      return new Response("", { status: 404 });
    });

    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    // Open system prompt and type custom instruction
    await userEvent.click(screen.getByRole("button", { name: "System prompt" }));
    await userEvent.type(screen.getByLabelText("System prompt"), "Be concise.");
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "claude-haiku-4-5" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "claude-haiku-4-5" }));
    await userEvent.click(screen.getByRole("button", { name: "Web Search" }));
    await userEvent.type(screen.getByLabelText("User message"), "latest AI news");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).not.toBeDisabled());
    await userEvent.click(screen.getByRole("button", { name: "Run" }));
    await waitFor(() => expect(screen.getByLabelText("Response").textContent).toContain("Done."));

    expect(leg1Body?.system).toContain("Be concise.");
    expect(leg1Body?.system).toMatch(/web_search/i);
  });

  it("fix 2: shows search hint when message contains search keywords and toggle is off", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TENANT1]);
      if (path === "/models") return Promise.resolve(MODELS_WITH_CLAUDE);
      if (path === "/tenants/t1/gateways") return Promise.resolve([GW1]);
      return Promise.resolve([]);
    });
    mockApi.post.mockResolvedValue(PLAY_TOKEN);

    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    // Select a Claude model
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "claude-haiku-4-5" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "claude-haiku-4-5" }));

    // Type a search-like message with toggle OFF
    await userEvent.type(screen.getByLabelText("User message"), "What is the latest news?");
    await waitFor(() => expect(screen.getByLabelText("Web search hint")).toBeInTheDocument());
  });

  it("fix 2: hint disappears when web search is enabled", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TENANT1]);
      if (path === "/models") return Promise.resolve(MODELS_WITH_CLAUDE);
      if (path === "/tenants/t1/gateways") return Promise.resolve([GW1]);
      return Promise.resolve([]);
    });
    mockApi.post.mockResolvedValue(PLAY_TOKEN);

    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "claude-haiku-4-5" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "claude-haiku-4-5" }));
    await userEvent.type(screen.getByLabelText("User message"), "What is the latest news?");
    await waitFor(() => expect(screen.getByLabelText("Web search hint")).toBeInTheDocument());

    // Enable web search — hint should vanish
    await userEvent.click(screen.getByRole("button", { name: "Web Search" }));
    await waitFor(() => expect(screen.queryByLabelText("Web search hint")).not.toBeInTheDocument());
  });

  it("fix 2: hint not shown for non-Claude models", async () => {
    setupDefaultMocks(); // uses MODELS which has gpt-4o but no claude-haiku-4-5
    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "gpt-4o" }));
    await userEvent.type(screen.getByLabelText("User message"), "What is the latest news?");
    // No hint — gpt-4o doesn't use the agentic loop
    expect(screen.queryByLabelText("Web search hint")).not.toBeInTheDocument();
  });

  it("non-Claude models use compat path even with web search enabled (no agentic loop)", async () => {
    mockApi.get.mockImplementation((path: string) => {
      if (path === "/tenants") return Promise.resolve([TENANT1]);
      if (path === "/models") return Promise.resolve(MODELS);
      if (path === "/tenants/t1/gateways") return Promise.resolve([GW1]);
      return Promise.resolve([]);
    });
    mockApi.post.mockResolvedValue(PLAY_TOKEN);

    const fetchSpy = vi.spyOn(global, "fetch").mockResolvedValue(makeSseResponse("compat answer"));

    renderPlayground();
    await waitFor(() => expect(screen.getByText("token active")).toBeInTheDocument());

    // Select gpt-4o (non-Claude)
    const pickerBtn = screen.getAllByRole("button").find((b) => b.textContent?.includes("Select model"))!;
    await userEvent.click(pickerBtn);
    await waitFor(() => expect(screen.getByRole("option", { name: "gpt-4o" })).toBeInTheDocument());
    await userEvent.click(screen.getByRole("option", { name: "gpt-4o" }));

    // Enable web search
    await userEvent.click(screen.getByRole("button", { name: "Web Search" }));

    await userEvent.type(screen.getByLabelText("User message"), "search for something");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run" })).not.toBeDisabled());
    await userEvent.click(screen.getByRole("button", { name: "Run" }));

    await waitFor(() => expect(screen.getByText("compat answer")).toBeInTheDocument());
    // Must have used the compat endpoint, not the Anthropic native one
    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining("/compat/chat/completions"),
      expect.anything()
    );
    expect(fetchSpy).not.toHaveBeenCalledWith(
      expect.stringContaining("/anthropic/v1/messages"),
      expect.anything()
    );
  });
});
