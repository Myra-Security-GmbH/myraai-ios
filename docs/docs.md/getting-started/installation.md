---
title: Getting access
description: How to gain access to AI Gateway by Myra Security and complete the initial setup required before making your first request.
---

# Getting access

AI Gateway by Myra Security is a managed service running on the Global Myra Security CDN. There is nothing to install or operate — Myra Security provisions and maintains your instance.

---

## Requesting an instance

Proceed as follows to request access to AI Gateway by Myra Security:

1. Visit the [Myra Security contact page](https://www.myrasecurity.com/en/contact/) and submit an enquiry for AI Gateway.
   - Myra Security reviews your request and provisions a dedicated instance.
2. Wait for the provisioning confirmation from Myra Security.
   - You receive an e-mail containing your admin URL (for example, `https://<your-gateway-host>/admin`) and your initial credentials.
3. Open your admin URL in a browser and enter your credentials in the **Username** and **Password** text fields.
4. Click on the **Log in** button.
   - The admin dashboard opens.

-> Your AI Gateway instance is active and accessible.

---

## On-premise deployment

AI Gateway is also available as an on-premise offering for organisations with data-residency or air-gapped requirements. Myra Security handles licensing, hardware requirements, and deployment support.

To enquire about on-premise deployment, [contact Myra Security](https://www.myrasecurity.com/en/contact/).

---

## Initial setup

Before the gateway processes inference requests, three objects must exist: a gateway, a provider key, and an auth token. Complete the steps below after your first login.

### Creating a gateway

Proceed as follows to create your first gateway:

1. Click on **Tenants** in the left sidebar.
   - The **Tenants** view opens.
2. Click on the **New Tenant** button.
   - The **New Tenant** dialog opens.
3. Enter a name in the **Slug** text field.
4. Click on the **Save** button.
   - The new tenant appears in the tenant list.
5. Click on **Gateways** in the left sidebar.
   - The **Gateways** view opens.
6. Click on the **New Gateway** button.
   - The **New Gateway** dialog opens.
7. Select your new tenant from the **Tenant** drop-down list.
8. Enter a name in the **Slug** text field.
9. Click on the **Save** button.
   - The new gateway appears in the gateway list.

-> The gateway is created and associated with the tenant.

### Adding a provider key

Proceed as follows to store a provider API key in the gateway:

1. Click on **Gateways** in the left sidebar.
   - The **Gateways** view opens.
2. Click on the gateway you created.
   - The gateway detail view opens.
3. Open the **Keys** tab.
   - The provider keys list opens.
4. Click on the **Add Key** button.
   - The **Add Key** dialog opens.
5. Select a provider from the **Provider** drop-down list.
6. Paste your API key into the **API Key** text field.
7. Click on the **Save** button.
   - The new provider key appears in the keys list. The key is encrypted at rest immediately; the plaintext is never stored.

-> The provider key is saved and ready for use by the gateway.

### Creating an auth token

Proceed as follows to create an authentication token for API access:

1. Click on **Gateways** in the left sidebar.
   - The **Gateways** view opens.
2. Click on the gateway you created.
   - The gateway detail view opens.
3. Open the **Auth Tokens** tab.
   - The auth tokens list opens.
4. Click on the **New Token** button.
   - The **New Token** dialog opens.
5. Enter a name in the **Name** text field.
6. If required, set a budget limit in the **Budget** text field.
7. Click on the **Save** button.
   - The new token appears in the token list. Copy the token value — it is shown only once.

-> The auth token is created and ready to use in API requests.

---

## Next steps

- [Quick start](quick-start.md) — make your first inference request
- [Authentication](../security/authentication.md) — manage auth tokens and secure your gateways
- [Gateway configuration](../configuration/gateway-config.md) — full reference for gateway settings
