# Quick start

This guide takes you from first login to a working inference request in four steps.

Log in to the admin UI at `https://<your-gateway-host>/admin` using the credentials provided when your instance was provisioned.

---

## Creating a tenant and gateway

1. Click on **Tenants** in the left sidebar.
   ↳ The **Tenants** view opens.
2. Click on the **New Tenant** button.
   ↳ The **New Tenant** dialog opens.
3. Enter a slug in the **Slug** text field. For example: `myapp`.
4. To save the new tenant, click on the **Save** button.
   ↳ The new tenant appears in the tenant list.
5. Click on **Gateways** in the left sidebar.
   ↳ The **Gateways** view opens.
6. Click on the **New Gateway** button.
   ↳ The **New Gateway** dialog opens.
7. Select your new tenant from the **Tenant** drop-down list.
8. Enter a slug in the **Slug** text field. For example: `production`.
9. To save the new gateway, click on the **Save** button.
   ↳ The new gateway appears in the gateway list.

![Gateway list after selecting a tenant](../assets/screenshots/gateway-list.png)

!!! note "Authentication for this quick start"
    By default, gateways require an auth token on every inference request. To skip that for now, open the gateway's **Config** tab and set the **Auth Required** toggle to off. Re-enable it before going to production.

---

## Storing a provider key

1. Click on **Gateways** in the left sidebar.
   ↳ The **Gateways** view opens.
2. Click on the gateway you created.
   ↳ The gateway detail view opens.
3. Open the **Keys** tab.
   ↳ The provider keys list opens.
4. Click on the **Add Key** button.
   ↳ The **Add Key** dialog opens.
5. Select a provider from the **Provider** drop-down list. For example: `openai`.
6. Paste your API key into the **API Key** text field.
7. To save the key, click on the **Save** button.
   ↳ The new provider key appears in the keys list. The key is encrypted at rest immediately. The plaintext is never stored.

![Gateway detail — provider keys, auth tokens, and routing rules](../assets/screenshots/gateway-detail.png)

---

## Making your first request

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

## Checking the request log

1. Click on **Logs** in the left sidebar.
   ↳ The **Logs** view opens. Your request appears at the top of the list with provider, model, token count, cost, and latency.

---

## Next steps

- [Multi-Tenancy](../concepts/multi-tenancy.md) — understand the tenant/gateway/token hierarchy
- [Request Pipeline](../concepts/request-pipeline.md) — see exactly what happens to every request
- [Supported Providers](../concepts/providers.md) — swap OpenAI for any of the 21 supported providers
