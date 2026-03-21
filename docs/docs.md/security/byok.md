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

## Key caching

Decrypted keys are cached in the `aig_byok` shared memory dictionary for **60 seconds**. This avoids decrypting the key on every request without holding plaintext indefinitely. After 60 seconds, the next request re-decrypts from the database.

## API reference

### Store a key

```bash
curl -X POST https://your-gateway-host/admin/v1/gateways/{id}/keys \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "openai",
    "alias": "default",
    "key": "sk-proj-..."
  }'
```

### List keys for a gateway

Returns metadata only — the plaintext key and ciphertext are never returned.

```bash
curl https://your-gateway-host/admin/v1/gateways/{id}/keys \
  -H "x-aig-token: <admin-token>"
```

Response:

```json
[
  {
    "provider": "openai",
    "alias": "default",
    "created_at": "2026-03-21T10:00:00Z"
  },
  {
    "provider": "openai",
    "alias": "backup",
    "created_at": "2026-03-21T10:05:00Z"
  }
]
```

### Delete a key

```bash
curl -X DELETE \
  https://your-gateway-host/admin/v1/gateways/{id}/keys/{provider}/{alias} \
  -H "x-aig-token: <admin-token>"
```

Example — delete the default OpenAI key:

```bash
curl -X DELETE \
  https://your-gateway-host/admin/v1/gateways/gw_123/keys/openai/default \
  -H "x-aig-token: <admin-token>"
```

## Using multiple keys per provider

Store additional keys under named aliases:

```bash
# Store a backup key
curl -X POST https://your-gateway-host/admin/v1/gateways/{id}/keys \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "openai",
    "alias": "backup",
    "key": "sk-proj-backup..."
  }'
```

Select a non-default alias on a per-request basis using the `x-aig-byok-alias` header:

```bash
curl https://your-gateway-host/v1/my-tenant/my-gateway/chat/completions \
  -H "x-aig-token: <inference-token>" \
  -H "x-aig-byok-alias: backup" \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-4o", "messages": [...]}'
```

!!! note
    The `x-aig-byok-alias` header is evaluated at request time. If the specified alias does not exist for the provider, the gateway falls back to the `"default"` alias.

## Bedrock key format

For AWS Bedrock, store credentials as a colon-delimited string:

```
ACCESS_KEY_ID:SECRET_ACCESS_KEY
```

Or with a session token:

```
ACCESS_KEY_ID:SECRET_ACCESS_KEY:SESSION_TOKEN
```

Example:

```bash
curl -X POST https://your-gateway-host/admin/v1/gateways/{id}/keys \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "bedrock",
    "alias": "default",
    "key": "AKIAIOSFODNN7EXAMPLE:wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  }'
```

## See also

- [Authentication & Tokens](authentication.md)
- [Gateway Configuration](../configuration/gateway-config.md)
- [Fallback & Retry](../routing/fallback.md)
- [Providers Overview](../providers/overview.md)
