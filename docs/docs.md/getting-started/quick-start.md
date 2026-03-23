# Quick Start

This guide takes you from first login to a working inference request in four steps.

Log in to the admin UI at `https://<your-gateway-host>/admin` using the credentials provided when your instance was provisioned.

---

## Step 1 — Create a tenant and gateway

1. In the left sidebar, click **Tenants**.
2. Click **New Tenant**, enter a slug (e.g. `myapp`), and save.
3. Click **Gateways** in the sidebar, then **New Gateway**.
4. Select your new tenant, enter a slug (e.g. `production`), and save.

![Gateway list after selecting a tenant](../assets/screenshots/gateway-list.png)

!!! note "Auth for this quick start"
    By default, gateways require an auth token on every inference request. To skip that for now, open the gateway's **Config** tab and set **Auth Required** to off. Re-enable it before going to production.

---

## Step 2 — Store a provider key

1. In **Gateways**, click your new gateway.
2. Open the **Keys** tab.
3. Click **Add Key**, select a provider (e.g. `openai`), paste your API key, and save.

![Gateway detail — provider keys, auth tokens, and routing rules](../assets/screenshots/gateway-detail.png)

The key is encrypted at rest immediately. The plaintext is never stored.

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

In the left sidebar, click **Logs**. Your request appears at the top of the list with provider, model, token count, cost, and latency.

---

## Next steps

- [Multi-Tenancy](../concepts/multi-tenancy.md) — understand the tenant/gateway/token hierarchy
- [Request Pipeline](../concepts/request-pipeline.md) — see exactly what happens to every request
- [Supported Providers](../concepts/providers.md) — swap OpenAI for any of the 21 supported providers
