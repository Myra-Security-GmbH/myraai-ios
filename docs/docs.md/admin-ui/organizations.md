# Organizations

Organizations provide a grouping layer above tenants. They are used to give `member` users a scoped view of the platform — they see only the tenants, gateways, and users that belong to their organization.

---

## Who can manage organizations?

| Role | Capability |
|---|---|
| `admin` | Full CRUD on all organizations |
| `member` | Read-only view of their own organization |

---

## Creating an organization

1. Navigate to **Organizations** in the sidebar (visible to `admin` users only).
2. Click **+ New Organization**.
3. Enter a **name** (display name, e.g. `Acme Corp`) and a **slug** (URL-safe identifier, e.g. `acme-corp`).
4. Click **Create**.

---

## Assigning tenants to an organization

After creating an organization, tenants can be associated with it. This is done at the database level (`tenant.organization_id`). Once a tenant is assigned, `member` users with that `organization_id` will see it in their tenant list.

---

## API reference

All organization endpoints require an `admin` session cookie (`aig_admin`). `member` users may call `GET /admin/v1/organizations/{id}` for their own org and `PATCH` to update it.

| Method | Path | Role required |
|---|---|---|
| `GET` | `/admin/v1/organizations` | `admin` |
| `POST` | `/admin/v1/organizations` | `admin` |
| `GET` | `/admin/v1/organizations/{id}` | `admin` or own org |
| `PATCH` | `/admin/v1/organizations/{id}` | `admin` or own org |
| `DELETE` | `/admin/v1/organizations/{id}` | `admin` |

### Create

```http
POST /admin/v1/organizations
Content-Type: application/json

{
  "name": "Acme Corp",
  "slug": "acme-corp"
}
```

### Response

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "name": "Acme Corp",
  "slug": "acme-corp",
  "created_at": "2026-01-15T10:00:00Z"
}
```
