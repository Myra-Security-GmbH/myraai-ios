import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { DetectorBuilder } from "./DetectorBuilder";
import type { DetectorConfig } from "src/api/types";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function setup(initial: DetectorConfig[] = []) {
  const onChange = vi.fn();
  const utils = render(<DetectorBuilder value={initial} onChange={onChange} />);
  return { onChange, ...utils };
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

describe("DetectorBuilder — empty state", () => {
  it("renders the add-detector buttons", () => {
    setup();
    expect(screen.getByText(/\+ Regex \/ Pattern/i)).toBeInTheDocument();
    expect(screen.getByText(/\+ Keyword/i)).toBeInTheDocument();
    expect(screen.getByText(/\+ Presidio/i)).toBeInTheDocument();
    expect(screen.getByText(/\+ Llama Guard/i)).toBeInTheDocument();
  });

  it("shows empty-state message when no detectors", () => {
    setup();
    expect(screen.getByText(/No detectors configured/i)).toBeInTheDocument();
  });

  it("does not show empty-state message when detectors exist", () => {
    const det: DetectorConfig = {
      type: "keyword",
      name: "test",
      action: "flag",
      keywords: [],
    };
    setup([det]);
    expect(screen.queryByText(/No detectors configured/i)).not.toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Adding detectors
// ---------------------------------------------------------------------------

describe("DetectorBuilder — adding detectors", () => {
  it("calls onChange with a new regex detector when + Regex is clicked", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Regex \/ Pattern/i));
    expect(onChange).toHaveBeenCalledOnce();
    const [detectors] = onChange.mock.calls[0];
    expect(detectors).toHaveLength(1);
    expect(detectors[0].type).toBe("regex");
  });

  it("calls onChange with a new keyword detector when + Keyword is clicked", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Keyword/i));
    expect(onChange).toHaveBeenCalledOnce();
    const [detectors] = onChange.mock.calls[0];
    expect(detectors[0].type).toBe("keyword");
  });

  it("calls onChange with a new presidio detector when + Presidio is clicked", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Presidio/i));
    const [detectors] = onChange.mock.calls[0];
    expect(detectors[0].type).toBe("presidio");
  });

  it("calls onChange with a new llm_guard detector when + Llama Guard is clicked", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Llama Guard/i));
    const [detectors] = onChange.mock.calls[0];
    expect(detectors[0].type).toBe("llm_guard");
  });

  it("appends new detectors to existing list", async () => {
    const existing: DetectorConfig[] = [{ type: "keyword", name: "existing", action: "flag", keywords: [] }];
    const { onChange } = setup(existing);
    await userEvent.click(screen.getByText(/\+ Regex \/ Pattern/i));
    const [detectors] = onChange.mock.calls[0];
    expect(detectors).toHaveLength(2);
    expect(detectors[0].type).toBe("keyword");
    expect(detectors[1].type).toBe("regex");
  });
});

// ---------------------------------------------------------------------------
// Detector count display
// ---------------------------------------------------------------------------

describe("DetectorBuilder — detector count", () => {
  it("shows count in label", () => {
    const dets: DetectorConfig[] = [
      { type: "keyword", name: "a", action: "flag", keywords: [] },
      { type: "regex", name: "b", action: "block", patterns: [] },
    ];
    setup(dets);
    expect(screen.getByText(/Detectors \(2\)/i)).toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Detector card rendering
// ---------------------------------------------------------------------------

describe("DetectorBuilder — detector cards", () => {
  it("renders a card for each detector", () => {
    const dets: DetectorConfig[] = [
      { type: "keyword", name: "kw-check", action: "flag", keywords: [] },
      { type: "regex", name: "pii-check", action: "block", patterns: [] },
    ];
    setup(dets);
    const cards = screen.getAllByTestId("detector-card");
    expect(cards).toHaveLength(2);
  });

  it("shows detector name and action in collapsed card", () => {
    const det: DetectorConfig = { type: "keyword", name: "my-detector", action: "block", keywords: [] };
    setup([det]);
    expect(screen.getByText("my-detector")).toBeInTheDocument();
    expect(screen.getByText(/block/i)).toBeInTheDocument();
  });

  it("shows type badge", () => {
    const det: DetectorConfig = { type: "presidio", name: "p", action: "block" };
    setup([det]);
    expect(screen.getByText("Presidio (NLP)")).toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Removing detectors
// ---------------------------------------------------------------------------

describe("DetectorBuilder — removing detectors", () => {
  it("removes a detector when × is clicked", async () => {
    const dets: DetectorConfig[] = [
      { type: "keyword", name: "keep", action: "flag", keywords: [] },
      { type: "regex", name: "remove-me", action: "block", patterns: [] },
    ];
    const { onChange } = setup(dets);
    const removeButtons = screen.getAllByLabelText("Remove detector");
    await userEvent.click(removeButtons[1]); // remove second
    const [updated] = onChange.mock.calls[0];
    expect(updated).toHaveLength(1);
    expect(updated[0].name).toBe("keep");
  });
});

// ---------------------------------------------------------------------------
// Reordering detectors
// ---------------------------------------------------------------------------

describe("DetectorBuilder — reordering", () => {
  it("moves a detector up when ▲ is clicked", async () => {
    const dets: DetectorConfig[] = [
      { type: "keyword", name: "first", action: "flag", keywords: [] },
      { type: "regex", name: "second", action: "block", patterns: [] },
    ];
    const { onChange } = setup(dets);
    const moveUpButtons = screen.getAllByLabelText("Move up");
    // Second card's "move up" button (index 1)
    await userEvent.click(moveUpButtons[1]);
    const [updated] = onChange.mock.calls[0];
    expect(updated[0].name).toBe("second");
    expect(updated[1].name).toBe("first");
  });

  it("moves a detector down when ▼ is clicked", async () => {
    const dets: DetectorConfig[] = [
      { type: "keyword", name: "first", action: "flag", keywords: [] },
      { type: "regex", name: "second", action: "block", patterns: [] },
    ];
    const { onChange } = setup(dets);
    const moveDownButtons = screen.getAllByLabelText("Move down");
    await userEvent.click(moveDownButtons[0]); // first card move down
    const [updated] = onChange.mock.calls[0];
    expect(updated[0].name).toBe("second");
    expect(updated[1].name).toBe("first");
  });

  it("first card has disabled move-up button", () => {
    const dets: DetectorConfig[] = [
      { type: "keyword", name: "only", action: "flag", keywords: [] },
    ];
    setup(dets);
    expect(screen.getByLabelText("Move up")).toBeDisabled();
  });

  it("last card has disabled move-down button", () => {
    const dets: DetectorConfig[] = [
      { type: "keyword", name: "only", action: "flag", keywords: [] },
    ];
    setup(dets);
    expect(screen.getByLabelText("Move down")).toBeDisabled();
  });
});

// ---------------------------------------------------------------------------
// Expanded editor — keyword
// ---------------------------------------------------------------------------

describe("DetectorBuilder — keyword editor", () => {
  it("expands when card header is clicked", async () => {
    const det: DetectorConfig = { type: "keyword", name: "kw", action: "flag", keywords: [] };
    setup([det]);
    // Before expand, keyword-specific content not visible
    expect(screen.queryByPlaceholderText("confidential")).not.toBeInTheDocument();
    // Click header to expand
    await userEvent.click(screen.getByText("kw"));
    expect(screen.getByPlaceholderText("confidential")).toBeInTheDocument();
  });

  it("adds a keyword via the Add button", async () => {
    const det: DetectorConfig = { type: "keyword", name: "kw", action: "flag", keywords: [] };
    const { onChange } = setup([det]);
    await userEvent.click(screen.getByText("kw")); // expand
    const input = screen.getByPlaceholderText("confidential");
    await userEvent.type(input, "secret");
    await userEvent.click(screen.getByRole("button", { name: "Add" }));
    const [updated] = onChange.mock.calls[0];
    expect(updated[0].keywords).toContain("secret");
  });

  it("adds a keyword via Enter key", async () => {
    const det: DetectorConfig = { type: "keyword", name: "kw", action: "flag", keywords: [] };
    const { onChange } = setup([det]);
    await userEvent.click(screen.getByText("kw")); // expand
    const input = screen.getByPlaceholderText("confidential");
    await userEvent.type(input, "topsecret{Enter}");
    const [updated] = onChange.mock.calls[0];
    expect(updated[0].keywords).toContain("topsecret");
  });
});

// ---------------------------------------------------------------------------
// Expanded editor — regex
// ---------------------------------------------------------------------------

describe("DetectorBuilder — regex editor", () => {
  it("shows pattern set checkboxes when expanded", async () => {
    const det: DetectorConfig = { type: "regex", name: "re", action: "block", patterns: [] };
    setup([det]);
    await userEvent.click(screen.getByText("re")); // expand
    expect(screen.getByText("pci_pan")).toBeInTheDocument();
    expect(screen.getByText("hipaa_structured")).toBeInTheDocument();
  });

  it("toggles a pattern set on/off", async () => {
    const det: DetectorConfig = { type: "regex", name: "re", action: "block", patterns: [] };
    const { onChange } = setup([det]);
    await userEvent.click(screen.getByText("re")); // expand
    const pciCheckbox = screen.getByRole("checkbox", { name: /pci_pan/ });
    await userEvent.click(pciCheckbox);
    const [updated] = onChange.mock.calls[0];
    expect(updated[0].patterns).toContain("pci_pan");
  });

  it("adds a custom pattern", async () => {
    const det: DetectorConfig = { type: "regex", name: "re", action: "block", patterns: [], custom_patterns: [] };
    const { onChange } = setup([det]);
    await userEvent.click(screen.getByText("re")); // expand
    const customInput = screen.getByPlaceholderText("%d%d%d%d%-%d%d%d%d");
    await userEvent.type(customInput, "my-regex");
    await userEvent.click(screen.getByRole("button", { name: "Add" }));
    const [updated] = onChange.mock.calls[0];
    expect(updated[0].custom_patterns).toContain("my-regex");
  });
});

// ---------------------------------------------------------------------------
// Expanded editor — presidio
// ---------------------------------------------------------------------------

describe("DetectorBuilder — presidio editor", () => {
  it("shows URL and language fields when expanded", async () => {
    const det: DetectorConfig = { type: "presidio", name: "presidio-check", action: "block" };
    setup([det]);
    await userEvent.click(screen.getByText("presidio-check")); // expand
    expect(screen.getByText("Presidio URL")).toBeInTheDocument();
    expect(screen.getByText("Language")).toBeInTheDocument();
    expect(screen.getByText("Score threshold")).toBeInTheDocument();
  });

  it("adds an entity type", async () => {
    const det: DetectorConfig = { type: "presidio", name: "p", action: "block", entities: [] };
    const { onChange } = setup([det]);
    await userEvent.click(screen.getByText("p")); // expand
    const entityInput = screen.getByPlaceholderText(/PERSON/);
    await userEvent.type(entityInput, "email_address");
    await userEvent.click(screen.getByRole("button", { name: "Add" }));
    const [updated] = onChange.mock.calls[0];
    expect(updated[0].entities).toContain("EMAIL_ADDRESS"); // uppercased
  });
});

// ---------------------------------------------------------------------------
// Expanded editor — llm_guard
// ---------------------------------------------------------------------------

describe("DetectorBuilder — llm_guard editor", () => {
  it("shows URL and timeout fields when expanded", async () => {
    const det: DetectorConfig = { type: "llm_guard", name: "llm-check", action: "block" };
    setup([det]);
    await userEvent.click(screen.getByText("llm-check")); // expand
    expect(screen.getByText("Llama Guard URL")).toBeInTheDocument();
    expect(screen.getByText("Timeout (ms)")).toBeInTheDocument();
  });

  it("adds a safety category", async () => {
    const det: DetectorConfig = { type: "llm_guard", name: "llm", action: "block", categories: [] };
    const { onChange } = setup([det]);
    await userEvent.click(screen.getByText("llm")); // expand
    const catInput = screen.getByPlaceholderText(/S1, S2/);
    await userEvent.type(catInput, "S1");
    await userEvent.click(screen.getByRole("button", { name: "Add" }));
    const [updated] = onChange.mock.calls[0];
    expect(updated[0].categories).toContain("S1");
  });
});
