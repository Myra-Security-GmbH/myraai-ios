# AI Gateway — Claude Code Instructions

These instructions apply to every session in this repository. Follow them exactly.

---

## Quality standard

**All outputs must be of the highest quality. Errors are not permitted.**

- Code must be correct on the first attempt. Do not submit broken code and fix it later.
- Tests must pass before any task is considered complete. A failing test is a blocker, not a note.
- Documentation must be accurate, complete, and consistent with the current state of the product.
- Screenshots in documentation must reflect the actual current UI.
- If something cannot be done correctly, say so — do not produce low-quality output.

### Mandatory completion checklist — every feature

After writing any frontend or backend code, you MUST complete these steps in order before
considering the task done. Skipping any step is not acceptable.

1. **Rebuild the Docker image** — run `bash run_docker_production.sh` from
   `/home/sas/work/ai-gateway/`. Never use `bash build_frontend.sh` alone as the final
   step — it hot-deploys only and does not bake the change into the image.
   - Exception: if only a config file or container environment changed (no source files),
     `sudo systemctl restart myra-ai-gateway` is sufficient for a fast bounce.
   - **Always show the full stdout output** — never pipe through `tail`, `head`, or any
     filter. Redirect stderr to /dev/null if needed: `bash run_docker_production.sh 2>/dev/null`
2. **Run the relevant E2E tests** — start the Vite dev server (`cd frontend && npm run dev`)
   if it is not already running, then execute the test file for the feature you changed:
   ```bash
   cd frontend && ./run-e2e.sh tests/<feature>.spec.ts --reporter=list
   ```
3. **If any test fails**, fix the code, repeat step 1, and re-run. Do not mark the task
   complete while a test is failing.
4. **Run the full suite** when the change is broad or touches shared code:
   ```bash
   cd frontend && ./run-e2e.sh --reporter=list
   ```

---

## E2E Testing — MANDATORY for every feature

**Every feature must ship with a full Playwright E2E test suite. No manual testing is acceptable.**

### Test quality rules — non-negotiable

These rules apply to every test in the suite. Violating them is the same as having no test.

#### No silent skip guards

**Never use `test.skip()` to hide a missing precondition.** If the chat input is not
visible, the gateway selector has no options, or any other required state is absent,
the test must **fail loudly** — not skip silently. A skipped test gives false confidence.

```typescript
// WRONG — hides broken state
if (!await input.isVisible().catch(() => false)) {
  test.skip(true, "Chat input not visible");
  return;
}

// RIGHT — the precondition is set up explicitly before the test body runs
// Use beforeEach or a setup helper that selects a gateway/model via the API,
// and fail the test if setup itself fails.
```

#### Always assert the inference response, not just the request

Any test that sends a message to the inference API (the gateway) must assert that a
**model response was received** — not just that the user message appeared optimistically.

```typescript
// WRONG — only checks the user message echo
await expect(page.getByText(marker)).toBeVisible({ timeout: 5000 });

// RIGHT — also waits for and checks the assistant's reply
await expect(page.locator("[data-cy=assistant-message]").last())
  .not.toBeEmpty({ timeout: 30000 });
```

#### Always assert error banners are absent after success

After any inference call, file upload, or form submission that is expected to succeed,
explicitly assert that no error message is shown:

```typescript
await expect(page.getByText(/failed to fetch/i)).not.toBeVisible();
await expect(page.getByText(/error/i).first()).not.toBeVisible();
```

#### No hardcoded waits

`waitForTimeout` is banned except as an absolute last resort with a comment explaining
why no condition-based wait is possible. Use Playwright's built-in condition waiters:

```typescript
// WRONG
await page.waitForTimeout(1500);

// RIGHT
await expect(page.locator("[data-cy=response-bubble]")).toBeVisible({ timeout: 15000 });
```

#### Inference path must be exercised end-to-end

In the E2E test environment, `VITE_GATEWAY_URL` is unset so inference requests resolve
to a relative `/v1/` path, which the Vite dev server **proxies to the local host openresty
at `127.0.0.1:8081`**. Use gateways whose provider keys are encrypted with the dev master
key (e.g. the `myratest` tenant's "SAFE local only" / vllm preset). The "PII claude-sonnet-4-6"
preset uses Anthropic keys encrypted with the production master key and will fail with
"Provider API key unavailable" in the local test environment — do not rely on it for
inference assertions; use it only for CORS/header regression tests where a provider-level
error is acceptable.

Before any test that sends a message:

1. Select a gateway and model explicitly via the UI or API helpers.
2. Confirm the chat input is enabled (not disabled/hidden).
3. Send the message and assert both user message and assistant response are visible.
4. Assert no error banner is visible.

### Running tests

**Never pipe E2E test output through `tail`, `head`, or any filter.** Always capture the full output — truncating it hides failures.

Both Playwright configs (`playwright.config.ts`, `playwright.docker.config.ts`) use the custom progress reporter at `reporters/progress.ts` — do not pass `--reporter=list` or any other `--reporter` flag.

Run against the Docker container (preferred — no dev server needed):
```bash
cd frontend && ./run-e2e.sh --config playwright.docker.config.ts
```

Run a single spec against Docker:
```bash
cd frontend && ./run-e2e.sh tests/<feature>.spec.ts --config playwright.docker.config.ts
```

Run all tests (dev-server proxy mode):
```bash
cd frontend && ./run-e2e.sh
```

Run a single test by name:
```bash
cd frontend && ./run-e2e.sh --grep "test name here"
```

The Vite dev server at `http://localhost:5173` proxies `/admin/v1` and `/admin/auth` to the Docker container. **The Docker container must be running** before tests are executed.

### Preventing concurrent runs

`run-e2e.sh` wraps `npx playwright test` with an exclusive `flock` lock so only
one Playwright process can run at a time on this machine. Tests create and delete
fixtures in the shared MySQL database — two simultaneous runs will corrupt each
other's state.

```bash
# Use run-e2e.sh instead of npx playwright test directly
cd frontend && ./run-e2e.sh --config playwright.docker.config.ts --reporter=list
```

If you see `ERROR: Another Playwright run is already in progress (PID ...)`,
either wait for it to finish or, if that PID is no longer running, remove the
stale lock:

```bash
rm /tmp/ai-gateway-playwright.lock
```

### Coverage requirements

E2E tests must cover every action a user can realistically take on a feature. A test suite that only covers the happy path is not acceptable. When in doubt, add more tests.

#### 1. Creation — with all parameters

- Create the object with **only required fields** — verify it appears correctly
- Create the object with **all optional fields filled in** — verify every field is saved and displayed
- Create with **boundary values** (max-length names, special characters, whitespace trimming)
- Verify the newly created object appears in the list immediately after creation
- Verify the detail/show view reflects exactly what was entered (no silent data loss)

#### 2. Editing — field by field

- Edit each field individually and verify the change is persisted after save (reload the page and confirm)
- Clear an optional field (set it to empty) and verify it is removed, not retained
- Cancel an edit and verify the original values are unchanged
- Verify the list view updates to reflect edits without requiring a full page reload

#### 3. Deletion

- Delete the object and verify it disappears from the list
- Verify the detail URL now returns 404 or redirects
- Verify cascading effects (e.g. linked records are detached/deleted as documented)
- Test the confirmation step — cancelling must not delete

#### 4. Validation — every constraint

- Submit with the required field empty → expect a visible error message
- Submit with a value that exceeds the maximum length → expect rejection
- Submit with an invalid format (bad email, bad URL, etc.) where applicable
- Verify error messages are specific and visible (not just a generic failure)
- Verify the form is still editable after a validation error (not stuck)

#### 5. List / index view

- Empty state: when no objects exist, the empty-state message is shown
- After creating one object, the list shows it with correct columns
- Clicking a row navigates to the detail view
- Counts and summary fields in the list match the actual data

#### 6. Navigation & routing

- Sidebar link navigates to the feature page
- Direct URL access (`/feature`, `/feature/:id`) works without going through the sidebar first
- The browser back button returns to the expected previous page
- Navigating to a non-existent `:id` shows an appropriate not-found state

#### 7. Permissions

- Actions that require elevated permissions (edit, delete, invite) are **not visible** to users without that permission
- Attempting those actions via the API as an unauthorised user returns the correct error status (403 or 404)
- Read-only users can view but not mutate

#### 8. Integration points

- Test how this feature interacts with adjacent features (e.g. a project linked to a gateway, a conversation linked to a project)
- Verify that data flows correctly between features (e.g. selecting a gateway populates the correct model, selecting a project sets the correct instructions)

#### 9. Regression guards

- Every bug that has been fixed gets its own dedicated test that would have caught it
- Name the test after the symptom: `"gateway dropdown is populated for admin users without personal tenant_id"`

### Environment

- Tests always run against the **Docker production environment** (not the dev server)
- Playwright `baseURL` is `http://localhost:5173` (Vite dev proxy → Docker)
- Admin API base: `http://localhost:5173/admin/v1`
- Use **tenant `myratest`** for all test fixtures that require a tenant
- Default test user: `info@schumann.net` (admin role) — use this for all E2E test fixtures, never `sascha@schumann.net`
- Session is pre-authenticated via `tests/auth.setup.ts` — all tests in the `chromium` project start already logged in

### File location

- Test files go in `frontend/tests/<feature>.spec.ts`
- Follow the existing pattern: named suites (`test.describe`), API helpers at the top, cleanup in `finally` blocks

### API helpers pattern

```typescript
const ADMIN_BASE = "http://localhost:5173/admin/v1";

async function getFirstTenantId(page: Page): Promise<string> {
  const resp = await page.context().request.get(`${ADMIN_BASE}/tenants`);
  if (!resp.ok()) return "";
  const tenants = await resp.json() as Array<{ id: string }>;
  return tenants[0]?.id ?? "";
}

async function apiCreate<T>(page: Page, path: string, data: Record<string, unknown>): Promise<T> {
  const resp = await page.context().request.post(`${ADMIN_BASE}${path}`, { data });
  expect(resp.ok(), `POST ${path}: ${await resp.text()}`).toBeTruthy();
  return resp.json() as Promise<T>;
}
```

Always clean up created fixtures in `finally` blocks. Never leave test data in the database.

### cjson / null assertion gotcha

Lua's `cjson` omits `nil` fields — they are absent from JSON, not encoded as `null`.
Use `expect(value == null).toBeTruthy()` instead of `expect(value).toBeNull()` when asserting
that an API field is unset.

---

## Frontend development

### Building and deploying

```bash
bash build_frontend.sh
```

Run from `/home/sas/work/ai-gateway/`. NEVER run `npm run build` or `vite build` directly —
the script sets four mandatory `VITE_*` env vars that get baked into the bundle:
- `VITE_ADMIN_URL=https://ai-api-admin.myra.eu/admin/v1`
- `VITE_AUTH_URL=https://ai-api-admin.myra.eu/admin/auth`
- `VITE_GATEWAY_URL=https://ai-api.myra.eu`
- `VITE_DOCS_URL=https://ai-docs.myra.eu`

`build_frontend.sh` hot-deploys to the running container via `docker cp`. It does **not** rebuild the Docker image. Use `run_docker_production.sh` when a full image rebuild is needed.

### Type checking

Before deploying any frontend change, verify there are no TypeScript errors:

```bash
cd frontend && npx tsc --noEmit
```

A build will succeed even with type errors (Vite transpiles without checking). Always run `tsc --noEmit` explicitly.

### CSS — myraui / Layout.module.scss

All frontend pages and components use the shared CSS module at:
`frontend/src/common/components/layout/Layout.module.scss`

**Never use inline styles or custom CSS classes for things already covered by this module.**
Always check what exists before adding anything. Key classes:

| Category | Classes |
|---|---|
| Page shell | `.page`, `.page-header`, `.page-title`, `.page-subtitle` |
| Buttons | `.btn` + `.btn--primary`, `.btn--secondary`, `.btn--danger`, `.btn--sm` |
| Forms | `.form-group`, `.form-label`, `.form-input`, `.form-hint`, `.form-actions`, `.form-row` |
| Tables | `.table-wrapper`, `.table` |
| Badges | `.badge` + `.badge--success`, `.badge--warning`, `.badge--error`, `.badge--neutral` |
| Alerts | `.alert` + `.alert--success`, `.alert--error` |
| Empty state | `.empty` |
| Detail panel | `.detail-panel`, `.detail-panel-body`, `.detail-header`, `.detail-title` |
| Tabs | `.tabs`, `.tab`, `.tab--active` |
| Stats | `.stats-grid`, `.stat-card`, `.stat-label`, `.stat-value`, `.stat-value--text` |
| Sections | `.section-header`, `.section-title` |
| Drop zone | `.drop-zone`, `.drop-zone--active` |
| Pickers | `.picker-row`, `.picker-group`, `.picker-options`, `.picker-btn`, `.picker-btn--selected` |
| Colour swatches | `.color-swatch`, `.color-swatch--selected` |

Modal dialogs use the shared `<Modal>` component at `frontend/src/common/components/Modal.tsx`.
Never build a custom modal overlay — always use `<Modal>`.

---

## Restarting the gateway

Two commands exist — use the right one:

| Situation | Command |
|---|---|
| Container crashed / needs a bounce | `sudo systemctl restart myra-ai-gateway` |
| Code changed (Lua, frontend, docs) | `bash run_docker_production.sh` |
| Documentation changed + PDF needs updating | `bash run_docker_production.sh --pdf` |

`sudo systemctl restart myra-ai-gateway` restarts the container instantly without rebuilding anything.
It is safe to use any time the image is already up-to-date.

`run_docker_production.sh` does a full rebuild: docs → PDF → frontend → Docker image → container restart.
Use it whenever any source file changed.

The service unit is at `/etc/systemd/system/myra-ai-gateway.service` and is enabled on boot.

---

## Lua / backend changes

```bash
bash run_docker_production.sh
```

PDF generation is skipped by default (it is slow). Pass `--pdf` to include it:

```bash
bash run_docker_production.sh --pdf
```

Lua files are **baked into the Docker image** — they are NOT volume-mounted.
`sudo openresty -s reload` only works for a locally-running openresty; it has no effect on Docker.
`docker compose up -d` alone will crash-loop — the entrypoint requires `AIG_LAUNCHED_BY_SCRIPT=1`
and the secrets injected by `run_docker_production.sh`. Never call `docker compose up` directly.

If a clean rebuild is needed: `docker compose build --no-cache` first, then `bash run_docker_production.sh`.

---

## Documentation changes

### Content changes

After any change to files under `docs/docs.md/`:

1. Update `docs/mkdocs.yml` nav if pages were added or sections moved
2. Run `./gen_docs.sh` from `docs/` — calls `create_map.sh` (regenerates `topic-map.md`), then runs `mkdocs build` + regenerates `llms.txt`

`./gen_docs.sh` is the correct entry point for all documentation builds — run it after any content change.
`./create_map.sh` can be run standalone to regenerate only `topic-map.md` without a full site rebuild.

### Screenshots

After any UI change that affects documentation screenshots, rebuild them:

```bash
cd frontend && ./run-e2e.sh tests/screenshots.spec.ts \
  --config playwright.production.config.ts --project=chromium
```

Output goes to `docs/docs.md/assets/screenshots/*.png`.
Run against the **live production container** — `run_docker_production.sh` must have been run first
so the container serves the latest code.

### PDF generation

`gen_pdf.py` is called automatically inside `run_docker_production.sh` — do not run it separately.
Output: `docs/out/ai-gateway-docs.pdf` (baked into the Docker image, served at `/ai-gateway-docs.pdf`).

### Full pipeline order

`run_docker_production.sh` **must always be last** — it runs `gen_docs.sh` + `gen_pdf.py` internally,
then bakes everything into the Docker image. Running it earlier embeds stale outputs.

```
1. bash build_frontend.sh          # hot-deploy frontend to running container
2. (run E2E tests to verify)
3. cd frontend && ./run-e2e.sh tests/screenshots.spec.ts \
      --config playwright.production.config.ts --project=chromium   # capture screenshots
4. bash run_docker_production.sh   # LAST: gen_docs + gen_pdf + full image rebuild + container restart
```

Steps 1–3 are only needed when their respective outputs changed.
`bash build_frontend.sh` alone is sufficient for a quick frontend-only iteration.

---

## Database

- **Only MySQL/MariaDB** — there is NO SQLite in production or Docker
- MariaDB runs on the host at `172.17.0.1:3306`
- Production DB: `ai_gateway` | Dev DB: `gateway_dev`
- MySQL user: `gateway` / `gateway`

Connect for debugging:
```bash
mysql -h 172.17.0.1 -u gateway -pgateway ai_gateway
```

---

## Infrastructure overview

| Vhost | Purpose |
|---|---|
| `ai.myra.eu:443` | React SPA frontend |
| `ai-api-admin.myra.eu:443` | Admin API (`/admin/`) |
| `ai-api.myra.eu:443` | Inference API (`/v1/`) |
| `ai-docs.myra.eu:443` | Documentation |

Config files used in Docker:
- `config/nginx.docker.conf` → `/etc/openresty/nginx.conf`
- `config/gateway.docker.lua` → `/opt/ai-gateway/config/gateway.lua`
- `config/docker-entrypoint.sh` → validates env vars, starts openresty

---

## Git hygiene

**Never commit:**
- `docs/__pycache__/` — Python bytecode
- `docs/out/` — built site output; generated, not source
- `*.pdf` anywhere — generated outputs, always excluded
- `luacov.stats.out`, `luacov.report.out`, `.luacov` — Lua coverage artefacts
- `frontend/coverage/` — Vitest coverage output
- `test-results/` — Playwright failure screenshots and traces
- Any file containing credentials or secrets (`run_docker_production.sh` is intentionally not committed)

When grouping commits, split by concern: backend (Lua + schema), frontend (React/CSS), docs.
Do not bundle unrelated changes in one commit.
