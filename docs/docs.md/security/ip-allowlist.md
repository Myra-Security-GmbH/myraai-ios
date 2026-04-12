---
title: IP allowlist
description: How AI Gateway by Myra Security restricts inference access by source IP address using CIDR-notation allowlist entries.
---

# IP allowlist

The IP allowlist restricts which source IP addresses can send inference requests to a gateway. The gateway evaluates the allowlist in the access phase, after authentication.

## How the IP allowlist works

When `ip_allowlist` contains one or more entries, any request from a source IP that does not match at least one entry is rejected with `403 Forbidden`. An empty list (the default) allows all source IPs.

- CIDR notation is supported (e.g. `10.0.0.0/8`, `192.168.1.0/24`).
- A bare IP address without a prefix is treated as a `/32` (exact match).
- Both IPv4 addresses and CIDR ranges are supported.
- The check uses the connecting client IP as seen by the gateway. When the gateway is deployed behind a load balancer, IP evaluation uses the original client IP from forwarding headers automatically.

> 💡 **Note:** The IP allowlist applies only to inference endpoints. Admin API requests are subject to separate access controls and are not filtered by the `ip_allowlist` configuration of the gateway.

## CIDR notation

| Entry | Matches |
|---|---|
| `203.0.113.42` | Exactly `203.0.113.42` |
| `203.0.113.0/24` | `203.0.113.0` – `203.0.113.255` |
| `10.0.0.0/8` | `10.0.0.0` – `10.255.255.255` |
| `172.16.0.0/12` | `172.16.0.0` – `172.31.255.255` |
| `192.168.0.0/16` | `192.168.0.0` – `192.168.255.255` |

## Load balancer forwarding

When the gateway sits behind a load balancer or reverse proxy, configure allowlist entries to match the true client IP ranges. The gateway reads the original client IP from forwarding headers automatically — proxy IPs are not evaluated.

## Block response format

When a request is blocked by the IP allowlist, the gateway returns:

```json
{
  "error": {
    "code": "FORBIDDEN",
    "message": "Access denied",
    "blocked_by": "ip_allowlist"
  }
}
```

The `blocked_by` field identifies the IP allowlist as the reason, which distinguishes this from authentication failures in client-side error handling.

---

## Adding an IP allowlist entry

![Screenshot: IP Allowlist field on the Config tab](../assets/screenshots/ip-allowlist-config.png)
*IP Allowlist field on the gateway Config tab*

Proceed as follows to add an IP allowlist entry:

1. Click on **Gateways** in the left sidebar.
   - The gateway list opens.
2. Click on the gateway you want to restrict.
   - The gateway detail page opens.
3. Click on the **Config** tab.
4. Locate the **IP Allowlist** field.
5. Enter one IP address or CIDR range per line in the **IP Allowlist** field.
6. Click on the **Save** button.

→ The allowlist is saved. Requests from IP addresses that do not match any entry are rejected with `403 Forbidden`.

---

## Removing an IP allowlist entry

Proceed as follows to remove an IP allowlist entry:

1. Click on **Gateways** in the left sidebar.
   - The gateway list opens.
2. Click on the gateway whose allowlist you want to modify.
   - The gateway detail page opens.
3. Click on the **Config** tab.
4. Locate the **IP Allowlist** field.
5. Delete the entry or entries you want to remove.
6. Click on the **Save** button.

→ The updated allowlist is saved. To allow all source IPs, clear the IP Allowlist field completely before saving.

---

## API

The `ip_allowlist` field is part of the gateway config object. See [Tenants & Gateways API](../api-reference/tenants-gateways.md) for the PATCH endpoint and request examples.

## See also

- [Authentication](authentication.md)
- [Gateway Configuration](../configuration/gateway-config.md)
- [Routing Rules](../routing/routing-rules.md)
