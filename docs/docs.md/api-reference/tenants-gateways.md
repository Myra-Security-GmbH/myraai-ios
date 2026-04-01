# Tenants & gateways API

Tenants are the top-level organisational unit. Each tenant contains one or more gateways. A gateway holds a configuration object, a set of provider keys, routing rules, and auth tokens.

**Base URL:** `https://<your-gateway-host>/admin/v1`

---

## Endpoints

| **Method** | **Path** | **Description** |
|---|---|---|
| `GET` | `/tenants` | List all tenants |
| `POST` | `/tenants` | Create a tenant |
| `PATCH` | `/tenants/{id}` | Update a tenant |
| `DELETE` | `/tenants/{id}` | Delete a tenant and all its gateways |
| `GET` | `/tenants/{id}/gateways` | List gateways for a tenant |
| `POST` | `/tenants/{id}/gateways` | Create a gateway |
| `GET` | `/gateways/{id}` | Get a single gateway |
| `PATCH` | `/gateways/{id}` | Update gateway config |
| `DELETE` | `/gateways/{id}` | Delete a gateway |
| `DELETE` | `/gateways/{id}/budget` | Reset the spend counter of the gateway |

---

## Tenants

### Listing tenants

```bash
curl https://<your-gateway-host>/admin/v1/tenants
```

**Response:**

```json
{
  "tenants": [
    {
      "id": "ten_abc123",
      "slug": "myapp",
      "plan": "starter",
      "budget_usd": null,
      "budget_period": "monthly",
      "created_at": "2025-03-21T10:00:00Z"
    }
  ]
}
```

### Creating a tenant

```bash
curl -X POST https://<your-gateway-host>/admin/v1/tenants \
  -H "Content-Type: application/json" \
  -d '{
    "slug": "myapp",
    "plan": "starter",
    "budget_usd": null
  }'
```

| **Field** | **Type** | **Required** | **Description** |
|---|---|---|---|
| `slug` | string | Yes | URL-safe identifier. Must be unique. Used in inference endpoint URLs. |
| `plan` | string | No | Arbitrary plan label (e.g. `starter`, `pro`). Not enforced by the gateway. |
| `budget_usd` | number \| null | No | Tenant-level spend cap in USD. `null` disables the cap. |
| `budget_period` | string | No | Reset period for the spend counter: `"daily"`, `"monthly"`, or `"total"`. Default: `"monthly"`. |

**Response:** `{ "id": "...", "slug": "..." }`

### Updating a tenant

```bash
curl -X PATCH https://<your-gateway-host>/admin/v1/tenants/{id} \
  -H "Content-Type: application/json" \
  -d '{"plan": "pro", "budget_usd": 1000.00, "budget_period": "monthly"}'
```

### Deleting a tenant

```bash
curl -X DELETE https://<your-gateway-host>/admin/v1/tenants/{id}
```

> ⚠️ **Caution:** Deleting a tenant permanently removes all gateways, users, tokens, routing rules, and provider keys belonging to that tenant. This action cannot be undone.

---

## Gateways

### Listing gateways for a tenant

```bash
curl https://<your-gateway-host>/admin/v1/tenants/{tenant_id}/gateways
```

**Response:**

```json
{
  "gateways": [
    {
      "id": "gw_xyz789",
      "tenant_id": "ten_abc123",
      "slug": "production",
      "config": { "auth_required": true, "cache_ttl": 300 },
      "created_at": "2025-03-21T10:00:00Z"
    }
  ]
}
```

### Creating a gateway

```bash
curl -X POST https://<your-gateway-host>/admin/v1/tenants/{tenant_id}/gateways \
  -H "Content-Type: application/json" \
  -d '{
    "slug": "production",
    "config": {
      "auth_required": true,
      "cache_ttl": 300,
      "retry_count": 2,
      "timeout_ms": 30000,
      "log_payloads": true,
      "budget_usd": 500.00,
      "rate_limit": {"requests": 100, "window_sec": 60}
    }
  }'
```

| **Field** | **Type** | **Required** | **Description** |
|---|---|---|---|
| `slug` | string | Yes | URL-safe identifier unique within the tenant. |
| `config` | object | No | Gateway configuration. Omitted fields use defaults. |

**Response:** `{ "id": "...", "slug": "..." }`

### Getting a gateway

```bash
curl https://<your-gateway-host>/admin/v1/gateways/{id}
```

### Updating gateway config

The `PATCH` body must include a `config` key. The config is **merged at the top level** — only fields you include are changed. Nested objects (`rate_limit`) are replaced in full.

```bash
curl -X PATCH https://<your-gateway-host>/admin/v1/gateways/{id} \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "retry_count": 3,
      "timeout_ms": 45000
    }
  }'
```

To override provider base URLs:

```bash
curl -X PATCH https://<your-gateway-host>/admin/v1/gateways/{id} \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "provider_base_urls": {
        "ollama": "http://192.168.1.50:11434"
      }
    }
  }'
```

> 💡 **Note:** The `config` merge is shallow. To clear a nested object (e.g. to remove a rate limit), set the field to `null` explicitly: `"rate_limit": null`.

### Deleting a gateway

```bash
curl -X DELETE https://<your-gateway-host>/admin/v1/gateways/{id}
```

### Resetting the gateway budget counter

Clears the accumulated spend counter. Requests blocked by `QUOTA_EXCEEDED` are allowed again (up to the configured `budget_usd`).

```bash
curl -X DELETE https://<your-gateway-host>/admin/v1/gateways/{id}/budget
```

> ⚠️ **Caution:** Budget resets are immediate and irreversible. Automate monthly resets with a cron job rather than resetting manually.

---

## Gateway config structure

The complete config object with all defaults:

```json
{
  "auth_required": true,
  "budget_usd": null,
  "budget_period": "monthly",
  "tenant_budget_usd": null,
  "tenant_budget_period": "monthly",
  "cache_ttl": 0,
  "retry_count": 2,
  "timeout_ms": 60000,
  "log_payloads": true,
  "rate_limit": null,
  "ip_allowlist": [],
  "guardrails": [],
  "azure_endpoint": null,
  "azure_deployment": null,
  "azure_api_version": "2024-02-01",
  "bedrock_region": "us-east-1",
  "vertex_project": null,
  "vertex_region": "us-central1",
  "provider_base_urls": {}
}
```

For the full field-by-field reference see [Gateway Configuration Reference](../reference/config-reference.md).

---

## See also

- [Gateway Configuration Reference](../reference/config-reference.md)
- [Users & Tokens API](users-tokens.md)
- [Routing Rules API](routing-rules.md)
- [Error Codes](error-codes.md)
- [Budget & Quota Enforcement](../configuration/budgets.md)
