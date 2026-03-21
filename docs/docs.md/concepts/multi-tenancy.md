# Multi-Tenancy

AI Gateway is designed from the ground up for multi-tenant operation. A single gateway process can serve many independent tenants, each with their own gateways, provider keys, auth tokens, routing rules, and users — with hard isolation boundaries between them.

---

## Object hierarchy

```
Tenant  (id, slug, plan, budget_limit, deleted_at)
  │
  ├── Gateway  (id, slug, config JSONB)
  │     ├── ProviderConfig  (provider, alias, encrypted_key)   ← BYOK
  │     ├── AuthToken       (token_hash, expiry, label, rate_limit, budget_usd, user_id)
  │     └── RoutingRule     (priority, conditions JSONB, actions JSONB, enabled)
  │
  └── User  (id, email, role: admin|member|viewer)
        └── UserGatewayAccess  (user_id, gateway_id)
```

A **Tenant** is the top-level billing and isolation boundary. Each tenant can have multiple **Gateways** — each gateway is an independent policy domain with its own config, keys, tokens, and rules.

**Users** belong to a tenant and are granted per-gateway access via `UserGatewayAccess`. Their role (`admin`, `member`, or `viewer`) determines what they can do across all gateways in the tenant.

---

## URL routing

Every inference request encodes the tenant and gateway in the URL path:

```
POST /v1/{tenant_slug}/{gateway_slug}/{provider}/chat/completions
POST /v1/{tenant_slug}/{gateway_slug}/compat/chat/completions
```

At the access processing phase, the gateway resolves `{tenant_slug}` and `{gateway_slug}` to their internal UUIDs and loads the gateway config. The resolved identifiers are cached in in-process shared memory for `config_cache_ttl` seconds (default: 30 s) to avoid a database read on every request.

!!! note "Slug changes"
    Gateway configuration changes take effect within seconds.

---

## Isolation mechanisms

| Boundary | Mechanism |
|----------|-----------|
| URL routing | `{tenant_slug}/{gateway_slug}` prefix resolved at access processing phase; unknown slugs return `404 TENANT_NOT_FOUND` |
| Internal state isolation | All internal state is namespaced per tenant and gateway — no cross-tenant data leakage is possible |
| Database | `tenant_id` foreign key on all tables; all queries filter by tenant |
| BYOK keys | Encrypted in the database, decrypted only for the matching `gateway_id`; cached in shared memory keyed by `gateway_id:provider:alias` |
| Auth tokens | Scoped to a single gateway; a token issued for gateway A is rejected on gateway B |
| Rate limits and budgets | Tracked per gateway, not shared across tenants or gateways |

---

## User roles

| Role | Inference requests | Admin operations |
|------|-------------------|-----------------|
| `admin` | Yes, on all gateways in the tenant | Full CRUD on tenant, gateways, users, tokens, rules, keys |
| `member` | Yes, on gateways where `UserGatewayAccess` is granted | None |
| `viewer` | No — returns `403 FORBIDDEN` | None |

Role is enforced at the authentication middleware step (access phase, step 3). A `viewer` is blocked before the request body is read.

Per-user gateway access is managed via the admin API:

```bash
# Grant a user access to a specific gateway
curl -X POST "https://<your-gateway-host>/admin/v1/users/{user_id}/gateways/{gw_id}"

# Revoke access
curl -X DELETE "https://<your-gateway-host>/admin/v1/users/{user_id}/gateways/{gw_id}"
```

Deleting a user immediately disables all of their auth tokens.

---

## Auth tokens

Tokens are scoped to a single gateway and carry optional per-token overrides:

| Field | Description |
|-------|-------------|
| `label` | Human-readable name, e.g., `"ci-pipeline"` |
| `expiration` | ISO-8601 timestamp; requests after this date return `401` |
| `rate_limit` | `{"requests": N, "window_sec": S}` — overrides gateway-level rate limit |
| `budget_usd` | Per-token spending cap; takes precedence over gateway-level budget |
| `user_id` | Optional binding to a user; recorded in request logs |

SHA-256 hashes are stored in the database. The plaintext token is shown only once at creation time — it cannot be recovered.

---

## See also

- [Authentication](../security/authentication.md) — token acceptance order, role enforcement
- [BYOK Key Vault](../security/byok.md) — per-gateway provider key encryption
- [Request Pipeline](request-pipeline.md) — where tenant resolution happens in the chain
- [Admin REST API — Tenants & Gateways](../api-reference/tenants-gateways.md)
