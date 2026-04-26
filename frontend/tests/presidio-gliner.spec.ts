/**
 * presidio-gliner.spec.ts
 *
 * E2E tests for the Presidio analyzer sidecar after the GLiNER migration.
 * Tests call the analyzer at http://127.0.0.1:5002 directly — no gateway
 * auth is required.
 *
 * Coverage:
 *   • Health / metadata endpoints
 *   • GLiNER NER — English PII (person, org, location, phone)
 *   • GLiNER NER — German PII (person, org, location, date of birth)
 *   • Presidio regex recognisers — language-independent structured PII
 *     (email, IBAN, credit card, phone number)
 *   • Automatic language detection via lingua (en / de)
 *   • Request options: entity filter, score threshold, allow_list
 *   • Edge cases: empty text, whitespace-only input
 */

import { test, expect } from "./base";

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const ANALYZER = "http://127.0.0.1:5002";

// Use a generous inference timeout — the sidecar is warm but GLiNER still
// takes a few hundred milliseconds per request on CPU; GPU is faster.
const TIMEOUT = 20_000;

// ---------------------------------------------------------------------------
// Types & helpers
// ---------------------------------------------------------------------------

interface Entity {
  entity_type: string;
  start: number;
  end: number;
  score: number;
}

/**
 * POST /analyze and return the result list.
 * Defaults: language="auto", score_threshold=0.3 (wide net for tests).
 */
async function analyze(
  request: Parameters<typeof test>[1] extends { request: infer R } ? R : never,
  text: string,
  opts: Record<string, unknown> = {},
): Promise<Entity[]> {
  const res = await (request as any).post(`${ANALYZER}/analyze`, {
    data: { text, language: "auto", score_threshold: 0.3, ...opts },
    timeout: TIMEOUT,
  });
  expect(res.status()).toBe(200);
  return res.json() as Promise<Entity[]>;
}

/** Return the first entity of the given type, or undefined. */
function find(entities: Entity[], type: string): Entity | undefined {
  return entities.find(e => e.entity_type === type);
}

/** Assert at least one entity of *type* exists in *entities*. */
function expectEntity(entities: Entity[], type: string): Entity {
  const hit = find(entities, type);
  if (!hit) {
    throw new Error(
      `Expected entity type "${type}" but got: ${entities.map(e => e.entity_type).join(", ") || "(none)"}`,
    );
  }
  return hit;
}


// ===========================================================================
// 1. Health / metadata endpoints
// ===========================================================================

test.describe("Health and metadata", () => {
  test("GET /health returns 200", async ({ request }) => {
    const res = await request.get(`${ANALYZER}/health`, { timeout: TIMEOUT });
    expect(res.status()).toBe(200);
    const body = await res.text();
    expect(body).toMatch(/up/i);
  });

  test("GET /supportedentities includes both GLiNER and Presidio entity types", async ({ request }) => {
    const res = await request.get(`${ANALYZER}/supportedentities`, { timeout: TIMEOUT });
    expect(res.status()).toBe(200);
    const entities: string[] = await res.json();

    // GLiNER-specific types (not in Presidio's built-in set)
    expect(entities).toContain("ORG");
    expect(entities).toContain("PASSPORT");
    expect(entities).toContain("MEDICAL_LICENSE");

    // Presidio built-in types (regex recognisers)
    expect(entities).toContain("EMAIL_ADDRESS");
    expect(entities).toContain("PHONE_NUMBER");
    expect(entities).toContain("IBAN_CODE");
    expect(entities).toContain("CREDIT_CARD");

    // NER types covered by GLiNER
    expect(entities).toContain("PERSON");
    expect(entities).toContain("LOCATION");
    expect(entities).toContain("DATE_TIME");
  });

  test("GET /recognizers includes GlinerRecognizer", async ({ request }) => {
    const res = await request.get(`${ANALYZER}/recognizers`, { timeout: TIMEOUT });
    expect(res.status()).toBe(200);
    const recognizers: string[] = await res.json();
    expect(recognizers).toContain("GlinerRecognizer");
  });
});


// ===========================================================================
// 2. GLiNER — English PII detection
// ===========================================================================

test.describe("GLiNER — English NER", () => {
  test("detects PERSON", async ({ request }) => {
    const results = await analyze(request,
      "Hello, my name is John Smith and I live in London.",
    );
    expectEntity(results, "PERSON");
  });

  test("detects LOCATION (full address)", async ({ request }) => {
    // gliner_multi_pii-v1 uses the "address" label which targets full postal
    // addresses, not bare city names — use a complete address for reliable detection.
    const results = await analyze(request,
      "Please ship the package to 123 Main Street, San Francisco, CA 94102.",
    );
    expectEntity(results, "LOCATION");
  });

  test("detects ORG", async ({ request }) => {
    const results = await analyze(request,
      "Alice works at Microsoft as a senior engineer.",
    );
    expectEntity(results, "ORG");
  });

  test("detects PHONE_NUMBER (US format)", async ({ request }) => {
    const results = await analyze(request,
      "Please call me back at +1-555-867-5309 any time.",
    );
    expectEntity(results, "PHONE_NUMBER");
  });

  test("detects multiple entity types in one sentence", async ({ request }) => {
    const results = await analyze(request,
      "Dr. Jane Doe from Google, based in Seattle, can be reached at jane.doe@google.com.",
    );
    expectEntity(results, "PERSON");
    expectEntity(results, "EMAIL_ADDRESS");
  });
});


// ===========================================================================
// 3. GLiNER — German PII detection
// ===========================================================================

test.describe("GLiNER — German NER", () => {
  test("detects PERSON in German text", async ({ request }) => {
    const results = await analyze(request,
      "Herr Klaus Müller ist Geschäftsführer der Firma und wohnt in München.",
      { language: "de" },
    );
    expectEntity(results, "PERSON");
  });

  test("detects LOCATION in German text (full address)", async ({ request }) => {
    const results = await analyze(request,
      "Bitte senden Sie die Unterlagen an Herrn Müller, Hauptstraße 15, 80331 München.",
      { language: "de" },
    );
    expectEntity(results, "LOCATION");
  });

  test("detects ORG in German text", async ({ request }) => {
    const results = await analyze(request,
      "Frau Schmidt ist seit Jahren bei der Allianz AG beschäftigt.",
      { language: "de" },
    );
    expectEntity(results, "ORG");
  });

  test("detects DATE_TIME (date of birth) in German text", async ({ request }) => {
    const results = await analyze(request,
      "Hans Bauer wurde am 12. März 1975 in Köln geboren.",
      { language: "de" },
    );
    // GLiNER maps "date of birth" → DATE_TIME
    expectEntity(results, "DATE_TIME");
  });

  test("detects PERSON in German with auto language detection", async ({ request }) => {
    const results = await analyze(request,
      "Laut Vertrag ist Frau Dr. Anna Weber für die Projektleitung verantwortlich.",
      { language: "auto" },
    );
    expectEntity(results, "PERSON");
  });
});


// ===========================================================================
// 4. Presidio regex recognisers (language-independent structured PII)
// ===========================================================================

test.describe("Presidio regex recognisers", () => {
  test("detects EMAIL_ADDRESS", async ({ request }) => {
    const results = await analyze(request,
      "Send your invoice to billing@company.example.com please.",
    );
    const hit = expectEntity(results, "EMAIL_ADDRESS");
    // Regex recogniser returns score 1.0; GLiNER may also contribute — take the max
    expect(hit.score).toBeGreaterThanOrEqual(0.5);
  });

  test("detects IBAN_CODE (German IBAN)", async ({ request }) => {
    const results = await analyze(request,
      "Bitte überweisen Sie den Betrag auf IBAN DE89 3704 0044 0532 0130 00.",
      { language: "auto" },
    );
    expectEntity(results, "IBAN_CODE");
  });

  test("detects CREDIT_CARD number (Luhn-valid)", async ({ request }) => {
    const results = await analyze(request,
      "Card number: 4532015112830366, expiry 09/28.",
    );
    expectEntity(results, "CREDIT_CARD");
  });

  test("detects PHONE_NUMBER (German landline)", async ({ request }) => {
    const results = await analyze(request,
      "Rufen Sie uns an: +49 30 1234567.",
      { language: "auto" },
    );
    expectEntity(results, "PHONE_NUMBER");
  });

  test("detects US_SSN", async ({ request }) => {
    const results = await analyze(request,
      "Social Security Number: 078-05-1120.",
    );
    expectEntity(results, "US_SSN");
  });
});


// ===========================================================================
// 5. Automatic language detection (lingua)
// ===========================================================================

test.describe("Automatic language detection", () => {
  test("long English sentence is processed correctly with language=auto", async ({ request }) => {
    const results = await analyze(request,
      "My colleague Robert Brown from the London office will present his findings at 3 PM.",
    );
    // We care that detection still works — not which language was chosen internally
    expectEntity(results, "PERSON");
  });

  test("long German sentence is processed correctly with language=auto", async ({ request }) => {
    const results = await analyze(request,
      "Die Geschäftsführerin Maria Schneider lud alle Mitarbeiter der Volkswagen AG zum Jahrestreffen ein.",
      { language: "auto" },
    );
    // PERSON and ORG are reliably detected by gliner_multi_pii-v1 in German.
    // LOCATION requires a full postal address (bare city names are not flagged as PII).
    expectEntity(results, "PERSON");
    expectEntity(results, "ORG");
  });

  test("empty language field defaults to auto behaviour without error", async ({ request }) => {
    // Omit language entirely — sidecar should default to auto
    const res = await (request as any).post(`${ANALYZER}/analyze`, {
      data: { text: "John Smith, john@example.com", score_threshold: 0.3 },
      timeout: TIMEOUT,
    });
    expect(res.status()).toBe(200);
    const results: Entity[] = await res.json();
    expect(results.length).toBeGreaterThan(0);
  });
});


// ===========================================================================
// 6. Entity filter, score threshold, allow_list
// ===========================================================================

test.describe("Request filtering options", () => {
  test("entity filter — returns only requested types", async ({ request }) => {
    const results = await analyze(request,
      "Contact Alice Brown at alice@example.com or call +49-89-1234567.",
      { entities: ["PERSON"] },
    );
    // Only PERSON should appear; EMAIL and PHONE must be absent
    expect(results.every(e => e.entity_type === "PERSON")).toBe(true);
    expect(find(results, "EMAIL_ADDRESS")).toBeUndefined();
    expect(find(results, "PHONE_NUMBER")).toBeUndefined();
  });

  test("high score threshold (0.98) suppresses low-confidence GLiNER results", async ({ request }) => {
    // "meeting" is not PII — with a high threshold GLiNER won't fire on ambiguous text
    const results = await analyze(request,
      "We had a meeting in the main conference room.",
      { score_threshold: 0.98 },
    );
    // No high-confidence PII in this sentence
    expect(results.filter(e => e.entity_type === "PERSON").length).toBe(0);
    expect(results.filter(e => e.entity_type === "LOCATION").length).toBe(0);
  });

  test("allow_list (exact) suppresses a matched detection", async ({ request }) => {
    const text = "Please contact John Smith at john@example.com.";

    // Without allow_list: PERSON detected
    const without = await analyze(request, text);
    expectEntity(without, "PERSON");

    // With allow_list containing the exact name: PERSON should be absent (or at least
    // the span covering "John Smith" should be suppressed in GLiNER results)
    const withAllow = await analyze(request, text, {
      allow_list: ["John Smith"],
      allow_list_match: "exact",
    });
    const personHits = withAllow.filter(e => e.entity_type === "PERSON");
    // The span "John Smith" must not appear
    const johnSmithHit = personHits.find(e => text.slice(e.start, e.end) === "John Smith");
    expect(johnSmithHit).toBeUndefined();
  });

  test("score is present and in [0, 1] range on all results", async ({ request }) => {
    const results = await analyze(request,
      "Hans Müller, hans@example.de, IBAN DE89 3704 0044 0532 0130 00.",
      { language: "auto" },
    );
    expect(results.length).toBeGreaterThan(0);
    for (const e of results) {
      expect(e.score).toBeGreaterThanOrEqual(0);
      expect(e.score).toBeLessThanOrEqual(1);
      expect(e.start).toBeGreaterThanOrEqual(0);
      expect(e.end).toBeGreaterThan(e.start);
    }
  });
});


// ===========================================================================
// 7. Edge cases
// ===========================================================================

test.describe("Edge cases", () => {
  test("empty text returns empty array", async ({ request }) => {
    const res = await (request as any).post(`${ANALYZER}/analyze`, {
      data: { text: "", language: "auto", score_threshold: 0.3 },
      timeout: TIMEOUT,
    });
    expect(res.status()).toBe(200);
    const results: Entity[] = await res.json();
    expect(results).toEqual([]);
  });

  test("whitespace-only text returns empty array", async ({ request }) => {
    const res = await (request as any).post(`${ANALYZER}/analyze`, {
      data: { text: "   \n\t  ", language: "auto", score_threshold: 0.3 },
      timeout: TIMEOUT,
    });
    expect(res.status()).toBe(200);
    const results: Entity[] = await res.json();
    expect(results).toEqual([]);
  });

  test("mixed English and German PII in one message", async ({ request }) => {
    const results = await analyze(request,
      "Please transfer funds to Herr Thomas Fischer. IBAN DE89 3704 0044 0532 0130 00. Address: Hauptstraße 15, 80331 München.",
      { language: "auto" },
    );
    expectEntity(results, "PERSON");
    expectEntity(results, "IBAN_CODE");
    expectEntity(results, "LOCATION");
  });
});
