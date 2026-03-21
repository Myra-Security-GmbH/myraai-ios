# Admin UI

The admin UI is a React single-page application served at `/admin`. It provides full management of tenants, gateways, users, keys, routing rules, detectors, and observability in a browser-based interface.

---

## URL

```
https://<your-gateway-host>/admin
```

---

## Modules

| Module | Path | Description |
|---|---|---|
| Dashboard | `/admin` | Hero cards, sparklines, recent requests, by-tenant breakdown |
| Tenants | `/admin/tenants` | Create, view, and manage tenants |
| Gateways | `/admin/gateways` | Gateway config, routing rules, BYOK key management |
| Users | `/admin/users` | Auth token management per gateway |
| Logs | `/admin/logs` | Searchable, filterable request log viewer |
| Prices | `/admin/prices` | Per-provider per-model pricing table (used for cost calculation) |
| Detectors | `/admin/detectors` | Visual builder for the detector pipeline (regex, keyword, PII, Presidio, LLM Guard) |
| Monitor | `/admin/monitor` | Real-time request stream and live metrics charts |
| Settings | `/admin/settings` | Gateway-level global settings |
| Playground | `/admin/playground` | Interactive multi-model testing interface |

---

## Navigation structure

The left sidebar provides top-level navigation between modules. Within the Gateways module, a secondary tabbed interface covers:

- **Config** — gateway configuration fields (cache TTL, timeouts, auth, log payloads, provider base URLs, Azure/Bedrock/Vertex settings)
- **Routing** — fallback provider/model routing rules with condition builder
- **Keys** — BYOK provider key management (add, delete, alias)

---

## Authentication

The admin UI uses the same token-based auth as the API. On first access, if no session exists, the UI redirects to a login screen.

!!! warning "Admin token security"
    Admin tokens grant full read/write access to all tenants and gateways. Do not share them or embed them in client-side code outside the admin UI.

---

## See also

- [Playground](../observability/playground.md)
- [Admin Dashboard](../observability/dashboard.md)
- [Gateway Configuration](../configuration/gateway-config.md)
- [Quick Start](../getting-started/quick-start.md)
