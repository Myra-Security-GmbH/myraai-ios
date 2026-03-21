# Provider Key Management (BYOK)

BYOK (Bring Your Own Key) lets you store your provider API keys encrypted inside the gateway rather than hardcoding them in config files or environment variables. The gateway encrypts each key at rest and decrypts it on demand when making upstream provider requests.

## Encryption details

Provider API keys are encrypted at rest using AES-256. The encryption key is managed by the Myra Security platform — you never handle it directly.

## Key identity

Each stored key is uniquely identified by the combination of:

- `gateway_id` — the gateway the key belongs to
- `provider` — the provider name (e.g. `openai`, `anthropic`, `bedrock`)
- `alias` — a label for the key (default: `"default"`)

Multiple keys for the same provider on the same gateway can coexist under different aliases. This lets you rotate keys without downtime or assign different keys to different request flows.

## Using the admin UI

### Add a key

1. Open **Gateways** and click the gateway you want to configure.
2. Open the **Keys** tab.
3. Click **Add Key**.
4. Select the provider, enter an alias (leave as `default` unless you need multiple keys for the same provider), and paste the API key.
5. Click **Save**. The key is encrypted immediately — the plaintext is not stored.

### Delete a key

On the **Keys** tab, find the key and click the delete icon. Deletion is immediate.

!!! warning
    Deleting the `default` key for a provider will cause all requests to that provider to fail until a new key is added.

## Using multiple keys per provider

Store additional keys under named aliases via the Keys tab (set the **Alias** field to something other than `default`, e.g. `backup`).

To use a non-default alias on a specific inference request, send the `x-aig-byok-alias` header:

```bash
curl https://your-gateway-host/v1/my-tenant/my-gateway/chat/completions \
  -H "x-aig-token: <inference-token>" \
  -H "x-aig-byok-alias: backup" \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-4o", "messages": [...]}'
```

!!! note
    If the specified alias does not exist for the provider, the gateway falls back to the `"default"` alias.

## Bedrock key format

For AWS Bedrock, enter credentials as a colon-delimited string in the **Key** field:

```
ACCESS_KEY_ID:SECRET_ACCESS_KEY
```

Or with a session token:

```
ACCESS_KEY_ID:SECRET_ACCESS_KEY:SESSION_TOKEN
```

## API

Key management is also available via the Admin API. See [Tenants & Gateways API](../api-reference/tenants-gateways.md) for endpoint reference and request/response examples.

## See also

- [Authentication & Tokens](authentication.md)
- [Gateway Configuration](../configuration/gateway-config.md)
- [Fallback & Retry](../routing/fallback.md)
- [Providers Overview](../providers/overview.md)
