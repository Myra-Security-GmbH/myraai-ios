# IP Allowlist

The IP allowlist restricts which source IP addresses can send inference requests to a gateway. Evaluated in the access phase, after authentication.

## Purpose and behavior

When `ip_allowlist` contains one or more entries, any request from a source IP that does not match at least one entry is rejected with `403 Forbidden`. An empty list (the default) allows all source IPs.

- CIDR notation is supported (e.g. `10.0.0.0/8`, `192.168.1.0/24`)
- A bare IP address without a prefix is treated as a `/32` (exact match)
- Both IPv4 addresses are supported
- The check is performed on the connecting client IP as seen by the gateway. If the gateway is deployed behind a load balancer, IP evaluation uses the original client IP from forwarding headers automatically.

## Config example

Set the allowlist via the gateway config:

```bash
curl -X PATCH https://your-gateway-host/admin/v1/gateways/{id} \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "ip_allowlist": [
        "10.0.0.0/8",
        "192.168.1.50",
        "172.16.0.0/12"
      ]
    }
  }'
```

To remove the allowlist and allow all IPs again, set it to an empty array:

```bash
curl -X PATCH https://your-gateway-host/admin/v1/gateways/{id} \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{"config": {"ip_allowlist": []}}'
```

## CIDR notation examples

| Entry | Matches |
|---|---|
| `203.0.113.42` | Exactly `203.0.113.42` |
| `203.0.113.0/24` | `203.0.113.0` – `203.0.113.255` |
| `10.0.0.0/8` | `10.0.0.0` – `10.255.255.255` |
| `172.16.0.0/12` | `172.16.0.0` – `172.31.255.255` |
| `192.168.0.0/16` | `192.168.0.0` – `192.168.255.255` |

## 403 response format

When a request is blocked by the IP allowlist:

```json
{
  "error": {
    "code": "FORBIDDEN",
    "message": "Access denied",
    "blocked_by": "ip_allowlist"
  }
}
```

The `blocked_by` field identifies the IP allowlist as the reason, which is useful for distinguishing this from authentication failures in client-side error handling.

!!! note
    The IP allowlist applies only to inference endpoints. Admin API requests are subject to separate access controls and are not filtered by the gateway's `ip_allowlist` config.

!!! warning
    If your gateway is behind a load balancer or reverse proxy, verify that the allowlist entries match your true client IP ranges. The gateway uses the original client IP from forwarding headers automatically, so proxy IPs are not evaluated.

## See also

- [Authentication & Tokens](authentication.md)
- [Gateway Configuration](../configuration/gateway-config.md)
- [Routing Rules](../routing/routing-rules.md)
