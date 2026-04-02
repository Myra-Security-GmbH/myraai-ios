# Troubleshooting

This chapter describes errors that occur when using AI Gateway by Myra Security, including their causes and the steps to resolve them.

---

## Error: 429 RATE_LIMITED

**Description**

The gateway returns HTTP 429 with code `rate_limited` when the number of requests in the current sliding window exceeds the configured limit. The limit can be set at gateway level (applies to all traffic) or per authentication token (applies to a single caller). The gateway enforces rate limits before any upstream provider call is made. The response includes three headers: `X-RateLimit-Limit` (the configured limit), `X-RateLimit-Remaining` (always 0 when blocked), and `Retry-After` (the window duration in seconds).

**Resolution**

► Proceed as follows to resolve the error:

1. Read the `Retry-After` header in the HTTP 429 response.
   ⇒ The header contains the window duration in seconds. Waiting at least this long before retrying is sufficient.
2. Implement exponential backoff in the calling application before retrying.
   ⇒ The retry delay increases with each subsequent attempt, reducing burst pressure on the gateway.
3. Navigate to **Gateways** in the admin UI and open the affected gateway.
   ⇒ The gateway detail page opens.
4. Select the **Config** tab.
   ⇒ The configuration form opens.
5. Increase the value in the **Requests** text field or the **Window** text field to raise the gateway-level limit.
   ⇒ The updated rate limit applies to all subsequent requests.
6. To increase a per-token limit, navigate to **Users**, open the user record, and edit the rate limit fields of the token.
   ⇒ The updated limit applies to all subsequent requests authenticated with that token.

→ The gateway accepts requests again once the current window elapses or after the limit has been raised.

---

## Error: 429 QUOTA_EXCEEDED

**Description**

The gateway returns HTTP 429 with code `quota_exceeded` when the cumulative spend for an authentication token, a tenant, or a gateway has reached its configured budget. All three budget levels are evaluated independently on every request. The error message identifies exactly which budget scope was exhausted, states the configured budget and the current spend, and provides the API endpoint needed to increase the budget or reset the spend of the current period.

**Resolution**

► Proceed as follows to resolve the error:

1. Read the `message` field in the HTTP 429 response body to identify the affected scope (token, tenant, or gateway) and the API endpoint.
   ⇒ The message states the budget, the current spend, and two corrective actions.
2. Choose one of the following actions based on the scope:
   - To reset spend immediately: call `DELETE /admin/v1/gateways/{id}/budget`, `DELETE /admin/v1/tenants/{id}/budget`, or `DELETE /admin/v1/tokens/{id}/budget` as indicated in the message.
   - To increase the budget: call `PATCH` on the relevant resource with an updated `budget_usd` value.
3. Alternatively, navigate to the **Gateways** or **Users** section in the admin UI, open the affected record, and use the **Reset budget** button or update the **Budget (USD)** field.
   ⇒ The budget reset takes effect immediately.

→ The gateway accepts requests again once the budget has been increased or the spend counter has been reset.

---

## Error: 502 ALL_PROVIDERS_FAILED

**Description**

The gateway returns HTTP 502 with code `all_providers_failed` when every provider in the routing chain — the primary provider and all configured fallback providers — has returned errors or timed out. The primary provider is retried up to `retry_count` times on HTTP 5xx responses. Each fallback provider is attempted once in order. HTTP 4xx responses from a provider terminate the chain immediately without attempting further fallbacks.

**Resolution**

► Proceed as follows to resolve the error:

1. Check the request log in the admin UI (**Request Log** view) for the failed request to identify which providers were attempted and what status codes they returned.
   ⇒ The log entry shows the primary provider, fallback providers, and the HTTP status code received from each.
2. Check the operational status of the affected providers on their respective status pages.
   ⇒ Ongoing provider outages confirm that the error originates outside the gateway.
3. Navigate to **Gateways**, open the affected gateway, and verify that BYOK keys are stored for every provider in the fallback chain.
   ⇒ A missing key for a fallback provider causes a 4xx authentication failure, which halts the fallback chain.
4. Add additional fallback providers to the routing rule if the current chain does not provide sufficient redundancy.
   ⇒ Open the routing rule, add entries to the **Fallbacks** list, and save.
5. Enable the circuit breaker on the gateway to prevent retry cycles during sustained provider outages.
   ⇒ Set `circuit_breaker.enabled` to `true` in the gateway configuration.

→ The gateway returns a successful response once at least one provider in the chain is reachable and authenticated.

---

## Error: 400 GUARDRAIL_BLOCKED

**Description**

The gateway returns HTTP 400 with code `guardrail_blocked` when a guardrail in the pipeline matches the request or response content and its action is set to `block`. The error message identifies the guardrail name and the specific pattern or harm category that triggered the block. In streaming mode, the gateway returns HTTP 200 with a synthetic SSE stream containing the block message, because some streaming clients do not handle non-200 responses on streaming connections.

**Resolution**

► Proceed as follows to resolve the error:

1. Read the `message` field in the response body to identify which guardrail blocked the request and which pattern or category matched.
   ⇒ For streaming responses, inspect the content of the first SSE data chunk.
2. Review the content of the request or response that triggered the block.
   ⇒ Remove or rephrase the matched content and retry.
3. If the block is a false positive, navigate to the **Guardrail Builder** for the affected gateway and adjust the matching guardrail.
   - For a regex or keyword guardrail: update or remove the pattern that caused the false match.
   - For a Tier 2 guardrail (Presidio, Prompt Guard): consider changing the action from `block` to `flag` for entity types with a high false-positive rate.
4. Save the updated guardrail configuration.
   ⇒ The new configuration applies to all subsequent requests.

→ The gateway forwards the request to the provider once the content no longer matches any guardrail configured with a `block` action.

---

## Error: 401 UNAUTHORIZED

**Description**

The gateway returns HTTP 401 with code `unauthorized` when a request does not include a valid authentication token, when the token has expired, or when the token has been revoked. This applies to both inference endpoint requests and admin API requests.

**Resolution**

► Proceed as follows to resolve the error:

1. Verify that the request includes the `x-aig-token` header with a valid token value.
   ⇒ Check that no whitespace or truncation has been introduced when copying the token.
2. Navigate to **Users** → **My tokens** in the admin UI to confirm the token is active and has not been revoked.
   ⇒ Revoked tokens show a revoked status and cannot be reinstated.
3. If the token has been revoked or lost, create a new token in the **My tokens** view.
   - Click the **New Token** button, configure the required rate limit and budget fields, and save.
   ⇒ The new token value is displayed once on creation.
4. Update the calling application or integration with the new token value.
   ⇒ The token is passed in the `x-aig-token` header on every request.

→ The gateway accepts requests once a valid, active token is present in the request header.

---

## Error: 403 FORBIDDEN (IP allowlist)

**Description**

The gateway returns HTTP 403 with code `forbidden` when the source IP address of the request is not included in the configured IP allowlist of the gateway. This applies when an IP allowlist has been configured on the gateway; gateways without an IP allowlist accept requests from any source address. Only IPv4 CIDR ranges are supported in the allowlist; IPv6 addresses cannot be used.

**Resolution**

► Proceed as follows to resolve the error:

1. Confirm the source IP address of the request by checking the calling system or reading the IP from the gateway request log.
   ⇒ The log entry includes the client IP address.
2. Navigate to **Gateways** in the admin UI and open the affected gateway.
   ⇒ The gateway detail page opens.
3. Select the **Config** tab and locate the **IP allowlist** field.
   ⇒ The current list of allowed CIDR ranges is displayed.
4. Add the source IP address or CIDR range to the allowlist and save.
   ⇒ Use CIDR notation (for example, `203.0.113.10/32` for a single address).
5. If the calling system uses dynamic IP addresses, consider using a NAT gateway or proxy to provide a stable egress IP, then add that IP to the allowlist.

→ The gateway accepts requests from the source IP address once it is included in the allowlist.

---

## Error: Circuit breaker open

**Description**

When the circuit breaker is enabled on a gateway and a provider accumulates failures at or above the configured `failure_threshold` within the `window_sec` interval, the circuit breaker transitions to the open state for that provider. While open, the gateway skips that provider entirely and proceeds directly to the next entry in the fallback chain. If no fallback is available, the request fails with `502 all_providers_failed`. After the `cooldown_ms` period elapses, the circuit breaker transitions to the half-open state and allows one probe request through to test recovery.

**Resolution**

► Proceed as follows to resolve the error:

1. Check the circuit breaker status for the affected gateway by calling `GET /admin/v1/gateways/{id}/circuit-breaker` or by opening the gateway detail page in the admin UI.
   ⇒ The response lists each provider with its current state (`open`, `half-open`, or `closed`), the failure count, and the time the breaker opened.
2. Check the operational status of the affected provider on its status page.
   ⇒ If a provider outage is confirmed, wait for the provider to recover; the circuit breaker probes automatically after `cooldown_ms` elapses.
3. Verify that fallback providers are configured in the routing rule for the affected gateway.
   ⇒ Open the routing rule and confirm entries exist in the **Fallbacks** list, each with a valid BYOK key stored.
4. If the circuit breaker opened due to a configuration error (for example, an incorrect BYOK key), correct the key in the **BYOK key vault**, then wait for the cooldown period to expire.
   ⇒ The probe request after cooldown will succeed and transition the breaker back to closed.
5. To adjust sensitivity, update `failure_threshold`, `window_sec`, or `cooldown_ms` in the gateway configuration.
   ⇒ Raise `failure_threshold` or increase `window_sec` to reduce sensitivity to transient errors.

→ The gateway resumes routing to the provider once the probe request succeeds and the circuit breaker returns to the closed state.

---

## Error: Tier 2 guardrail sidecar unavailable

**Description**

Tier 2 guardrails (NLP PII Detector, Prompt Guard, PII Protector) make an HTTP call to a locally hosted sidecar service within Myra's certified infrastructure. If the sidecar service is unavailable — due to a deployment issue, resource exhaustion, or network isolation — the gateway cannot complete the Tier 2 guardrail check. The behaviour when this occurs is controlled by the `fail_open` setting on each Tier 2 guardrail. When `fail_open` is `true` (the default), the request passes through as if no match occurred. When `fail_open` is `false`, the request is blocked.

**Resolution**

► Proceed as follows to resolve the error:

1. Check the request log in the admin UI for affected requests and look for guardrail verdict fields (`blocked`, `blocked_by`, `detectors_fired` — the legacy log-field name for the guardrails that fired) to confirm which sidecar was unreachable.
   ⇒ Requests that passed through with `fail_open: true` will not have a block verdict; the absence of a Tier 2 verdict in the log indicates the sidecar was skipped.
2. Verify that the sidecar service is running and reachable within the infrastructure of Myra Security.
   ⇒ Contact Myra Security support if the sidecar deployment is managed by Myra.
3. If the sidecar is self-managed, check the deployment logs and resource allocation for the affected sidecar (Presidio, Prompt Guard, or PII Protector container).
   ⇒ Restart the sidecar service if it has crashed or become unresponsive.
4. Review the `fail_open` setting for the affected Tier 2 guardrail in the **Guardrail Builder**.
   ⇒ If the guardrail is a hard security dependency, set `fail_open` to `false` to block requests when the sidecar is unavailable rather than allowing uninspected traffic through.
5. Save the updated guardrail configuration.
   ⇒ The change applies to all subsequent requests.

→ The Tier 2 guardrail resumes normal operation once the sidecar service is reachable and responding to health checks.
