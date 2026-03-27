import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { GuardrailBuilder } from "./GuardrailBuilder";
import type { DetectorConfig } from "src/api/types";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function setup(initial: DetectorConfig[] = []) {
  const onChange = vi.fn();
  const utils = render(<GuardrailBuilder value={initial} onChange={onChange} />);
  return { onChange, ...utils };
}

// ---------------------------------------------------------------------------
// Empty state
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — empty state", () => {
  it("renders the add-guardrail buttons", () => {
    setup();
    expect(screen.getByText(/\+ Regex \/ Pattern/i)).toBeInTheDocument();
    expect(screen.getByText(/\+ Keyword/i)).toBeInTheDocument();
    expect(screen.getByText(/\+ Presidio/i)).toBeInTheDocument();
    expect(screen.getByText(/\+ Prompt Guard/i)).toBeInTheDocument();
  });

  it("shows empty-state message when no guardrails", () => {
    setup();
    expect(screen.getByText(/No guardrails configured/i)).toBeInTheDocument();
  });

  it("does not show empty-state message when guardrails exist", () => {
    const det: DetectorConfig = {
      type: "keyword",
      name: "test",
      action: "flag",
      keywords: [],
    };
    setup([det]);
    expect(screen.queryByText(/No guardrails configured/i)).not.toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Adding guardrails
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — adding guardrails", () => {
  it("calls onChange with a new regex guardrail when + Regex is clicked", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Regex \/ Pattern/i));
    expect(onChange).toHaveBeenCalledOnce();
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails).toHaveLength(1);
    expect(guardrails[0].type).toBe("regex");
  });

  it("calls onChange with a new keyword guardrail when + Keyword is clicked", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Keyword/i));
    expect(onChange).toHaveBeenCalledOnce();
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails[0].type).toBe("keyword");
  });

  it("calls onChange with a new presidio guardrail when + Presidio is clicked", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Presidio/i));
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails[0].type).toBe("presidio");
  });

  it("calls onChange with a new prompt_guard guardrail when + Prompt Guard is clicked", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Prompt Guard/i));
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails[0].type).toBe("prompt_guard");
  });

  it("appends new guardrails to existing list", async () => {
    const existing: DetectorConfig[] = [{ type: "keyword", name: "existing", action: "flag", keywords: [] }];
    const { onChange } = setup(existing);
    await userEvent.click(screen.getByText(/\+ Regex \/ Pattern/i));
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails).toHaveLength(2);
    expect(guardrails[0].type).toBe("keyword");
    expect(guardrails[1].type).toBe("regex");
  });
});

// ---------------------------------------------------------------------------
// Guardrail count display
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — guardrail count", () => {
  it("shows count in label", () => {
    const dets: DetectorConfig[] = [
      { type: "keyword", name: "a", action: "flag", keywords: [] },
      { type: "regex", name: "b", action: "block", patterns: [] },
    ];
    setup(dets);
    expect(screen.getByText(/Guardrails \(2\)/i)).toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Guardrail card rendering
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — guardrail cards", () => {
  it("renders a card for each guardrail", () => {
    const dets: DetectorConfig[] = [
      { type: "keyword", name: "kw-check", action: "flag", keywords: [] },
      { type: "regex", name: "pii-check", action: "block", patterns: [] },
    ];
    setup(dets);
    const cards = screen.getAllByTestId("detector-card");
    expect(cards).toHaveLength(2);
  });

  it("shows guardrail name and action in collapsed card", () => {
    const det: DetectorConfig = { type: "keyword", name: "my-guardrail", action: "block", keywords: [] };
    setup([det]);
    expect(screen.getAllByText("my-guardrail")[0]).toBeInTheDocument();
    expect(screen.getAllByText(/block/i)[0]).toBeInTheDocument();
  });

  it("shows type badge", () => {
    const det: DetectorConfig = { type: "presidio", name: "p", action: "block" };
    setup([det]);
    expect(screen.getByText("Presidio (NLP)")).toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Removing guardrails
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — removing guardrails", () => {
  it("removes a guardrail when × is clicked", async () => {
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
// Reordering guardrails
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — reordering", () => {
  it("moves a guardrail up when ▲ is clicked", async () => {
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

  it("moves a guardrail down when ▼ is clicked", async () => {
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

describe("GuardrailBuilder — keyword editor", () => {
  it("expands when card header is clicked", async () => {
    const det: DetectorConfig = { type: "keyword", name: "kw", action: "flag", keywords: [] };
    setup([det]);
    // Before expand, keyword-specific content not visible
    expect(screen.queryByPlaceholderText("confidential")).not.toBeInTheDocument();
    // Click header to expand
    await userEvent.click(screen.getAllByText("kw")[0]);
    expect(screen.getByPlaceholderText("confidential")).toBeInTheDocument();
  });

  it("adds a keyword via the Add button", async () => {
    const det: DetectorConfig = { type: "keyword", name: "kw", action: "flag", keywords: [] };
    const { onChange } = setup([det]);
    await userEvent.click(screen.getAllByText("kw")[0]); // expand
    const input = screen.getByPlaceholderText("confidential");
    await userEvent.type(input, "secret");
    await userEvent.click(screen.getByRole("button", { name: "Add" }));
    const [updated] = onChange.mock.calls[0];
    expect(updated[0].keywords).toContain("secret");
  });

  it("adds a keyword via Enter key", async () => {
    const det: DetectorConfig = { type: "keyword", name: "kw", action: "flag", keywords: [] };
    const { onChange } = setup([det]);
    await userEvent.click(screen.getAllByText("kw")[0]); // expand
    const input = screen.getByPlaceholderText("confidential");
    await userEvent.type(input, "topsecret{Enter}");
    const [updated] = onChange.mock.calls[0];
    expect(updated[0].keywords).toContain("topsecret");
  });
});

// ---------------------------------------------------------------------------
// Expanded editor — regex
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — regex editor", () => {
  it("shows pattern set checkboxes when expanded", async () => {
    const det: DetectorConfig = { type: "regex", name: "re", action: "block", patterns: [] };
    setup([det]);
    await userEvent.click(screen.getAllByText("re")[0]); // expand
    expect(screen.getByText("pci_pan")).toBeInTheDocument();
    expect(screen.getByText("hipaa_structured")).toBeInTheDocument();
  });

  it("toggles a pattern set on/off", async () => {
    const det: DetectorConfig = { type: "regex", name: "re", action: "block", patterns: [] };
    const { onChange } = setup([det]);
    await userEvent.click(screen.getAllByText("re")[0]); // expand
    const pciCheckbox = screen.getByRole("checkbox", { name: /pci_pan/ });
    await userEvent.click(pciCheckbox);
    const [updated] = onChange.mock.calls[0];
    expect(updated[0].patterns).toContain("pci_pan");
  });

  it("adds a custom pattern", async () => {
    const det: DetectorConfig = { type: "regex", name: "re", action: "block", patterns: [], custom_patterns: [] };
    const { onChange } = setup([det]);
    await userEvent.click(screen.getAllByText("re")[0]); // expand
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

describe("GuardrailBuilder — presidio editor", () => {
  it("shows URL, allow list, and score threshold fields when expanded", async () => {
    const det: DetectorConfig = { type: "presidio", name: "presidio-check", action: "block" };
    setup([det]);
    await userEvent.click(screen.getAllByText("presidio-check")[0]); // expand
    expect(screen.getByText("Presidio URL")).toBeInTheDocument();
    expect(screen.getByText("Allow list")).toBeInTheDocument();
    expect(screen.getByText("Score threshold")).toBeInTheDocument();
  });

  it("adds an entity type", async () => {
    const det: DetectorConfig = { type: "presidio", name: "p", action: "block", entities: [] };
    const { onChange } = setup([det]);
    await userEvent.click(screen.getAllByText("p")[0]); // expand
    const entityInput = screen.getByPlaceholderText(/IN_PAN/);
    await userEvent.type(entityInput, "email_address");
    await userEvent.click(screen.getByRole("button", { name: "Add" }));
    const [updated] = onChange.mock.calls[0];
    expect(updated[0].entities).toContain("EMAIL_ADDRESS"); // uppercased
  });
});

// ---------------------------------------------------------------------------
// Expanded editor — prompt_guard
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — prompt_guard editor", () => {
  it("shows URL and timeout fields when expanded", async () => {
    const det: DetectorConfig = { type: "prompt_guard", name: "pg-check", action: "block" };
    setup([det]);
    await userEvent.click(screen.getAllByText("pg-check")[0]); // expand
    expect(screen.getByText("Llama Guard URL")).toBeInTheDocument();
    expect(screen.getByText("Timeout (ms)")).toBeInTheDocument();
  });

  it("adds a safety category", async () => {
    // Categories are now checkboxes (S1–S14), not a free-text input.
    const det: DetectorConfig = { type: "prompt_guard", name: "pg", action: "block", categories: [] };
    const { onChange, container } = setup([det]);
    await userEvent.click(screen.getAllByText("pg")[0]); // expand
    // Scope to this render's container — the preceding test leaves its expanded
    // editor in the DOM, so screen.getBy* would find duplicate category checkboxes.
    await userEvent.click(within(container).getByRole("checkbox", { name: /^Violent Crimes/i }));
    const [updated] = onChange.mock.calls[0];
    expect(updated[0].categories).toContain("S1");
  });
});

// ---------------------------------------------------------------------------
// Adding pii_protector guardrail
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — pii_protector add button", () => {
  it("renders the + PII Protector button", () => {
    setup();
    expect(screen.getByText(/\+ PII Protector/i)).toBeInTheDocument();
  });

  it("calls onChange with a pii_protector guardrail when clicked", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ PII Protector/i));
    expect(onChange).toHaveBeenCalledOnce();
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails).toHaveLength(1);
    expect(guardrails[0].type).toBe("pii_protector");
  });

  it("default pii_protector has target=both", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ PII Protector/i));
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails[0].target).toBe("both");
  });

  it("default pii_protector has no action field", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ PII Protector/i));
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails[0].action).toBeUndefined();
  });

  it("default pii_protector has score_threshold 0.7", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ PII Protector/i));
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails[0].score_threshold).toBe(0.7);
  });
});

// ---------------------------------------------------------------------------
// pii_protector card rendering
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — pii_protector card", () => {
  const piiDet: DetectorConfig = {
    type: "pii_protector",
    name: "pii-protect",
    target: "both",
    analyzer_url: "http://127.0.0.1:5002",
    entities: [],
    score_threshold: 0.7,
    fail_open: true,
  };

  it("shows PII Protector type badge", () => {
    setup([piiDet]);
    expect(screen.getByText("PII Protector")).toBeInTheDocument();
  });

  it("shows '⟳ protect' in collapsed card summary", () => {
    setup([piiDet]);
    expect(screen.getByText(/⟳ protect/)).toBeInTheDocument();
  });

  it("shows 'both' in collapsed card summary", () => {
    setup([piiDet]);
    expect(screen.getByText(/⟳ protect.*both|both.*⟳ protect/)).toBeInTheDocument();
  });

  it("does not show Action select when card is expanded", async () => {
    setup([piiDet]);
    await userEvent.click(screen.getAllByText("pii-protect")[0]); // expand
    expect(screen.queryByText(/^Action$/i)).not.toBeInTheDocument();
  });

  it("shows locked target label 'request + response' when expanded", async () => {
    setup([piiDet]);
    await userEvent.click(screen.getAllByText("pii-protect")[0]); // expand
    expect(screen.getByText(/request \+ response/i)).toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// pii_protector editor fields
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — pii_protector editor", () => {
  const piiDet: DetectorConfig = {
    type: "pii_protector",
    name: "pii-protect",
    target: "both",
    analyzer_url: "http://127.0.0.1:5002",
    entities: [],
    score_threshold: 0.7,
    fail_open: true,
  };

  it("shows Analyzer URL and Allow list fields when expanded", async () => {
    setup([piiDet]);
    await userEvent.click(screen.getAllByText("pii-protect")[0]); // expand
    expect(screen.getByText("Analyzer URL")).toBeInTheDocument();
    expect(screen.getByText("Allow list")).toBeInTheDocument();
  });

  it("shows Score threshold field when expanded", async () => {
    setup([piiDet]);
    await userEvent.click(screen.getAllByText("pii-protect")[0]); // expand
    expect(screen.getByText("Score threshold")).toBeInTheDocument();
  });

  it("shows reversible tokenization description when expanded", async () => {
    setup([piiDet]);
    await userEvent.click(screen.getAllByText("pii-protect")[0]); // expand
    expect(screen.getByText(/reversible/i)).toBeInTheDocument();
  });

  it("adds an entity type uppercased", async () => {
    const { onChange } = setup([piiDet]);
    await userEvent.click(screen.getAllByText("pii-protect")[0]); // expand
    const entityInput = screen.getByPlaceholderText(/IN_PAN/);
    await userEvent.type(entityInput, "email_address");
    await userEvent.click(screen.getByRole("button", { name: "Add" }));
    const [updated] = onChange.mock.calls[0];
    expect(updated[0].entities).toContain("EMAIL_ADDRESS");
  });

  it("updates analyzer_url when input changes", async () => {
    const { onChange } = setup([piiDet]);
    await userEvent.click(screen.getAllByText("pii-protect")[0]); // expand
    const urlInput = screen.getByDisplayValue("http://127.0.0.1:5002");
    fireEvent.change(urlInput, { target: { value: "http://presidio:5002" } });
    const lastCall = onChange.mock.calls[onChange.mock.calls.length - 1];
    expect(lastCall[0][0].analyzer_url).toBe("http://presidio:5002");
  });
});

// ---------------------------------------------------------------------------
// Execution plan (DetectorPhaseSummary)
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — execution plan", () => {
  it("does not render execution plan when no guardrails", () => {
    setup([]);
    expect(screen.queryByText(/Execution plan/i)).not.toBeInTheDocument();
  });

  it("renders execution plan when guardrails are present", () => {
    const det: DetectorConfig = { type: "keyword", name: "kw", action: "flag", keywords: [] };
    setup([det]);
    expect(screen.getByText(/Execution plan/i)).toBeInTheDocument();
  });

  it("shows correct tier for each guardrail type", () => {
    const dets: DetectorConfig[] = [
      { type: "regex",    name: "re",  action: "block", patterns: [] },
      { type: "presidio", name: "pre", action: "flag" },
    ];
    setup(dets);
    // Tier column cells: regex=1, presidio=2
    const tierCells = screen.getAllByText(/^[12]$/);
    expect(tierCells.length).toBeGreaterThanOrEqual(2);
  });

  it("sorts tier-2 guardrails after tier-1 in the plan", () => {
    const dets: DetectorConfig[] = [
      { type: "presidio", name: "tier2-first", action: "block" },
      { type: "regex",    name: "tier1-second", action: "flag", patterns: [] },
    ];
    setup(dets);
    const rows = screen.getAllByRole("row").filter((r) => r.textContent?.includes("tier"));
    // tier1-second should appear before tier2-first
    expect(rows[0].textContent).toContain("tier1-second");
    expect(rows[1].textContent).toContain("tier2-first");
  });

  it("shows ⟳ reversible for pii_protector in plan", () => {
    const det: DetectorConfig = {
      type: "pii_protector",
      name: "protect",
      target: "both",
    };
    setup([det]);
    expect(screen.getByText(/⟳ reversible/i)).toBeInTheDocument();
  });

  it("shows ⇄ arrow for guardrails with target=both", () => {
    const det: DetectorConfig = {
      type: "pii_protector",
      name: "protect",
      target: "both",
    };
    setup([det]);
    expect(screen.getByText("⇄")).toBeInTheDocument();
  });

  it("shows → arrow for request-phase guardrails", () => {
    const det: DetectorConfig = { type: "keyword", name: "kw", action: "block", keywords: [], target: "request" };
    setup([det]);
    expect(screen.getByText("→")).toBeInTheDocument();
  });

  it("shows ← arrow for response-phase guardrails", () => {
    const det: DetectorConfig = { type: "presidio", name: "p", action: "flag", target: "response" };
    setup([det]);
    expect(screen.getByText("←")).toBeInTheDocument();
  });

  it("plan updates when a guardrail is added", async () => {
    const { onChange } = setup([]);
    expect(screen.queryByText(/Execution plan/i)).not.toBeInTheDocument();
    // Simulate parent passing new value after add
    const det: DetectorConfig = { type: "keyword", name: "new", action: "flag", keywords: [] };
    const { rerender } = render(<GuardrailBuilder value={[det]} onChange={onChange} />);
    expect(screen.getByText(/Execution plan/i)).toBeInTheDocument();
    rerender(<GuardrailBuilder value={[det]} onChange={onChange} />);
  });

  it("plan shows pii_protector tier 2", () => {
    const det: DetectorConfig = { type: "pii_protector", name: "pp", target: "both" };
    setup([det]);
    // Should render tier 2 for pii_protector
    expect(screen.getByText("2")).toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Jailbreak guardrail type — add button
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — jailbreak add button", () => {
  it("renders the + Jailbreak button", () => {
    setup();
    expect(screen.getByText(/\+ Jailbreak/i)).toBeInTheDocument();
  });

  it("calls onChange with type='jailbreak' when clicked", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Jailbreak/i));
    expect(onChange).toHaveBeenCalledOnce();
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails[0].type).toBe("jailbreak");
  });

  it("default jailbreak has action='flag'", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Jailbreak/i));
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails[0].action).toBe("flag");
  });

  it("default jailbreak has whole_word=false", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Jailbreak/i));
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails[0].whole_word).toBe(false);
  });

  it("default jailbreak has case_sensitive=false", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Jailbreak/i));
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails[0].case_sensitive).toBe(false);
  });

  it("default jailbreak keywords list is non-empty (18 built-in phrases)", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Jailbreak/i));
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails[0].keywords.length).toBe(18);
  });

  it("default jailbreak keywords list has no duplicates", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Jailbreak/i));
    const [guardrails] = onChange.mock.calls[0];
    const kws: string[] = guardrails[0].keywords;
    expect(new Set(kws).size).toBe(kws.length);
  });

  it("default jailbreak includes 'ignore previous instructions'", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Jailbreak/i));
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails[0].keywords).toContain("ignore previous instructions");
  });

  it("default jailbreak includes 'DAN mode'", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Jailbreak/i));
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails[0].keywords).toContain("DAN mode");
  });

  it("default jailbreak includes 'prompt injection'", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Jailbreak/i));
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails[0].keywords).toContain("prompt injection");
  });

  it("default jailbreak includes '[SYSTEM]'", async () => {
    const { onChange } = setup();
    await userEvent.click(screen.getByText(/\+ Jailbreak/i));
    const [guardrails] = onChange.mock.calls[0];
    expect(guardrails[0].keywords).toContain("[SYSTEM]");
  });
});

// ---------------------------------------------------------------------------
// Jailbreak guardrail type — card rendering
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — jailbreak card rendering", () => {
  const jbDet: DetectorConfig = {
    type: "jailbreak",
    name: "jailbreak-check",
    action: "flag",
    keywords: ["ignore previous instructions", "DAN mode"],
    whole_word: false,
    case_sensitive: false,
  };

  it("shows 'Jailbreak' type badge", () => {
    setup([jbDet]);
    expect(screen.getByText("Jailbreak")).toBeInTheDocument();
  });

  it("shows name in collapsed card header", () => {
    setup([jbDet]);
    expect(screen.getAllByText("jailbreak-check")[0]).toBeInTheDocument();
  });

  it("shows action in collapsed card header", () => {
    setup([jbDet]);
    expect(screen.getAllByText(/flag/i)[0]).toBeInTheDocument();
  });
});

// ---------------------------------------------------------------------------
// Jailbreak guardrail type — editor
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — jailbreak editor", () => {
  const jbDet: DetectorConfig = {
    type: "jailbreak",
    name: "jailbreak-check",
    action: "flag",
    keywords: ["ignore previous instructions", "DAN mode"],
    whole_word: false,
    case_sensitive: false,
  };

  it("expands when card header is clicked", async () => {
    setup([jbDet]);
    // jbDet has keywords, so the expanded callout says "Custom list active"
    expect(screen.queryByText(/custom list active/i)).not.toBeInTheDocument();
    await userEvent.click(screen.getAllByText("jailbreak-check")[0]);
    expect(screen.getByText(/custom list active/i)).toBeInTheDocument();
  });

  it("shows custom list active notice when keywords are populated", async () => {
    setup([jbDet]);
    await userEvent.click(screen.getAllByText("jailbreak-check")[0]);
    expect(screen.getByText(/custom list active/i)).toBeInTheDocument();
  });

  it("shows built-in phrases notice when keywords is empty", async () => {
    const emptyDet: DetectorConfig = { type: "jailbreak", name: "jb", action: "flag", keywords: [] };
    setup([emptyDet]);
    await userEvent.click(screen.getAllByText("jb")[0]);
    expect(screen.getByText(/using built-in phrases/i)).toBeInTheDocument();
  });

  it("renders keyword chips for each phrase in the list", async () => {
    setup([jbDet]);
    const card = screen.getByTestId("detector-card");
    const header = card.querySelector("span[style*='font-weight: 500']") as HTMLElement;
    await userEvent.click(header);
    expect(screen.getByText(/^ignore previous instructions/)).toBeInTheDocument();
    expect(screen.getByText(/^DAN mode/)).toBeInTheDocument();
  });

  it("adds a custom phrase via input + Add button", async () => {
    const det: DetectorConfig = { type: "jailbreak", name: "jb", action: "flag", keywords: ["existing"] };
    const { onChange } = setup([det]);
    await userEvent.click(screen.getAllByText("jb")[0]);
    const input = screen.getByPlaceholderText("add a phrase…");
    await userEvent.type(input, "new phrase");
    await userEvent.click(screen.getByRole("button", { name: "Add" }));
    const lastCall = onChange.mock.calls[onChange.mock.calls.length - 1];
    expect(lastCall[0][0].keywords).toContain("new phrase");
  });

  it("shows whole_word checkbox (unchecked by default)", async () => {
    setup([jbDet]);
    await userEvent.click(screen.getAllByText("jailbreak-check")[0]);
    const cb = screen.getByRole("checkbox", { name: /whole-word/i });
    expect(cb).not.toBeChecked();
  });

  it("shows case_sensitive checkbox (unchecked by default)", async () => {
    setup([jbDet]);
    await userEvent.click(screen.getAllByText("jailbreak-check")[0]);
    const cb = screen.getByRole("checkbox", { name: /case sensitive/i });
    expect(cb).not.toBeChecked();
  });
});

// ---------------------------------------------------------------------------
// Jailbreak guardrail type — execution plan
// ---------------------------------------------------------------------------

describe("GuardrailBuilder — jailbreak type in execution plan", () => {
  it("appears as Tier 1", () => {
    const det: DetectorConfig = { type: "jailbreak", name: "jb", action: "flag", keywords: [] };
    setup([det]);
    expect(screen.getByText("1")).toBeInTheDocument();
  });

  it("shows → arrow (request phase by default)", () => {
    const det: DetectorConfig = { type: "jailbreak", name: "jb", action: "flag", keywords: [] };
    setup([det]);
    expect(screen.getByText("→")).toBeInTheDocument();
  });

  it("sorts before prompt_guard (Tier 2) in the execution plan", () => {
    const dets: DetectorConfig[] = [
      { type: "prompt_guard", name: "pg", action: "block", categories: ["S1"] },
      { type: "jailbreak",    name: "jb", action: "flag",  keywords: [] },
    ];
    setup(dets);
    const rows = screen.getAllByRole("row").filter((r) =>
      r.textContent?.includes("jb") || r.textContent?.includes("pg")
    );
    expect(rows[0].textContent).toContain("jb");
    expect(rows[1].textContent).toContain("pg");
  });
});
