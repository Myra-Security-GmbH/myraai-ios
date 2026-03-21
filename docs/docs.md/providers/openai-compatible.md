# OpenAI-Compatible Providers

Thirteen providers expose an OpenAI-compatible API. They all share the same request format, Bearer token auth, and response structure. The only differences are the base URL, the expected model naming conventions, and provider-specific features.

---

## Provider list

| Provider | Model prefix / convention | Notes |
|---|---|---|
| Mistral AI | `mistral-`, `codestral-` | European models, code generation |
| Groq | `llama-3.3-70b-versatile`, `llama-3.1-8b-instant` etc. | High-speed inference on custom hardware |
| Together AI | `meta-llama/`, `Qwen/`, `microsoft/` prefixes | Large open-model catalogue |
| Fireworks | `accounts/fireworks/models/<name>` | Requires full `accounts/fireworks/models/` prefix |
| Cerebras | `llama3.1-8b`, `llama3.1-70b` etc. | Very fast inference |
| DeepSeek | `deepseek-chat`, `deepseek-reasoner` | Chinese frontier models |
| OpenRouter | Any model from any supported provider | 300+ models; universal compat fallback |
| Perplexity | `sonar-pro`, `sonar` etc. | Web-grounded generation |
| SambaNova | `Meta-Llama-3.1-405B-Instruct` etc. | Enterprise inference |
| xAI | `grok-3`, `grok-3-mini` etc. | Grok models |
| NVIDIA NIM | `nvidia/llama-3.1-nemotron-70b-instruct` etc. | `nvidia/` prefix |
| Cloudflare AI | `@cf/meta/llama-3.1-8b-instruct` etc. | `@cf/` prefix; edge inference |
| HuggingFace | Org-prefix routing (see below) | Various open models |

---

## BYOK setup

The process is identical for every provider in this group — only the `provider` field changes:

```bash
curl -s -X POST "https://gateway.example.com/admin/v1/gateways/{gateway_id}/keys" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "groq",
    "alias": "default",
    "key": "gsk_..."
  }'
```

Replace `"groq"` with any of: `mistral`, `together`, `fireworks`, `cerebras`, `deepseek`, `openrouter`, `perplexity`, `sambanova`, `xai`, `nvidia`, `cloudflare`, `huggingface`.

---

## Endpoints

### Native endpoints

```
POST /v1/{tenant}/{gateway}/mistral/chat/completions
POST /v1/{tenant}/{gateway}/groq/chat/completions
POST /v1/{tenant}/{gateway}/together/chat/completions
POST /v1/{tenant}/{gateway}/fireworks/chat/completions
POST /v1/{tenant}/{gateway}/cerebras/chat/completions
POST /v1/{tenant}/{gateway}/deepseek/chat/completions
POST /v1/{tenant}/{gateway}/openrouter/chat/completions
POST /v1/{tenant}/{gateway}/perplexity/chat/completions
POST /v1/{tenant}/{gateway}/sambanova/chat/completions
POST /v1/{tenant}/{gateway}/xai/chat/completions
POST /v1/{tenant}/{gateway}/nvidia/chat/completions
POST /v1/{tenant}/{gateway}/cloudflare/chat/completions
POST /v1/{tenant}/{gateway}/huggingface/chat/completions
```

### Compat endpoint

The compat endpoint resolves providers via model name prefix automatically. For providers where prefix matching is unambiguous you do not need to set `x-aig-provider`:

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/compat/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "deepseek-chat",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

---

## Request example (Groq)

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/groq/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "llama-3.3-70b-versatile",
    "messages": [
      {"role": "system", "content": "Be brief."},
      {"role": "user",   "content": "What is LoRA fine-tuning?"}
    ],
    "temperature": 0.5,
    "max_tokens": 256
  }'
```

---

## Request example (Together AI)

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/together/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "meta-llama/Llama-3.3-70B-Instruct-Turbo",
    "messages": [{"role": "user", "content": "Explain gradient descent."}],
    "max_tokens": 512
  }'
```

---

## Request example (Fireworks)

Fireworks requires the full model path:

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/fireworks/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "accounts/fireworks/models/llama-v3p3-70b-instruct",
    "messages": [{"role": "user", "content": "What is RAG?"}],
    "max_tokens": 256
  }'
```

---

## OpenRouter as universal fallback

OpenRouter aggregates 300+ models from many providers. When the compat endpoint cannot match a model name to any known provider prefix, it falls back to OpenRouter automatically.

```bash
# Unknown model → routed to OpenRouter
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/compat/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "cohere/command-r-plus-08-2024",
    "messages": [{"role": "user", "content": "Hello"}]
  }'
```

You can also force OpenRouter explicitly:

```bash
-H "x-aig-provider: openrouter"
```

!!! note "OpenRouter BYOK"
    You must have an OpenRouter BYOK key stored for the fallback to work. Without it, fallback requests will fail with an authentication error from OpenRouter.

---

## HuggingFace org prefix routing

The HuggingFace provider recognises the following organisation prefixes and routes to the correct inference endpoint:

| Org prefix | Example model |
|---|---|
| `HuggingFaceH4/` | `HuggingFaceH4/zephyr-7b-beta` |
| `tiiuae/` | `tiiuae/falcon-40b-instruct` |
| `bigcode/` | `bigcode/starcoder2-15b` |
| `EleutherAI/` | `EleutherAI/gpt-neox-20b` |
| `microsoft/` | `microsoft/Phi-3-mini-4k-instruct` |
| `google/` | `google/gemma-7b-it` |
| `stabilityai/` | `stabilityai/stablelm-2-12b-chat` |
| `mistralai/` | `mistralai/Mistral-7B-Instruct-v0.3` |

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/huggingface/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "HuggingFaceH4/zephyr-7b-beta",
    "messages": [{"role": "user", "content": "What is attention?"}],
    "max_tokens": 256
  }'
```

---

## See also

- [Providers Overview](overview.md)
- [OpenAI](openai.md)
- [Gateway Configuration](../configuration/gateway-config.md)
