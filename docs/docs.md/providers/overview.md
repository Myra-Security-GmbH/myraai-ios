# Providers Overview

The AI Gateway supports 21 inference providers. Each provider is accessible via its own native endpoint and via the unified OpenAI-compatible (`compat`) endpoint.

---

## Supported providers

| Provider | Wire Format | Auth | Notes |
|---|---|---|---|
| OpenAI | Native OpenAI | Bearer | Direct pass-through |
| Azure OpenAI | OpenAI | `api-key` header | Requires `azure_endpoint`, `azure_deployment`, `azure_api_version` in gateway config |
| Anthropic | Messages API | `x-api-key` | System prompt extraction, extended thinking, prompt caching |
| Google Gemini | GenerateContent | Bearer | System instruction conversion |
| Vertex AI | GenerateContent | Bearer + OAuth2 | Requires `vertex_project`, `vertex_region` in gateway config |
| AWS Bedrock | Bedrock Converse | SigV4 | HMAC-SHA256 signing; requires `bedrock_region` in gateway config |
| Mistral AI | OpenAI-compatible | Bearer | |
| Groq | OpenAI-compatible | Bearer | |
| Together AI | OpenAI-compatible | Bearer | `meta-llama/`, `Qwen/`, `microsoft/` model prefixes |
| Fireworks | OpenAI-compatible | Bearer | `accounts/fireworks/models/` model prefix |
| Cerebras | OpenAI-compatible | Bearer | Fast inference |
| DeepSeek | OpenAI-compatible | Bearer | `deepseek-` model prefix |
| OpenRouter | OpenAI-compatible | Bearer | 300+ models; acts as universal compat fallback |
| Perplexity | OpenAI-compatible | Bearer | `sonar-` model prefix |
| SambaNova | OpenAI-compatible | Bearer | |
| xAI | OpenAI-compatible | Bearer | `grok-` model prefix |
| NVIDIA NIM | OpenAI-compatible | Bearer | `nvidia/` model prefix |
| Cloudflare AI | OpenAI-compatible | Bearer | `@cf/` model prefix |
| Cohere | Cohere Chat API | Bearer | Native request/response translation |
| HuggingFace | OpenAI-compatible | Bearer | Org-prefix routing |
| Ollama | OpenAI-compatible | None | Local inference; configured via `provider_base_urls.ollama` |

---

## Endpoint patterns

### Native (provider-specific) endpoint

Each provider has a dedicated path that preserves the provider's exact wire format:

```
POST /v1/{tenant}/{gateway}/{provider}/chat/completions
```

Examples:

| Provider | Native endpoint |
|---|---|
| OpenAI | `POST /v1/{tenant}/{gateway}/openai/chat/completions` |
| Anthropic | `POST /v1/{tenant}/{gateway}/anthropic/chat/completions` |
| Google Gemini | `POST /v1/{tenant}/{gateway}/gemini/chat/completions` |
| AWS Bedrock | `POST /v1/{tenant}/{gateway}/bedrock/chat/completions` |
| Azure OpenAI | `POST /v1/{tenant}/{gateway}/azure/chat/completions` |
| Ollama | `POST /v1/{tenant}/{gateway}/ollama/chat/completions` |

All providers accept the OpenAI chat completions request body. The gateway translates to each provider's native wire format automatically.

### Compat (unified) endpoint

```
POST /v1/{tenant}/{gateway}/compat/chat/completions
```

The compat endpoint routes to the correct provider by inspecting the `model` field in the request body. It always returns an OpenAI-shaped response regardless of which provider handled the request.

```bash
curl -s -X POST "https://gateway.example.com/v1/myapp/prod/compat/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "claude-opus-4-6",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

---

## Compat model resolution

When a request arrives at the compat endpoint the gateway resolves the provider in three tiers:

| Tier | Mechanism | Example |
|---|---|---|
| 1 | Explicit `x-aig-provider` request header | `x-aig-provider: anthropic` |
| 2 | Model name prefix matching | `claude-` → Anthropic; `grok-` → xAI |
| 3 | OpenRouter fallback | Any unrecognized model name |

**Tier 2 prefix examples:**

| Model prefix | Resolved provider |
|---|---|
| `gpt-`, `o1-`, `o3-` | OpenAI |
| `claude-` | Anthropic |
| `gemini-` | Google Gemini |
| `mistral-`, `codestral-` | Mistral AI |
| `llama-`, `mixtral-`, `gemma-` (Groq) | Groq |
| `meta-llama/`, `Qwen/`, `microsoft/` | Together AI |
| `accounts/fireworks/models/` | Fireworks |
| `deepseek-` | DeepSeek |
| `sonar-` | Perplexity |
| `grok-` | xAI |
| `nvidia/` | NVIDIA NIM |
| `@cf/` | Cloudflare AI |
| `ollama/` | Ollama |
| `command-`, `embed-` | Cohere |

!!! note "OpenRouter as catch-all"
    If no prefix matches and no `x-aig-provider` header is set, the request is forwarded to OpenRouter, which itself supports 300+ models. This makes the compat endpoint a true universal adapter.

---

## Provider base URL override

Every provider has a hardcoded default base URL (e.g. `https://api.openai.com`). You can override this per-gateway using the `provider_base_urls` config field:

```bash
curl -X PATCH "https://gateway.example.com/admin/v1/gateways/{id}" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "provider_base_urls": {
        "ollama": "http://192.168.1.50:11434",
        "openai": "https://my-proxy.internal/openai"
      }
    }
  }'
```

This is useful for:

- Pointing Ollama at a remote host instead of `localhost`
- Routing through an internal OpenAI-compat proxy
- Testing against a staging endpoint

---

## Provider header pass-through

Any request header prefixed with `x-aig-provider-` is stripped of that prefix and forwarded verbatim to the upstream provider.

```
x-aig-provider-anthropic-beta: interleaved-thinking-2025-05-14
→ forwarded as →
anthropic-beta: interleaved-thinking-2025-05-14
```

This lets you pass provider-specific beta flags, versioning headers, or experimental features without waiting for gateway-level support.

!!! warning "Header forwarding is unconditional"
    All `x-aig-provider-*` headers are forwarded regardless of which provider handles the request. Sending an Anthropic-specific header to an OpenAI request is harmless but may produce unexpected upstream behaviour if the provider rejects unknown headers.

---

## See also

- [OpenAI](openai.md)
- [Anthropic](anthropic.md)
- [Google Gemini](gemini.md)
- [Azure OpenAI](azure.md)
- [AWS Bedrock](bedrock.md)
- [Ollama](ollama.md)
- [OpenAI-Compatible Providers](openai-compatible.md)
- [Gateway Configuration](../configuration/gateway-config.md)
