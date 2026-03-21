# AWS Bedrock

The gateway translates OpenAI chat completions format to the AWS Bedrock Converse API and handles SigV4 request signing automatically. You do not need an AWS SDK or signing library in your application.

---

## How signing works

Every request forwarded to Bedrock is signed with AWS Signature Version 4 (HMAC-SHA256). The gateway:

1. Extracts your `ACCESS_KEY_ID` and `SECRET_ACCESS_KEY` from the stored BYOK value
2. Computes the `Authorization` header using the request body, timestamp, and target region
3. Forwards the signed request to the Bedrock Converse endpoint

This happens transparently — your application sends a normal OpenAI-format request.

---

## Gateway config

Set the AWS region in your gateway config:

```bash
curl -X PATCH "https://gateway.example.com/admin/v1/gateways/{id}" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "bedrock_region": "us-west-2"
    }
  }'
```

| Config field | Default | Description |
|---|---|---|
| `bedrock_region` | `"us-east-1"` | AWS region for Bedrock API calls |

---

## BYOK key format

The BYOK value must be your AWS credentials in one of these two formats:

```
ACCESS_KEY_ID:SECRET_ACCESS_KEY
```

or, if using temporary credentials with a session token:

```
ACCESS_KEY_ID:SECRET_ACCESS_KEY:SESSION_TOKEN
```

```bash
# Permanent credentials
curl -s -X POST "https://gateway.example.com/admin/v1/gateways/{gateway_id}/keys" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "bedrock",
    "alias": "default",
    "key": "AKIAIOSFODNN7EXAMPLE:wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  }'

# Temporary credentials (STS)
curl -s -X POST "https://gateway.example.com/admin/v1/gateways/{gateway_id}/keys" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "provider": "bedrock",
    "alias": "sts",
    "key": "ASIA...EXAMPLE:secret...key:FwoGZXIvYXdzE..."
  }'
```

!!! warning "Rotate credentials regularly"
    Bedrock credentials are stored encrypted but follow standard BYOK security practices. For production, prefer short-lived STS credentials or an IAM role if running on AWS infrastructure.

---

## IAM requirements

The IAM principal associated with the credentials needs the following permission:

```json
{
  "Effect": "Allow",
  "Action": "bedrock:InvokeModel",
  "Resource": "arn:aws:bedrock:{region}::foundation-model/*"
}
```

Restrict the `Resource` to specific model ARNs for tighter access control:

```json
"Resource": [
  "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-3-5-sonnet-20241022-v2:0",
  "arn:aws:bedrock:us-east-1::foundation-model/amazon.nova-pro-v1:0"
]
```

---

## Endpoint

### Native endpoint

```
POST /v1/{tenant}/{gateway}/bedrock/chat/completions
```

---

## Request example

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/bedrock/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "anthropic.claude-3-5-sonnet-20241022-v2:0",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user",   "content": "What is Amazon Bedrock?"}
    ],
    "max_tokens": 512,
    "temperature": 0.7
  }'
```

Pass the full Bedrock model ID (including provider prefix and version) in the `model` field. The gateway forwards this as the model identifier in the Converse API call.

### Streaming

```bash
curl -s -X POST \
  "https://gateway.example.com/v1/myapp/production/bedrock/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <token>" \
  -d '{
    "model": "amazon.nova-pro-v1:0",
    "messages": [{"role": "user", "content": "Tell me about AWS regions."}],
    "stream": true,
    "max_tokens": 256
  }'
```

---

## See also

- [Providers Overview](overview.md)
- [Gateway Configuration](../configuration/gateway-config.md) — `bedrock_region`
