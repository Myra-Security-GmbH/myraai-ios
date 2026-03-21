# Provider API Keys

Supported providers and how to obtain credentials for each.

---

## Quick reference

| Provider | Key URL | Free tier | Card required |
|---|---|---|---|
| [OpenAI](#openai) | platform.openai.com/api-keys | Very limited (3 RPM, older models) | No to sign up; yes for real use |
| [Anthropic](#anthropic) | console.anthropic.com/settings/keys | ~$5 credits | Yes (upfront) |
| [Google Gemini](#google-gemini) | aistudio.google.com/apikey | 15 RPM, no card | No |
| [Mistral](#mistral) | console.mistral.ai/api-keys | All models, 2 RPM | No (phone verification) |
| [Groq](#groq) | console.groq.com/keys | Daily token quota | No |
| [Cohere](#cohere) | dashboard.cohere.com/api-keys | 1,000 calls/month | No |
| [DeepSeek](#deepseek) | platform.deepseek.com/api_keys | 5M free tokens | No |
| [xAI (Grok)](#xai-grok) | console.x.ai | $25 signup credits | No |
| [Cerebras](#cerebras) | cloud.cerebras.ai | 1M tokens/day | No |
| [SambaNova](#sambanova) | cloud.sambanova.ai/apis | $5 credits (30-day expiry) | No |
| [Fireworks AI](#fireworks-ai) | fireworks.ai/api-keys | $1 credits | No |
| [OpenRouter](#openrouter) | openrouter.ai/settings/keys | Free models available | No |
| [Together AI](#together-ai) | api.together.xyz/settings/api-keys | None | Yes |
| [Perplexity](#perplexity) | perplexity.ai/settings/api | None | Yes |
| [NVIDIA NIM](#nvidia-nim) | build.nvidia.com/settings/api-keys | Dev credits | No |
| [HuggingFace](#huggingface) | huggingface.co/settings/tokens | $0.10/month | No |
| [Cloudflare Workers AI](#cloudflare-workers-ai) | dash.cloudflare.com | 10K Neurons/day | No |
| [Azure OpenAI](#azure-openai) | Azure Portal → Keys and Endpoints | $200 trial (30 days) | Yes |
| [AWS Bedrock](#aws-bedrock) | AWS Console → Bedrock → API keys | $200 credits (6 months) | Yes |
| [Google Vertex AI](#google-vertex-ai) | GCP Console → APIs & Services → Credentials | 90-day trial | No (express mode) |
| [Ollama](#ollama) | — | Free (local) | No |

---

## OpenAI

**Provider name in gateway:** `openai`

Sign up at **platform.openai.com/signup**, then go to **platform.openai.com/api-keys** and click **Create new secret key**.

- Free tier is effectively unusable for real work (3 RPM, GPT-3.5 only). Access to GPT-4o and newer models requires a minimum $5 deposit.
- The key is shown only once — copy it immediately.
- GitHub Student Developer Pack includes $50–100 in credits.

---

## Anthropic

**Provider name in gateway:** `anthropic`

Sign up at **console.anthropic.com**, go to **Settings → API Keys**, and click **Create Key**.

- A payment method is required before you can generate a key (though you are not charged during the initial ~$5 free credit period).
- New accounts start on Tier 1 with low rate limits regardless of spend; limits increase with cumulative usage.

---

## Google Gemini

**Provider name in gateway:** `gemini`

Go to **aistudio.google.com/apikey** and click **Create API key in new project**. No billing info needed.

- Genuine free tier: 15 RPM on current Gemini models, no credit card.
- Prompts sent on the free tier may be used by Google to improve their models — check their terms if this matters for your use case.
- This is the Gemini Developer API (AI Studio). For enterprise use or non-Gemini models, see [Google Vertex AI](#google-vertex-ai) below.

---

## Mistral

**Provider name in gateway:** `mistral`

Sign up at **console.mistral.ai** with email + SMS verification, go to **API Keys**, and click **Create new key**.

- No credit card required. Phone (SMS) verification is mandatory.
- The Experiment (free) plan covers all Mistral models including Mistral Large, but is capped at 2 RPM.
- Requests on the free plan may be used to train Mistral's models.

---

## Groq

**Provider name in gateway:** `groq`

Sign up at **console.groq.com**, go to **API Keys**, and click **Create API Key**.

- No credit card required. Free tier gives a generous daily token quota across multiple open-weight models (Llama, Mixtral, Gemma).
- Groq serves open-weight models only (no GPT, Claude, or Gemini).
- Free tier rate limits reset daily per model.

---

## Cohere

**Provider name in gateway:** `cohere`

Sign up at **dashboard.cohere.com/register** — a Trial API key is created automatically. Find it under **API Keys**.

- No credit card required. Trial key allows 1,000 API calls/month.
- Trial keys are not permitted for production or commercial use. To get a Production key, complete Cohere's "Go to Production" workflow (requires billing setup).

---

## DeepSeek

**Provider name in gateway:** `deepseek`

Sign up at **platform.deepseek.com**, go to **API keys**, and click **Create new API key**.

- No credit card required. New accounts receive 5M free tokens on signup.
- The API is OpenAI-compatible (same request/response format).
- DeepSeek has had notable availability issues through early 2026. Check **status.deepseek.com** before depending on it.

---

## xAI (Grok)

**Provider name in gateway:** `xai`

Sign up at **accounts.x.ai**, then go to **console.x.ai** and create an API key under **API Keys**.

- $25 in free credits on signup, no credit card required.
- An additional $150/month is available by opting into xAI's data sharing program — your prompts and responses are shared with xAI for training. Do not opt in if you handle confidential data.

---

## Cerebras

**Provider name in gateway:** `cerebras`

Sign up at **cloud.cerebras.ai**, then go to **API Keys** in the dashboard.

- No credit card required. Free tier gives 1M tokens/day (resets daily), which is genuinely useful for development.
- Available models (Llama 4, Llama 3.1, Qwen3 variants) can change; preview models may be discontinued without notice.

---

## SambaNova

**Provider name in gateway:** `sambanova`

Sign up at **cloud.sambanova.ai**, go to **APIs**, and generate a key.

- No credit card required. $5 in free credits (~30M tokens on Llama 8B). Credits expire in 30 days.
- Up to 25 API keys per account.

---

## Fireworks AI

**Provider name in gateway:** `fireworks`

Sign up at **fireworks.ai**, go to **API Keys**, and click **Create API Key**.

- No credit card required. $1 in free credits on signup.
- Without a payment method, rate limits are capped at 10 RPM. Adding billing unlocks up to 6,000 RPM.

---

## OpenRouter

**Provider name in gateway:** `openrouter`

Sign up at **openrouter.ai**, go to **Settings → Keys**, and click **Create Key**.

- No credit card required for free models. Many permanently-free models are available (DeepSeek, Llama variants, etc.), limited to 50 free-model requests/day by default.
- Purchasing $10+ in credits raises the free-model limit to 1,000 requests/day.
- The key is shown only once at creation.
- OpenRouter also supports BYOK: configure your own provider keys and the first 1M requests/month are free (then 5% fee).

---

## Together AI

**Provider name in gateway:** `together`

Sign up at **api.together.xyz**, go to **Settings → API Keys**, and click **Create API Key**.

- Free tier was removed in July 2025. A minimum $5 purchase is required.

---

## Perplexity

**Provider name in gateway:** `perplexity`

Sign up at **perplexity.ai**, go to **Settings → API**, and click **Generate**.

- No free API tier. You must purchase credits before any API calls succeed.
- Perplexity Pro subscribers ($20/month) receive $5/month in API credits.

---

## NVIDIA NIM

**Provider name in gateway:** `nvidia`

Join the NVIDIA Developer Program (free) at **developer.nvidia.com**, then go to **build.nvidia.com/settings/api-keys** and click **Get API Key**.

- No credit card required for the developer tier. Free credits are granted for prototyping via NVIDIA-hosted endpoints.
- The hosted API at `integrate.api.nvidia.com/v1` is OpenAI-API-compatible.
- Production deployments require an NVIDIA AI Enterprise license. The free tier is prototyping-only.

---

## HuggingFace

**Provider name in gateway:** `huggingface`

Sign up at **huggingface.co/join**, go to **Settings → Access Tokens**, click **Create new token**, and select **Read** scope (or create a fine-grained token with "Make calls to Inference Providers" permission).

- No credit card required. Free accounts get $0.10/month in inference credits (routed through third-party providers).
- The Inference API now routes requests to providers like Together AI, Fireworks, and others. Model availability varies by provider.
- You can link your own provider API keys under **Settings → Inference Providers** to bypass HF billing entirely.
- Base URL for OpenAI-compatible calls: `https://router.huggingface.co/v1`

---

## Cloudflare Workers AI

**Provider name in gateway:** `cloudflare`

Sign up at **dash.cloudflare.com** (email only, no card), then go to **AI → Workers AI → Use REST API** and click **Create a Workers AI API Token**. Your **Account ID** is shown on the same page.

- Permanent free tier: 10,000 Neurons/day, no credit card.
- You need both the API token and your **Account ID** to make requests.
- API endpoint: `https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/run/{model}`

---

## Azure OpenAI

**Provider name in gateway:** `azure`

1. Create an Azure account at **azure.microsoft.com/free** (credit card required for verification).
2. In the Azure Portal, create an **Azure OpenAI** resource (search "Azure OpenAI" in the marketplace).
3. Open your resource → **Resource Management → Keys and Endpoint**. Copy **KEY 1** and the **Endpoint URL**.
4. Go to **Azure AI Foundry** (oai.azure.com) and **deploy a model** (e.g. `gpt-4o`). Note the deployment name.

In the gateway, configure:
- `api_key` — the KEY 1 value
- `base_url` — your endpoint URL (e.g. `https://my-resource.openai.azure.com/`)
- `model` — your deployment name (not the model name)

- New Azure accounts get $200 in credits valid for 30 days. Free Trial and Azure for Students subscriptions cannot access Azure OpenAI.
- You must deploy a model before you can call it — creating the resource alone is not enough.
- API versioning is required in every request (`?api-version=2024-02-01`). The gateway handles this automatically.

---

## AWS Bedrock

**Provider name in gateway:** `bedrock`

**Option A — Bedrock long-term API key (simplest for development):**
1. Sign in to the AWS Console and go to **console.aws.amazon.com/bedrock**.
2. In the left nav, click **API keys** → **Create API key**. Set an expiry (max 365 days).
3. Copy the key — it is shown only once. Set it as the `BEDROCK_API_KEY` environment variable (or `AWS_BEARER_TOKEN_BEDROCK`).

**Option B — IAM access key (recommended for production):**
1. In the IAM console, create a user or role with the `AmazonBedrockFullAccess` managed policy.
2. Generate an access key under **Security credentials**. Set `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `AWS_REGION`.

- New AWS accounts get $200 in credits (valid 6 months). A credit card is required to create an account.
- **Anthropic models require a First-Time Use form** — submit it once from the Bedrock console before calling Claude models.
- Not all models are available in all regions. `us-east-1` and `us-west-2` have the widest availability.
- After first enabling a model there can be a ~2 minute delay before calls succeed.

---

## Google Vertex AI

**Provider name in gateway:** `vertex`

**Option A — Express mode (no card, 90-day trial):**
1. Go to **console.cloud.google.com/expressmode** and sign in with a Google account.
2. An API key and project are created automatically. Find the key under **APIs & Services → Credentials**.

**Option B — Standard GCP (full access):**
1. Create a GCP project at **console.cloud.google.com** and enable the Vertex AI API.
2. Create a Service Account under **IAM & Admin → Service Accounts** with the `Vertex AI User` role.
3. Download the JSON key file and set `GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json`.
   Or for local dev: `gcloud auth application-default login`.

- Express mode is limited to Gemini models at 10 RPM with no SLA. For Claude on Vertex, Meta Llama, or other Model Garden models, you need the full setup and must accept each model's EULA in Model Garden before first use.
- For Gemini only, the simpler path is the [Gemini Developer API](#google-gemini) (no GCP project needed).

---

## Ollama

**Provider name in gateway:** `ollama`

Ollama runs models locally — no API key required.

1. Install Ollama: **ollama.ai** (macOS, Linux, Windows).
2. Pull a model: `ollama pull llama3.2`
3. Ollama listens on `http://localhost:11434` by default.

Configure the gateway with the Ollama base URL pointing to your Ollama instance. The gateway strips the `ollama/` namespace prefix automatically before forwarding.
