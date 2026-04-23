# Documentation Review Prompt

Use this prompt to instruct Claude to audit the AI Gateway documentation for consistency
with the actual implementation, then update docs and screenshots accordingly.

---

## Prompt

You are auditing the documentation for **AI Gateway by Myra Security** to ensure every
page is accurate, consistent with the real implementation, and supported by up-to-date
screenshots. You have access to all source files.

Work through the checklist below in order. For each item: read the authoritative source
first, then read the corresponding doc page, then fix every discrepancy you find. After
all doc edits, run `bash docs/gen_docs.sh` once. After all screenshot updates, run the
Playwright test once.

---

### 0. Ground rules

- The product name is **AI Gateway by Myra Security**. Never mention OpenResty, nginx,
  LuaJIT, or any internal infrastructure component.
- All doc edits must be followed immediately by `bash docs/gen_docs.sh` (memory rule).
- Screenshots are captured by `frontend/tests/screenshots.spec.ts` via Playwright.
  Run them with: `cd frontend && npx playwright test tests/screenshots.spec.ts --headed`
  Screenshots land in `docs/docs.md/assets/screenshots/`.
- For any screenshot that shows wrong data (wrong tenant, wrong page, empty state),
  fix the Playwright test first, then re-run it.

**Important — treat this prompt as a checklist, not a source of truth.** Every specific
claim in this prompt about field names, response shapes, enum values, operator sets, or
behavioral details is a hypothesis from the last time this prompt was written. It may be
outdated. Always derive facts from the source files. If source and prompt disagree,
trust the source, fix the documentation, and ignore the prompt's claim.

---

### 1. Admin API — response shapes

**Source of truth:** `src/storage/mysql.lua` (all SQL queries and row-to-JSON mapping),
`src/admin/api.lua` (handler logic, HTTP status codes, error shapes).

Check every JSON example in these doc pages against what the SQL queries actually return:

| Doc page | Key things to verify |
|---|---|
| `api-reference/tenants-gateways.md` | Tenant fields (id, slug, plan, budget_usd, budget_period, created_at); gateway fields; create/update response shape; `created_at` is a Unix integer (seconds since epoch), not an ISO string |
| `api-reference/users-tokens.md` | User fields; token creation response shape (read the `send()` call in the POST /gateways/:id/tokens handler in `api.lua`); list returns token_hash not plaintext; `created_at` format |
| `api-reference/routing-rules.md` | Rule fields; condition field names and operators (read `src/routing/engine.lua` — enumerate exactly what is implemented, no more, no less); notation style for `header:` and `meta:` prefixes |
| `api-reference/logs.md` | Log entry fields; filter parameter names (`guardrail_outcome` vs `guardrail_verdict`); pagination shape |
| `api-reference/stats.md` | Stats response fields; query parameters |
| `api-reference/traces.md` | Trace fields; response shape |
| `api-reference/models.md` | Model list fields |
| `api-reference/error-codes.md` | Error code strings and HTTP status codes match `src/core/errors.lua` |
| `api-reference/authentication.md` | Auth flow matches `src/middleware/auth.lua` |

For each page:
1. Read the relevant Lua source files.
2. Read the doc page.
3. List every discrepancy (wrong field name, wrong type, missing field, extra field,
   wrong HTTP status, wrong error code, wrong example value).
4. Fix all discrepancies in the doc.

---

### 2. Gateway configuration reference

**Source of truth:** `src/core/config.lua` (default values, field names, types),
`src/middleware/` (which fields are actually consumed and how).

Check `reference/config-reference.md` and `api-reference/tenants-gateways.md`
(Gateway config structure section):
- Every config field listed must exist in `config.lua`.
- Default values must match.
- No fields may be listed that don't exist.
- Field types and allowed values must be accurate.
- `budget_period` belongs to tenants, not to tokens.
- `rate_limit` shape: `{requests: N, window_sec: S}`.

---

### 3. Routing rules

**Source of truth:** `src/routing/engine.lua`.

Verify in `routing/routing-rules.md` and `api-reference/routing-rules.md`:
- Condition fields: read `engine.lua` and enumerate exactly what fields are handled.
  Verify the docs list exactly that set — no more, no less.
- Condition operators: read `engine.lua` and enumerate exactly what operators are
  implemented. Verify the docs list exactly that set — no more, no less.
- Field notation: read how `header:` and `meta:` prefixes are parsed — verify docs
  use the exact same notation (colon vs dot, capitalisation).
- Fallback behavior: each fallback attempted once; only primary uses retry_count.
- Rule cache TTL and refresh behavior.
- Priority tie-breaking.

---

### 4. Guardrails

**Source of truth:** `src/guardrails/` (all .lua files), `src/middleware/guardrails.lua`,
`src/middleware/guardrails_response.lua`.

Verify `security/guardrails.md` and all `security/guardrails/*.md` pages:
- Guardrail types listed match exactly what is implemented.
- Tier 1 vs Tier 2 classification is correct for each type.
- `jailbreak` type: zero-config, uses keyword.lua under the hood, built-in phrase list.
  Verify the phrase count and any listed phrases against `src/guardrails/jailbreak.lua`.
- `scrub` not supported on keyword and prompt_guard — verify against source.
- `fail_open` applies only to Tier 2 — verify.
- Log fields (`blocked`, `blocked_by`, `block_reason`, `detectors_fired`) match
  what `src/middleware/guardrails.lua` actually sets on the log entry.
- Block response format (HTTP 200 with assistant-role message) verified against source.
- `scrub_placeholder` custom value: verify it is actually supported for regex guardrail.
- PII Protector: verify tokenization/detokenization flow matches `src/guardrails/pii_protector.lua`.

---

### 5. Budget & quota

**Source of truth:** `src/middleware/quota.lua`, `src/utils/budget.lua`,
`src/storage/mysql.lua` (spend_ledger queries).

Verify `configuration/budgets.md`:
- Which levels have budgets (tenant, gateway, token).
- `budget_period` values and reset behavior.
- What happens on `QUOTA_EXCEEDED`: HTTP status, error body.
- Reset endpoints and their effect.
- Per-token budget (`budget_usd` on token) vs gateway-level budget.

---

### 6. Rate limiting

**Source of truth:** `src/middleware/rate_limit.lua`, `src/state/`.

Verify `configuration/rate-limiting.md`:
- Window algorithm (sliding vs fixed).
- Where state is stored (shared dict, Redis).
- How gateway-level and per-token rate limits interact — read `rate_limit.lua` to determine
  whether they are independent checks or one overrides the other. Update docs to match.
- HTTP response on rate limit exceeded: status code, error code string.
- `rate_limit` shape: `{requests: N, window_sec: S}`.

---

### 7. Authentication & BYOK

**Source of truth:** `src/middleware/auth.lua`, `src/auth/byok.lua`,
`src/middleware/byok.lua`.

Verify `security/authentication.md` and `security/byok.md`:
- Token format prefix (aig_).
- Hashing method (SHA-256).
- How gateway access grants are checked for member-role users.
- Admin tokens valid on all gateways.
- BYOK: which providers support it, how the key is passed, header name.

---

### 8. Providers

**Source of truth:** `src/utils/` (provider-specific files), `src/middleware/transform.lua`,
`src/middleware/upstream.lua`.

For each provider page (`providers/*.md`):
- Endpoint URL format matches what the gateway actually constructs.
- Auth header name and format.
- Any provider-specific config fields (azure_endpoint, bedrock_region, etc.).
- Verify Azure, Bedrock, Vertex config fields match `src/core/config.lua`.

---

### 9. Request pipeline

**Source of truth:** `src/core/pipeline.lua`, `src/core/gateway.lua`.

Verify `concepts/request-pipeline.md`:
- Middleware execution order matches the actual pipeline definition.
- Every middleware stage listed must exist.
- No stages listed that don't exist.

---

### 10. Observability — frontend pages

**Source of truth:** React components in `frontend/src/modules/`.

| Doc page | Component | Key things to verify |
|---|---|---|
| `observability/dashboard.md` | `Dashboard.tsx` | Hero card count and labels; sparklines; timeframe options; table names |
| `observability/analytics.md` | `TenantAnalytics.tsx` | Hero card count and labels; tab names and column names; period selector options; chart types |
| `observability/logging.md` | `Logs.tsx` | Filter field names; column names; pagination |
| `observability/playground.md` | `Playground.tsx` | UI element names; tenant/gateway/model selectors |
| `observability/tracing.md` | `Monitor.tsx` | Tracing toggle fields; trace display |

---

### 11. Screenshots

For each screenshot referenced in any doc page (find with `grep -r "screenshots/" docs/docs.md`):

1. Confirm the screenshot file exists in `docs/docs.md/assets/screenshots/`.
2. Open the corresponding Playwright test in `frontend/tests/screenshots.spec.ts`.
3. Verify the test navigates to the correct page/state:
   - Uses `myratest` tenant (not `test-tenant`) wherever a tenant selector is visible.
   - Captures the correct UI component (not an unrelated modal or page).
   - Waits for data to load before capturing.
4. If any test is wrong, fix it.

After fixing all tests, run:
```
cd frontend && npx playwright test tests/screenshots.spec.ts --headed
```

Review each generated screenshot visually. A good screenshot should:
- Show meaningful data (not empty state / loading spinner).
- Show the correct page/component described in the surrounding doc text.
- Not show development artifacts (console errors, localhost URLs in wrong places).

---

### 12. Cross-page consistency

After fixing individual pages, do a final cross-check:

- Every `budget_period` reference: verify allowed values against `src/utils/budget.lua`
  or `src/storage/mysql.lua`; ensure docs list exactly those values.
- Every `rate_limit` shape: verify the key names against `src/middleware/rate_limit.lua`;
  ensure all docs use the same shape.
- Every `created_at` example value: Unix integer (seconds since epoch) — all timestamp
  fields are now returned as raw integers from MySQL, not formatted ISO-8601 strings.
- Every token creation response: read the `send()` call in the POST tokens handler in
  `api.lua`; all examples must match exactly.
- Every tenant/gateway create response: same — read `api.lua` and match.
- Internal links: every `[text](path.md)` resolves to a file that actually exists.
- "See also" sections: all linked pages exist.

---

### 13. Final steps

1. Run `bash docs/gen_docs.sh` to rebuild HTML and llms.txt.
2. Optionally run `python3 docs/gen_pdf.py` to regenerate the PDF with a timestamped filename.
3. Report a summary of every change made, grouped by source file, with a one-line
   description of the discrepancy that was fixed.
