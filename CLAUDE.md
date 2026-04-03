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

---

## E2E Testing — MANDATORY for every feature

**Every feature must ship with a full Playwright E2E test suite. No manual testing is acceptable.**

### Running tests

E2E tests require the Vite dev server running as a proxy to the Docker container:

```bash
# Terminal 1 — keep running
cd frontend && npm run dev

# Terminal 2 — run tests
cd frontend && npx playwright test tests/<feature>.spec.ts --reporter=list
```

Run all tests:
```bash
cd frontend && npx playwright test --reporter=list
```

Run a single test by name:
```bash
cd frontend && npx playwright test --grep "test name here" --reporter=list
```

The Vite dev server at `http://localhost:5173` proxies `/admin/v1` and `/admin/auth` to the Docker container. **The Docker container must be running** before tests are executed.

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
- Default test user: `sascha@schumann.net` (admin role)
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

## Lua / backend changes

```bash
bash run_docker_production.sh
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
cd frontend
npx playwright test tests/screenshots.spec.ts \
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
3. npx playwright test screenshots  # capture screenshots against the running container
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
