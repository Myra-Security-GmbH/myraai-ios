---
title: MCP Connectors
description: Connect AI Gateway to external tool servers using the Model Context Protocol so the AI can call external tools during chat.
---

# MCP Connectors

The **MCP Connectors** view lets you register external tool servers that implement the [Model Context Protocol](https://modelcontextprotocol.io) (MCP). Once a connector is registered, the AI can discover and call the tools exposed by the MCP server during chat conversations.

The view is accessible from the **MCP Connectors** entry in the left sidebar and is available to users with the `admin` or `tenant_admin` role.

---

## How MCP connectors work

When you open a chat conversation, the gateway queries each registered MCP connector via a `tools/list` call. The tools returned are added to the model's available functions. If the model decides to use a tool, the gateway forwards the call to the appropriate MCP server, receives the result, and feeds it back into the conversation automatically.

This loop runs entirely on the client side — the model receives tool definitions, requests tool calls, and the results are injected as `tool_result` messages before the model continues generating its response.

---

## Adding a connector

Proceed as follows to add an MCP connector:

1. Click on **MCP Connectors** in the left sidebar.
   - The **MCP Connectors** list opens.
2. Click on the **+ New connector** button.
   - The **New MCP Connector** dialog opens.
3. Enter a name for the connector in the **Name** text field.
4. Enter the URL of the MCP server endpoint in the **Server URL** text field.
   - The URL must point to the JSON-RPC 2.0 endpoint of the MCP server (for example, `https://my-tools-server.example.com/mcp`).
5. Select the authentication method:
   - **None** — no authentication header is sent.
   - **Bearer token** — sends an `Authorization: Bearer <token>` header. Enter the token in the field that appears.
   - **Custom header** — sends a custom HTTP header. Enter the header name and value in the format `Header-Name: header-value`.
6. Optionally, click **Test connection** to verify that the server responds correctly before saving.
7. Click **Create**.

→ The connector appears in the connectors table. The AI will discover its tools in the next chat session.

---

## Editing a connector

Proceed as follows to edit an existing connector:

1. Click on **MCP Connectors** in the left sidebar.
2. Click the **Edit** button in the row of the connector you want to change.
   - The **Edit MCP Connector** dialog opens with the current values pre-filled.
3. Change the required fields.
4. Click **Save**.

→ The changes take effect for new chat sessions.

---

## Deleting a connector

Proceed as follows to delete a connector:

1. Click on **MCP Connectors** in the left sidebar.
2. Click the **Delete** button in the row of the connector you want to remove.
   - A confirmation dialog opens.
3. Confirm the deletion.

→ The connector is removed. The AI will no longer have access to the tools it provided.

---

## Authentication

Three authentication methods are available:

| Method | Description |
|---|---|
| **None** | No authentication header is sent. Use for publicly accessible MCP servers. |
| **Bearer token** | Sends `Authorization: Bearer <token>` with every request. The token is stored encrypted and is not returned in list responses. |
| **Custom header** | Sends a single custom HTTP header. Use for servers that require a proprietary API key header such as `X-Api-Key`. Enter the header in the format `Header-Name: header-value`. |

The authentication value is visible only when you open the edit dialog for an individual connector. It is never included in list responses.

---

## Testing the connection

The **Test connection** button in the connector form sends a JSON-RPC `initialize` call to the configured server URL using the provided authentication. The result is displayed next to the button:

- **Connected ✓** — the server responded successfully.
- **HTTP \<status\>: \<body\>** — the server returned an error response.
- **Error: \<message\>** — a network or timeout error occurred.

The test runs from the browser, so the MCP server must be reachable from the user's network. The test does not save the connector.

---

## See also

- [Chat](chat.md) — using the AI with connected tools in a conversation
- [Gateways](../configuration/gateway-config.md) — configuring the AI provider used for conversations
