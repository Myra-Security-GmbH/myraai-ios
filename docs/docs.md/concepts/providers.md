# Supported Providers

AI Gateway supports 21 AI providers through a common internal interface. Each provider module implements five functions: `base_url`, `build_headers`, `build_request`, `parse_response`, and `parse_sse_chunk`.

---

## Provider table

| Provider | Wire format | Auth header | Notes |
|----------|------------|-------------|-------|
| OpenAI | Native OpenAI | `Authorization: Bearer` | Direct pass-through |
| Azure OpenAI | OpenAI | `api-key` | Requires `azure_endpoint`, `azure_deployment`, `azure_api_version` in gateway config |
| Anthropic | Messages API | `x-api-key` | System prompt extraction, extended thinking, prompt caching |
| Google Gemini | GenerateContent | `Authorization: Bearer` | System instruction conversion, safety settings |
| Vertex AI | GenerateContent | `x-goog-api-key` | Requires `vertex_project` and `vertex_region` in gateway config |
| AWS Bedrock | Bedrock Converse | SigV4 HMAC-SHA256 | BYOK key format: `ACCESS_KEY_ID:SECRET_ACCESS_KEY[:SESSION_TOKEN]`; `bedrock_region` in config |
| Mistral AI | OpenAI-compatible | `Authorization: Bearer` | |
| Groq | OpenAI-compatible | `Authorization: Bearer` | |
| Together AI | OpenAI-compatible | `Authorization: Bearer` | `meta-llama/`, `Qwen/`, `microsoft/` model prefixes |
| Fireworks AI | OpenAI-compatible | `Authorization: Bearer` | `accounts/fireworks/models/` model prefix |
| Cerebras | OpenAI-compatible | `Authorization: Bearer` | Fast inference hardware |
| DeepSeek | OpenAI-compatible | `Authorization: Bearer` | `deepseek-` model prefix |
| OpenRouter | OpenAI-compatible | `Authorization: Bearer` | Aggregates 300+ models; universal compat fallback |
| Perplexity | OpenAI-compatible | `Authorization: Bearer` | `sonar-` model prefix |
| SambaNova | OpenAI-compatible | `Authorization: Bearer` | |
| xAI | OpenAI-compatible | `Authorization: Bearer` | `grok-` model prefix |
| NVIDIA NIM | OpenAI-compatible | `Authorization: Bearer` | `nvidia/` model prefix |
| Cloudflare Workers AI | OpenAI-compatible | `Authorization: Bearer` | `@cf/` model prefix |
| Cohere | Cohere v2 Chat API | `Authorization: Bearer` | Native format; request and response translated to/from OpenAI shape |
| HuggingFace | Inference API (OpenAI-compat) | `Authorization: Bearer` | Org/model routing (see below) |
| Ollama | OpenAI-compatible | None | Local inference server; base URL from `provider_base_urls.ollama` |

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
