---
title: AWS Bedrock
description: How AI Gateway connects to AWS Bedrock using SigV4 signing, including key format, IAM requirements, and request examples.
---

# AWS Bedrock

AI Gateway by Myra Security translates the OpenAI chat completions format to the AWS Bedrock Converse API and handles AWS Signature Version 4 (SigV4) request signing automatically. Your application does not need an AWS SDK or signing library.

## How signing works

Every request forwarded to Bedrock is signed with HMAC-SHA256. The gateway:

1. Extracts your `ACCESS_KEY_ID` and `SECRET_ACCESS_KEY` from the stored BYOK value.
2. Computes the `Authorization` header using the request body, timestamp, and target region.
3. Forwards the signed request to the Bedrock Converse endpoint.

This happens transparently — your application sends a normal OpenAI-format request.

## Gateway configuration

Set the AWS region in your gateway config:

| Config field | Default | Description |
|---|---|---|
| `bedrock_region` | `"us-east-1"` | AWS region for Bedrock API calls |

## BYOK key format

The BYOK value must be your AWS credentials in one of the following two formats.

For permanent credentials:

```
ACCESS_KEY_ID:SECRET_ACCESS_KEY
```

For temporary credentials (AWS Security Token Service):

```
ACCESS_KEY_ID:SECRET_ACCESS_KEY:SESSION_TOKEN
```

## Adding AWS Bedrock credentials

Before you begin, ensure the following conditions are met:
- ☑ You have an AWS IAM user or role with the `bedrock:InvokeModel` permission.
- ☑ You have the `ACCESS_KEY_ID` and `SECRET_ACCESS_KEY` for the IAM principal.
- ☑ The gateway exists and is accessible.

![Screenshot: BYOK key management page with Add Key form](../assets/screenshots/byok-add-key.png)
*The key management page for a gateway.*

► Proceed as follows to add AWS Bedrock credentials:

1. Open **Gateways** in the left sidebar.
   ⇒ The gateway list opens.
2. Click on the gateway you want to configure.
   ⇒ The gateway detail page opens.
3. Click on the **Configuration** tab.
   ⇒ The configuration form opens.
4. Enter the AWS region in the **Bedrock region** text field (for example, `us-west-2`).
   ⇒ The region is set.
5. Click on the **Save** button.
   ⇒ The region configuration is saved.
6. Click on the **Keys** tab.
   ⇒ The key management page opens.
7. Click on the **Add Key** button.
   ⇒ The key form opens.
8. Select `bedrock` from the **Provider** drop-down list.
   ⇒ The provider is set.
9. Enter `default` in the **Alias** text field (or a custom alias for multiple credential sets).
   ⇒ The alias is set.
10. Enter your AWS credentials in the **Key** text field using the format `ACCESS_KEY_ID:SECRET_ACCESS_KEY`.
    ⇒ The key value is set.
11. Click on the **Save** button.

→ The credentials are encrypted and stored. The gateway uses them to sign all Bedrock requests on this gateway.

To configure the region and add credentials via the API:

```bash
# Set the region
curl -X PATCH "https://gateway.example.com/admin/v1/gateways/{id}" \
  -H "x-aig-token: <admin-token>" \
  -H "Content-Type: application/json" \
  -d '{
    "config": {
      "bedrock_region": "us-west-2"
    }
  }'

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

> ⚠️ **Caution:** Bedrock credentials are stored encrypted but follow standard BYOK security practices. For production, prefer short-lived STS credentials or an IAM role if running on AWS infrastructure. Rotate credentials regularly.

## IAM requirements

The IAM principal associated with the credentials requires the following permission:

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

## Endpoint

### Native endpoint

```
POST /v1/{tenant}/{gateway}/bedrock/chat/completions
```

## Request examples

### Standard request

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

Pass the full Bedrock model identifier (including provider prefix and version) in the `model` field. The gateway forwards this as the model identifier in the Converse API call.

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

## See also

- [Providers overview](overview.md)
- [Gateway configuration](../configuration/gateway-config.md) — `bedrock_region`
