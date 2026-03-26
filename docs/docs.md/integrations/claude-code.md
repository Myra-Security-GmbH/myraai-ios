# Claude Code

Claude Code reads two environment variables to locate the Anthropic API.
Point them at your AI Gateway tenant and gateway to route all Claude Code
traffic through Myra's AI Gateway — giving you audit logs, cost tracking,
guardrails, and rate limiting without any changes to how you use Claude Code.

## Prerequisites

- A running AI Gateway instance
- A tenant and gateway configured with an Anthropic BYOK key
- A gateway auth token

## Configuration

Set the two variables before running `claude`:

```bash
export ANTHROPIC_BASE_URL="https://ai-api.myra.eu/v1/{tenant}/{gateway}/anthropic/chat/completions"
export ANTHROPIC_API_KEY="<your-gateway-token>"
claude
```

Replace `{tenant}` and `{gateway}` with your tenant and gateway slugs.
`ANTHROPIC_API_KEY` is the gateway token, not an Anthropic API key —
the gateway uses it for authentication and injects your stored Anthropic
key from its vault.

## Persistent setup

Add the exports to your shell profile so every Claude Code session is
routed automatically:

```bash
# ~/.bashrc or ~/.zshrc
export ANTHROPIC_BASE_URL="https://ai-api.myra.eu/v1/{tenant}/{gateway}/anthropic/chat/completions"
export ANTHROPIC_API_KEY="<your-gateway-token>"
```

Then reload your shell:

```bash
source ~/.bashrc   # or source ~/.zshrc
```

## What you get

Every Claude Code session is now visible in the gateway:

| Benefit | Where to see it |
|---|---|
| Request logs with prompt and response | Observability → Logs |
| Token counts and cost per session | Cost Analytics |
| Guardrail enforcement (PII, jailbreak, etc.) | Security → Guardrails |
| Rate limiting and budget caps | Configuration → Rate Limiting |
| Fallback to another provider on failure | Routing → Fallback |

## See also

- [Authentication](../security/authentication.md)
- [BYOK — provider key setup](../security/byok.md)
- [Providers — Anthropic](../providers/anthropic.md)
