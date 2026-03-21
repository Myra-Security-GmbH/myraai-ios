#!/bin/sh
# create_map.sh — generate docs/docs.md/reference/topic-map.md and wire it into mkdocs.yml

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MKDOCS="$SCRIPT_DIR/mkdocs.yml"
MAPFILE="$SCRIPT_DIR/docs.md/reference/topic-map.md"

# ── 1. Add md_in_html extension if missing ──────────────────────────────────
if ! grep -q 'md_in_html' "$MKDOCS"; then
  sed -i 's/^  - tables$/  - tables\n  - md_in_html/' "$MKDOCS"
  echo "Added md_in_html to mkdocs.yml"
fi

# ── 2. Add Topic Map to nav if missing ──────────────────────────────────────
if ! grep -q 'topic-map.md' "$MKDOCS"; then
  sed -i 's|    - reference/glossary.md|    - reference/glossary.md\n    - Topic Map: reference/topic-map.md|' "$MKDOCS"
  echo "Added Topic Map to mkdocs.yml nav"
fi

# ── 3. Write the topic-map.md page ──────────────────────────────────────────
cat > "$MAPFILE" << 'EOF'
# Topic Map

Browse all documentation topics by category.

<div class="grid cards" markdown>

-   **Getting Started**

    ---

    - [What is AI Gateway?](../getting-started/what-is-ai-gateway.md)
    - [Quick Start](../getting-started/quick-start.md)
    - [Getting Access](../getting-started/installation.md)

-   **Core Concepts**

    ---

    - [Request Pipeline](../concepts/request-pipeline.md)
    - [Multi-Tenancy](../concepts/multi-tenancy.md)
    - [Supported Providers](../concepts/providers.md)
    - [Response Caching](../concepts/caching.md)
    - [Cost Attribution](../concepts/cost-attribution.md)

-   **Configuration**

    ---

    - [Gateway Configuration](../configuration/gateway-config.md)
    - [Rate Limiting](../configuration/rate-limiting.md)
    - [Budget & Quota Enforcement](../configuration/budgets.md)

-   **Security**

    ---

    - [Authentication & Tokens](../security/authentication.md)
    - [Detector Pipeline](../security/detectors.md)
    - [Provider Key Management (BYOK)](../security/byok.md)
    - [IP Allowlist](../security/ip-allowlist.md)

-   **Routing**

    ---

    - [Routing Rules](../routing/routing-rules.md)
    - [OpenAI-Compatible Endpoint](../routing/compat-endpoint.md)
    - [Fallback & Retry](../routing/fallback.md)

-   **Providers**

    ---

    - [Providers Overview](../providers/overview.md)
    - [OpenAI](../providers/openai.md)
    - [Anthropic](../providers/anthropic.md)
    - [Google Gemini](../providers/gemini.md)
    - [Azure OpenAI](../providers/azure.md)
    - [AWS Bedrock](../providers/bedrock.md)
    - [Ollama](../providers/ollama.md)
    - [OpenAI-Compatible Providers](../providers/openai-compatible.md)

-   **Observability**

    ---

    - [Request Logging](../observability/logging.md)
    - [Prometheus Metrics](../observability/prometheus.md)
    - [Admin Dashboard](../observability/dashboard.md)

-   **Admin UI**

    ---

    - [Admin UI Overview](../admin-ui/overview.md)
    - [Playground](../admin-ui/playground.md)

-   **API Reference**

    ---

    - [Authentication](../api-reference/authentication.md)
    - [Tenants & Gateways](../api-reference/tenants-gateways.md)
    - [Users & Tokens](../api-reference/users-tokens.md)
    - [Routing Rules](../api-reference/routing-rules.md)
    - [Stats](../api-reference/stats.md)
    - [Logs](../api-reference/logs.md)
    - [Models & Pricing](../api-reference/models.md)
    - [Error Codes](../api-reference/error-codes.md)

</div>
EOF

echo "Written: $MAPFILE"

# ── 4. Rebuild ───────────────────────────────────────────────────────────────
cd "$SCRIPT_DIR"
./gen_docs.sh
