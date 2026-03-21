# Quick Start

This guide takes you from first login to a working inference request in four steps.

Log in to the admin UI at `https://<your-gateway-host>/admin` using the credentials provided when your instance was provisioned.

---

## Step 1 — Create a tenant and gateway

```bash
# Create a tenant
curl -s -X POST https://<your-gateway-host>/admin/v1/tenants \
  -H 'Content-Type: application/json' \
  -d '{"slug":"myapp","plan":"starter"}' | tee /tmp/tenant.json

TENANT_ID=$(jq -r '.id' /tmp/tenant.json)

# Create a gateway inside that tenant
curl -s -X POST "https://<your-gateway-host>/admin/v1/tenants/${TENANT_ID}/gateways" \
  -H 'Content-Type: application/json' \
  -d '{
    "slug": "production",
    "config": {
      "auth_required": false,
      "cache_ttl": 0,
      "retry_count": 2
    }
  }' | tee /tmp/gateway.json

GW_ID=$(jq -r '.id' /tmp/gateway.json)
```

!!! note "auth_required: false"
    Setting `auth_required: false` removes the need for an auth token on inference requests, which simplifies this quick start. For any real deployment you should leave it enabled and create auth tokens.

---

## Step 2 — Store a provider key

```bash
curl -s -X POST "https://<your-gateway-host>/admin/v1/gateways/${GW_ID}/keys" \
  -H 'Content-Type: application/json' \
  -d '{
    "provider": "openai",
    "alias": "default",
    "key": "sk-..."
  }'
```

The key is encrypted at rest. The plaintext is never persisted.

---

## Step 3 — Make your first request

### Provider-native endpoint

```bash
curl -s -X POST \
  "https://<your-gateway-host>/v1/myapp/production/openai/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gpt-4o",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### OpenAI-compatible unified endpoint

The compat endpoint infers the provider from the model name:

```bash
curl -s -X POST \
  "https://<your-gateway-host>/v1/myapp/production/compat/chat/completions" \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "gpt-4o",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

A successful response looks like:

```json
{
  "id": "chatcmpl-...",
  "object": "chat.completion",
  "model": "gpt-4o",
  "choices": [{"message": {"role": "assistant", "content": "Hello! How can I help?"}}],
  "usage": {"prompt_tokens": 10, "completion_tokens": 9, "total_tokens": 19}
}
```

---

## Step 4 — Check the request log

```bash
curl -s "https://<your-gateway-host>/admin/v1/logs?limit=1" | jq .
```

---

## Next steps

- [Multi-Tenancy](../concepts/multi-tenancy.md) — understand the tenant/gateway/token hierarchy
- [Request Pipeline](../concepts/request-pipeline.md) — see exactly what happens to every request
- [Supported Providers](../concepts/providers.md) — swap OpenAI for any of the 21 supported providers
