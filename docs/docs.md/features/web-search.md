---
title: Web search
description: How AI Gateway by Myra Security augments model requests with live web search results, including configuration, modes, and supported providers.
---

# Web search

AI Gateway by Myra Security augments model requests with live web search results. When web search is active, the gateway intercepts the outbound request, retrieves relevant search results, and injects them into the conversation context before forwarding to the model. No changes to client code are required beyond an optional request header.

## How it works

### Two-leg agentic flow (most providers)

For the majority of supported providers, web search uses a two-leg agentic loop:

1. **Leg 1 (buffered):** The gateway injects a `web_search` tool into the request and makes a non-streaming, buffered call to the provider.
2. **Tool decision:** If the model answers directly without calling the tool, the Leg 1 response is returned to the client as-is. No search is performed.
3. **Search:** If the model calls the `web_search` tool, the gateway runs parallel Brave Search queries.
4. **URL fetch:** The gateway fetches up to two of the top result URLs in parallel and appends the page content to the search results.
5. **SSE status event:** For streaming requests, an `aig_status` event is emitted before the URL fetch so the client can display a loading indicator. See [SSE status event](#sse-status-event).
6. **Leg 2 (streaming):** The enriched results are injected into the conversation as tool results, and the final request is forwarded to the provider. Streaming is used if the original request requested it.

### Google Gemini — native grounding

For Google Gemini, web search uses Gemini's built-in `googleSearch` grounding feature. No Brave Search API call is made, and the `api_key` in the gateway config is not used for Gemini requests. The gateway automatically converts the web search instruction to the Gemini grounding format. This is a single-leg request with no tool injection.

## Supported providers

**Two-leg agentic loop (tool injection):**

- Anthropic (native endpoint only)
- OpenAI
- Groq
- Mistral
- DeepSeek
- Cerebras
- Together AI
- Fireworks
- OpenRouter
- xAI
- Ollama
- HuggingFace
- SambaNova
- NVIDIA
- Azure OpenAI
- Cloudflare AI
- Cohere

**Native grounding (single leg, no tool injection):**

- Google Gemini

## Configuration

Web search is configured at the gateway level under `config.web_search`.

```json
{
  "config": {
    "web_search": {
      "enabled": true,
      "api_key": "BSA...",
      "max_results": 5,
      "mode": "opt-in"
    }
  }
}
```

| **Field** | **Type** | **Default** | **Description** |
|-----------|----------|-------------|-----------------|
| `enabled` | boolean | `false` | Enables web search on this gateway. |
| `api_key` | string | — | Brave Search API key. Required for all providers except Google Gemini. |
| `max_results` | integer | `5` | Maximum number of search results to retrieve per query. |
| `mode` | string | `"opt-in"` | Controls when web search is triggered. See [Modes](#modes). |

### Modes

| **Mode** | **Behaviour** |
|----------|--------------|
| `"opt-in"` | Web search triggers only when the client includes the `X-Web-Search: 1` request header. |
| `"always"` | Web search is attempted on every request through this gateway, regardless of client headers. |

## Getting a Brave Search API key

Obtain a Brave Search API key from the [Brave Search API developer portal](https://brave.com/search/api/). The Free tier provides 2,000 queries per month; paid plans offer higher limits.

!!! note "Gemini native grounding"
    For Google Gemini, web search uses Gemini's built-in `googleSearch` grounding feature rather than Brave Search. The `api_key` in the gateway config is not used for Gemini requests. The gateway automatically converts the `web_search` tool to the Gemini grounding format.

## Request and response headers

**Client opt-in header** (required when `mode` is `"opt-in"`):

```
X-Web-Search: 1
```

**Response header** (always set when a search is performed):

```
X-Web-Search-Query: <search query used>
```

## SSE status event

For streaming requests, the gateway emits an `aig_status` server-sent event (SSE) before fetching URL content. Clients use this to display a loading indicator.

```
data: {"aig_status": "fetching", "count": 2}
```

The `count` field indicates the number of URLs being fetched.

## Enabling web search on a gateway

Proceed as follows to enable web search on a gateway:

1. Send a `PATCH` request to `/admin/v1/gateways/{id}` with the `web_search` configuration block.

   ```bash
   curl -X PATCH "https://<your-gateway-host>/admin/v1/gateways/{id}" \
     -H "x-aig-token: <admin-token>" \
     -H "Content-Type: application/json" \
     -d '{
       "config": {
         "web_search": {
           "enabled": true,
           "api_key": "BSA_your_brave_key",
           "max_results": 5,
           "mode": "opt-in"
         }
       }
     }'
   ```

   - The gateway configuration is updated immediately.

-> Web search is active for all subsequent requests through this gateway.

### Making a search-augmented request in opt-in mode

Proceed as follows to send a search-augmented request when `mode` is `"opt-in"`:

1. Include the `X-Web-Search: 1` header in the client request.

   ```bash
   curl -X POST "https://<your-gateway-host>/v1/myapp/prod/openai/chat/completions" \
     -H "x-aig-token: <token>" \
     -H "X-Web-Search: 1" \
     -H "Content-Type: application/json" \
     -d '{
       "model": "gpt-4o",
       "messages": [{"role": "user", "content": "What is the latest news about AI?"}],
       "stream": true
     }'
   ```

   - The gateway runs the two-leg agentic flow and injects search results before the final model call.

-> The model response includes context from live web search results.

!!! warning "Model compatibility"
    Not all models support tool use. Web search requires the model to support tool/function calling. If the model does not call the tool, the Leg 1 response is returned directly and no search is performed.

!!! note "Anthropic compat endpoint"
    Web search is not supported when using the OpenAI-compatible endpoint with Anthropic as the provider. Use the native Anthropic endpoint instead.

## See also

- [Gateway configuration](../configuration/gateway-config.md)
- [Providers overview](../providers/overview.md)
