# AI Gateway — Claude Code Instructions

These instructions apply to every session in this repository. Follow them exactly.

---

## E2E Testing — MANDATORY for every feature

**Every feature must ship with a full Playwright E2E test suite. No manual testing is acceptable.**

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

## Deploying changes

### Frontend changes only (React / TypeScript / CSS)

```bash
bash build_frontend.sh
```

Run from `/home/sas/work/ai-gateway/`. NEVER run `npm run build` or `vite build` directly —
the script sets four mandatory `VITE_*` env vars that get baked into the bundle.

### Lua / backend / config changes

```bash
bash run_docker_production.sh
```

Lua files are **baked into the Docker image** — they are NOT volume-mounted.
`sudo openresty -s reload` only works for a locally-running openresty; it has no effect on Docker.
`docker compose up -d` alone will crash-loop (the entrypoint requires `AIG_LAUNCHED_BY_SCRIPT=1`
and the secrets injected by the script). Only use `run_docker_production.sh`.

If a clean rebuild is needed: `docker compose build --no-cache` first, then `bash run_docker_production.sh`.

### Documentation changes

After any change to files under `docs/docs.md/`:

1. Update `docs/mkdocs.yml` nav if pages were added or sections moved
2. Run `./create_map.sh` from `docs/` — regenerates `topic-map.md` and calls `gen_docs.sh`

`create_map.sh` is always safe to use. If only the nav changed (no new files), `./gen_docs.sh` directly is sufficient.

---

## Database

- **Only MySQL/MariaDB** — there is NO SQLite in production or Docker
- MariaDB runs on the host at `172.17.0.1:3306`
- Production DB: `ai_gateway` | Dev DB: `gateway_dev`
- MySQL user: `gateway` / `gateway`

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
