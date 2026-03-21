# Supported Providers

AI Gateway supports 21 AI providers through a unified OpenAI-compatible interface.

---

## Provider table

| Provider | Notes |
|----------|-------|
| OpenAI | Direct pass-through |
| Azure OpenAI | Requires `azure_endpoint`, `azure_deployment`, `azure_api_version` in gateway config |
| Anthropic | Extended thinking and prompt caching supported |
| Google Gemini | Native grounding available for web search |
| Vertex AI | Requires `vertex_project` and `vertex_region` in gateway config |
| AWS Bedrock | BYOK key format: `ACCESS_KEY_ID:SECRET_ACCESS_KEY[:SESSION_TOKEN]`; `bedrock_region` in config |
| Mistral AI | |
| Groq | |
| Together AI | `meta-llama/`, `Qwen/`, `microsoft/` model prefixes |
| Fireworks AI | `accounts/fireworks/models/` model prefix |
| Cerebras | Fast inference |
| DeepSeek | `deepseek-` model prefix |
| OpenRouter | Aggregates 300+ models; acts as universal compat fallback |
| Perplexity | `sonar-` model prefix |
| SambaNova | |
| xAI | `grok-` model prefix |
| NVIDIA NIM | `nvidia/` model prefix |
| Cloudflare Workers AI | `@cf/` model prefix |
| Cohere | Request and response translated to/from OpenAI shape |
| HuggingFace | Org-prefix routing (see below) |
| Ollama | Local inference; set base URL via `provider_base_urls.ollama` |

---

## Endpoint formats

### Provider-native

```
POST /v1/{tenant_slug}/{gateway_slug}/{provider}/chat/completions
```

The request body is forwarded to the provider in its native wire format. For OpenAI-compatible providers, the OpenAI request body is forwarded as-is. For Anthropic, Gemini, Bedrock, and Cohere, the gateway translates the OpenAI-shaped body.

### OpenAI-compatible unified endpoint

```
POST /v1/{tenant_slug}/{gateway_slug}/compat/chat/completions
```

The provider is inferred from the `model` field using a three-tier resolution process. Any OpenAI-compatible client works against this endpoint regardless of the underlying provider.

---

## Compat endpoint model resolution

For the complete and authoritative model-to-provider mapping, see [OpenAI-Compatible Endpoint](../routing/compat-endpoint.md).

---

## HuggingFace org-prefix routing

The HuggingFace provider routes to the Inference API endpoint for the specified `org/model` path. The following organization prefixes are recognized:

```
HuggingFaceH4/
tiiuae/
bigcode/
EleutherAI/
microsoft/
google/
stabilityai/
mistralai/
```

---

## Provider base URL overrides

The `provider_base_urls` gateway config field lets you override the default upstream URL for any provider. This is most commonly used to point Ollama at a specific local server, but works for any provider:

```json
{
  "provider_base_urls": {
    "ollama": "http://localhost:11434",
    "openai": "https://my-openai-proxy.internal/v1"
  }
}
```

!!! note "Ollama requires a base URL"
    Ollama has no default public endpoint. You must set `provider_base_urls.ollama` to your local Ollama server URL.

---

## Provider-specific request headers

Headers matching `x-aig-provider-*` are stripped of the `x-aig-provider-` prefix and forwarded as-is to the provider. This enables provider-specific features without gateway configuration changes:

```bash
# Enable Anthropic extended thinking
curl -X POST https://<your-gateway-host>/v1/myapp/prod/anthropic/chat/completions \
  -H 'x-aig-provider-anthropic-beta: interleaved-thinking-2025-05-14' \
  -d '{"model":"claude-sonnet-4-6","messages":[...]}'
```

---

## See also

- [Compat Endpoint](../routing/compat-endpoint.md) — detailed model resolution and streaming re-encoding
- [BYOK Key Vault](../security/byok.md) — storing and selecting provider keys
- [Cost Attribution](cost-attribution.md) — per-provider pricing
- [Routing Rules](../routing/routing-rules.md) — overriding the provider at request time
