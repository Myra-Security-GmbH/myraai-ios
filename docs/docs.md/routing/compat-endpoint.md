---
title: OpenAI-compatible endpoint
description: How the compat endpoint works, model resolution tiers, streaming normalisation, and SDK usage examples.
---

# OpenAI-compatible endpoint

The compat endpoint accepts any model name and automatically resolves which provider to route to. It is designed as a drop-in replacement for the OpenAI API — any client built against the OpenAI SDK works without modification by changing only the `base_url` and `api_key`.

Use the compat endpoint when you want to:

- **Switch providers without changing code** — point your existing OpenAI SDK client at the gateway and change only the `base_url` and `api_key`. Route to Claude, Gemini, or any other provider by changing the model name.
- **Access multiple providers from one endpoint** — your code always calls the same URL; the gateway determines which provider to use.
- **Use OpenRouter as a fallback** — any model identifier that OpenRouter supports will work automatically, even if it is not listed in the gateway's built-in model registry.

Use the provider-native endpoint instead if you need provider-specific features (such as Anthropic's extended thinking or AWS Bedrock's inference profiles) that are not available through the OpenAI-compatible format.

This page is the single authoritative reference for compat model resolution. The [Providers overview](../providers/overview.md) page cross-references this page for resolution details.

## Endpoint URL

```
POST /v1/{tenant}/{gateway}/compat/chat/completions
```

| Segment | Description |
|---|---|
| `{tenant}` | Your tenant identifier |
| `{gateway}` | Your gateway identifier |

The request and response formats are identical to the OpenAI Chat Completions API.

## Model resolution

The compat endpoint resolves a provider for each request using a three-tier lookup.

**Tier 1 — Exact match**

The model name is compared against a known model registry. Key examples (not exhaustive):

| Model | Provider |
|---|---|
| `gpt-4o` | `openai` |
| `gpt-4o-mini` | `openai` |
| `gpt-4-turbo` | `openai` |
| `gpt-3.5-turbo` | `openai` |
| `o1` | `openai` |
| `o1-mini` | `openai` |
| `o3-mini` | `openai` |
| `claude-opus-4-6` | `anthropic` |
| `claude-sonnet-4-6` | `anthropic` |
| `claude-haiku-4-5` | `anthropic` |
| `claude-3-5-sonnet-20241022` | `anthropic` |
| `claude-3-5-haiku-20241022` | `anthropic` |
| `claude-3-opus-20240229` | `anthropic` |
| `gemini-2.0-flash` | `gemini` |
| `gemini-2.0-flash-lite` | `gemini` |
| `gemini-1.5-pro` | `gemini` |
| `gemini-1.5-flash` | `gemini` |
| `llama-3.3-70b-versatile` | `groq` |
| `llama-3.1-8b-instant` | `groq` |
| `mixtral-8x7b-32768` | `groq` |
| `deepseek-chat` | `deepseek` |
| `deepseek-reasoner` | `deepseek` |
| `grok-3` | `xai` |
| `grok-3-mini` | `xai` |
| `grok-2-1212` | `xai` |
| `sonar-pro` | `perplexity` |
| `sonar` | `perplexity` |
| `sonar-reasoning-pro` | `perplexity` |

**Tier 2 — Prefix match**

If no exact match is found, the model name prefix is matched:

| Prefix | Provider |
|---|---|
| `gpt` | `openai` |
| `o1` | `openai` |
| `o3` | `openai` |
| `o4` | `openai` |
| `claude` | `anthropic` |
| `gemini` | `gemini` |
| `command`, `embed-` | `cohere` |
| `anthropic.`, `meta.`, `amazon.`, `mistral.`, `cohere.`, `ai21.`, `stability.` | `bedrock` |
| `mistral`, `mixtral`, `codestral` | `mistral` |
| `deepseek` | `deepseek` |
| `grok` | `xai` |
| `sonar` | `perplexity` |
| `meta-llama/`, `deepseek-ai/`, `Qwen/` | `together` |
| `accounts/fireworks/` | `fireworks` |
| `meta/`, `nvidia/` | `nvidia` |
| `ollama/` | `ollama` |
| `@cf/` | `cloudflare` |
| `HuggingFaceH4/`, `tiiuae/`, `bigcode/`, `EleutherAI/`, `microsoft/`, `google/`, `stabilityai/`, `mistralai/`, `sentence-transformers/` | `huggingface` |

**Tier 3 — OpenRouter fallback**

If neither an exact nor a prefix match is found, the request is forwarded to OpenRouter, which supports hundreds of models from many providers under a single API. Any model identifier that OpenRouter accepts will work through the compat endpoint without any gateway configuration.

!!! note
    OpenRouter fallback requires a valid OpenRouter API key stored as a BYOK key for the `openrouter` provider on your gateway.

## Routing rules and compat resolution

Routing rules apply on top of compat resolution. If a routing rule matches the incoming request before provider resolution runs, the rule's configured provider and model are used instead.

## Streaming normalisation

All providers use different server-sent event (SSE) formats for streaming responses. The compat endpoint normalises all provider streams into the OpenAI chunk format:

```
data: {"id":"chatcmpl-...","object":"chat.completion.chunk","choices":[{"delta":{"content":"Hello"}}]}

data: {"id":"chatcmpl-...","object":"chat.completion.chunk","choices":[{"delta":{"content":" world"}}]}

data: {"id":"...","object":"chat.completion.chunk","usage":{...},"choices":[{"finish_reason":"stop"}]}

data: [DONE]
```

A usage chunk is always emitted immediately before `data: [DONE]`, even if the upstream provider does not include usage in its stream. This ensures usage-based billing and token tracking work consistently regardless of provider.

## Using the compat endpoint

The following examples show how to call the compat endpoint from common clients.

**Python (`openai` library):**

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://your-gateway-host/v1/my-tenant/my-gateway/compat",
    api_key="myra_your_inference_token"
)

response = client.chat.completions.create(
    model="claude-sonnet-4-6",   # any model — provider resolved automatically
    messages=[{"role": "user", "content": "Hello"}]
)
```

**Node.js (`openai` library):**

```javascript
import OpenAI from 'openai';

const client = new OpenAI({
  baseURL: 'https://your-gateway-host/v1/my-tenant/my-gateway/compat',
  apiKey: 'myra_your_inference_token',
});

const response = await client.chat.completions.create({
  model: 'gemini-2.0-flash',
  messages: [{ role: 'user', content: 'Hello' }],
});
```

**curl:**

```bash
curl https://your-gateway-host/v1/my-tenant/my-gateway/compat/chat/completions \
  -H "Authorization: Bearer myra_your_inference_token" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "claude-sonnet-4-6",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": true
  }'
```

## See also

- [Routing rules](routing-rules.md)
- [Fallback and retry](fallback.md)
- [Provider key management (BYOK)](../security/byok.md)
- [Providers overview](../providers/overview.md)
