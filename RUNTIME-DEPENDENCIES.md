# Runtime Dependencies

All services the gateway depends on at runtime, grouped by category.
"Required" means the gateway will not start or will fail core requests without it.
"Optional" means it is only needed if the corresponding feature is configured.

---

## 1. Core Infrastructure

### MySQL / MariaDB
- **Role:** Primary persistent storage (tenants, gateways, users, request logs, migrations)
- **URL:** `AIG_MYSQL_HOST:AIG_MYSQL_PORT` — default `172.17.0.1:3306`
- **Database:** `ai_gateway` (prod) / `ai_gateway_int` (int)
- **User:** `gateway` / `gateway_int`
- **Required:** Yes (production). SQLite is the fallback for `AIG_STORAGE=sqlite`.
- **Pool:** 200 connections, 10 s timeout

### Redis
- **Role:** Shared rate-limit counters, config cache, BYOK key cache, metrics
- **URL:** `REDIS_HOST:REDIS_PORT` — default `127.0.0.1:6379`; auth via `REDIS_AUTH`
- **Container:** `gora-redis`
- **Required:** Yes in production (rate limiting). Falls back to nginx shared dicts when unavailable.
- **Pool:** 100 connections, 10 s timeout

---

## 2. Self-Hosted Model Inference

### vLLM — qwen3-235b (default)
- **Role:** Default local LLM inference endpoint
- **URL:** `VLLM_BASE_URL` — default `http://127.0.0.1:8001`
- **Models:** `qwen3-235b` and any model not in the per-model override table
- **Required:** If any gateway uses the `vllm` provider

### vLLM — qwen3.6-35b-a3b
- **Role:** Faster/smaller vLLM instance with its own port
- **URL:** `http://172.28.0.1:8003` (hardcoded model-port override in `src/providers/vllm.lua`)
- **Required:** If any gateway uses model `qwen3.6-35b-a3b`
- **Status:** NOT RUNNING — container absent from `docker ps`

### Ollama
- **Role:** Self-hosted LLM inference (Ollama protocol)
- **URL:** `OLLAMA_BASE_URL` — default `http://10.232.10.252:11439` (prod) / `http://ollama:11434` (Docker)
- **Container:** `dev-ollama`
- **Required:** If any gateway uses the `ollama` provider

### MinerU
- **Role:** Document-to-markdown conversion (PDF/image pages → text for non-vision vLLM models)
- **URL:** `http://172.28.0.1:8084/v1/chat/completions` (hardcoded in `src/admin/projects.lua`, `src/admin/chat.lua`)
- **Model name:** `mineru2`
- **Required:** If file uploads containing PDFs or images are sent to a vLLM gateway that is not vision-capable
- **Status:** NOT RUNNING — container absent from `docker ps`

---

## 3. Guardrails Sidecars

### Presidio Analyzer
- **Role:** PII entity detection (PERSON, EMAIL, PHONE, CREDIT_CARD, …)
- **URL:** `PRESIDIO_ANALYZER_URL` — default `http://127.0.0.1:5002/analyze`
- **Container:** `aig-presidio-analyzer`
- **Required:** If any guardrail rule uses `presidio` or `pii_protector`

### Presidio Anonymizer
- **Role:** PII scrubbing — replaces detected entities in prompts/responses
- **URL:** `PRESIDIO_ANONYMIZER_URL` — default `http://127.0.0.1:5001/anonymize`
- **Container:** `aig-presidio-anonymizer`
- **Required:** If any guardrail rule uses action `scrub`

### Prompt Guard (Llama Guard 3)
- **Role:** Content-safety classification of requests and responses
- **URL:** `PROMPT_GUARD_URL` — default `http://127.0.0.1:8083/v1/chat/completions`
- **Required:** If any guardrail rule uses `prompt_guard` (tier-2 guardrail)

---

## 4. Push Notification Microservices

### APNs microservice
- **Role:** iOS push notifications (project invitations, new messages)
- **URL:** `http://172.17.0.1:8010/send` (hardcoded in `src/push.lua`)
- **Required:** If iOS clients are registered for push

### FCM microservice
- **Role:** Android push notifications
- **URL:** `http://172.17.0.1:8011/send` (hardcoded in `src/push.lua`)
- **Required:** If Android clients are registered for push

---

## 5. Email

### SMTP relay
- **Role:** Delivers OTP login codes to users
- **Address:** `AIG_SMTP_HOST:AIG_SMTP_PORT` — always port 25
- **Required:** If email-based login is enabled (`AIG_OTP_FROM_EMAIL` set)

---

## 6. External Cloud Provider APIs

Needed only when a gateway is configured to route to that provider.
All require a BYOK API key stored in the database.

| Provider | Base URL |
|---|---|
| Anthropic | `https://api.anthropic.com` |
| OpenAI | `https://api.openai.com` |
| Azure OpenAI | `https://{resource}.openai.azure.com/openai/deployments/{deployment}/…` |
| Groq | `https://api.groq.com/openai` |
| Mistral | `https://api.mistral.ai` |
| DeepSeek | `https://api.deepseek.com` |
| Cerebras | `https://api.cerebras.ai` |
| Together | `https://api.together.xyz` |
| Fireworks | `https://api.fireworks.ai/inference` |
| OpenRouter | `https://openrouter.ai/api` |
| xAI | `https://api.x.ai` |
| Perplexity | `https://api.perplexity.ai` |
| HuggingFace | `https://api-inference.huggingface.co` |
| Cohere | `https://api.cohere.com` |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta` |
| Google Vertex AI | `https://{region}-aiplatform.googleapis.com/v1/projects/{project}` |
| AWS Bedrock | `https://bedrock-runtime.{region}.amazonaws.com` |
| NVIDIA NIM | `https://integrate.api.nvidia.com` |
| SambaNova | `https://api.sambanova.ai` |
| Cloudflare AI | `https://api.cloudflare.com/client/v4/accounts/{account_id}/ai` |

---

## 7. Optional Feature Services

### Brave Search API
- **Role:** Server-side web search in the agentic tool-use loop
- **URL:** `https://api.search.brave.com/res/v1/web/search`
- **Required:** If `gateway_config.web_search` is configured

### Google OAuth 2.0
- **Role:** "Sign in with Google" for the admin panel
- **URLs:** `https://accounts.google.com`, `https://oauth2.googleapis.com`
- **Required:** If `AIG_GOOGLE_CLIENT_ID` / `AIG_GOOGLE_CLIENT_SECRET` are set

### OpenTelemetry Collector
- **Role:** Distributed trace export (OTLP/HTTP)
- **URL:** `gateway_config.tracing.otlp_endpoint` (e.g. `http://otel-collector:4318`)
- **Required:** If tracing is configured

### SIEM (one of the following)
- **Splunk HEC** — `gateway_config.siem.url` (type `splunk_hec`)
- **Elasticsearch** — `gateway_config.siem.url` (type `elasticsearch`)
- **Vector** — `gateway_config.siem.url` (type `vector`)
- **Syslog** — `gateway_config.siem.host:port`, UDP or TCP (type `syslog`)

### MCP Connectors
- **Role:** User-configured external tool servers (JSON-RPC 2.0)
- **URL:** Per-connector `server_url` stored in the database
- **Required:** If any project has MCP connectors attached

---

## 8. Status at Time of Writing (2026-04-28)

```
RUNNING
  ai-gateway-gateway-1       (healthy)  production gateway
  ai-gateway-int-gateway-1   (healthy)  integration gateway
  aig-presidio-anonymizer    (healthy)  127.0.0.1:5001
  aig-presidio-analyzer                 127.0.0.1:5002
  gora-redis                            0.0.0.0:6379
  gora-neo4j                            0.0.0.0:7474, :7687
  rabbitmq                              172.17.0.1:5672
  stunnel                               :9200 (Elasticsearch TLS proxy)
  dev-ollama                            10.232.10.252:11439
  ollama-web-tools           (healthy)  10.232.10.252:28080
  buzybot_webapp                        10.232.10.252:8100

NOT RUNNING (features degraded)
  vLLM qwen3.6-35b-a3b                  172.28.0.1:8003   → model qwen3.6-35b-a3b unavailable
  MinerU                                172.28.0.1:8084   → PDF/image uploads to vLLM gateways will fail
```

Note: `gora-neo4j`, `rabbitmq`, `stunnel`, and `buzybot_webapp` are not referenced in the
gateway source — they are co-located infrastructure. `stunnel` proxies Elasticsearch on port 9200
but SIEM is configured at the gateway level, not required for core operation.
