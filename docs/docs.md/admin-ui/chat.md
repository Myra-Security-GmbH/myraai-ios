# Chat

The **Chat** page provides a persistent, multi-turn conversation interface that routes through the gateway. It is available to all authenticated users and supports text, images, PDFs, plain text files, Word documents, and spreadsheets.

Navigate to **Chat** in the sidebar.

---

## Configuration bar

The top of the page contains three selectors that control which gateway handles your messages.

| Control | Description |
|---|---|
| **Tenant** | Select the tenant whose gateways you want to use |
| **Gateway** | Select a gateway within the chosen tenant. The gateway's provider keys, routing rules, and guardrails apply to every message. |
| **Model** | Select the model to use. The picker lists models from all providers with a key configured on the selected gateway. |

Selections are remembered in your browser's local storage and restored when you return to the page.

---

## Conversation list

The left panel shows all your saved conversations, ordered by most recently updated. Clicking a conversation loads its message history.

| Action | How |
|---|---|
| New conversation | Click **+ New Conversation** at the top of the list |
| Rename | Click the conversation title to edit it inline |
| Delete | Click the **×** button on a conversation row |

Conversations are private — only the user who created them can see them.

---

## Chat settings

Click the gear (⚙) icon to open the settings drawer. Changes apply to the current conversation.

| Setting | Description |
|---|---|
| **System prompt** | Initial instruction sent to the model before any user messages. A default prompt is pre-filled — edit or clear it as needed. |
| **Temperature** | Controls response randomness. Range: 0 – 2. Default: 0.7. |
| **Max tokens** | Maximum number of tokens the model may generate per response. Default: 8 192. |

---

## Sending messages

Type a message in the input field at the bottom and press **Enter** or click **Send**.

Responses stream in real time. While streaming, a **Stop** button appears — click it to abort the current response.

Long responses complete automatically without any action required. Each assistant response shows the token counts (input + output) and cost for that turn.

---

## File attachments

Click the paperclip icon to attach a file to your message. The following file types are supported:

| Format | Extensions |
|---|---|
| Images | `.jpg`, `.jpeg`, `.png`, `.gif`, `.webp` |
| PDF | `.pdf` |
| Plain text | `.txt` |
| Word document | `.docx` |
| Spreadsheet | `.csv`, `.tsv`, `.xlsx`, `.xlsm`, `.ods` |

!!! note "Document and spreadsheet support"
    Word and spreadsheet files require an **Anthropic** provider key on the selected gateway. Claude reads and analyses the document content and can answer questions about it.

Attaching an unsupported file type shows an error message listing the supported formats.

---

## Conversation history

All messages in the current conversation are sent to the model on every turn, giving the model full context of the conversation. This is the standard multi-turn behaviour expected by chat models.

Documents and spreadsheets attached in earlier turns remain accessible to Claude throughout the conversation — no re-upload is required.

---

## Exporting conversations

Two export buttons appear in the configuration bar when a conversation with messages is active:

| Button | Description |
|---|---|
| **Download Markdown** | Downloads the conversation as a `.md` file. Attached images and documents appear as labelled references. |
| **Download PDF** | Downloads the conversation as a formatted `.pdf` file. |

Both buttons are disabled when no conversation is selected or the conversation has no messages.

---

## API

The chat backend is a set of REST endpoints under `/admin/v1/`. All data is scoped to the authenticated user — no user can read or modify another user's conversations.

| Endpoint | Description |
|---|---|
| `GET /admin/v1/conversations` | List all conversations (paginated) |
| `POST /admin/v1/conversations` | Create a conversation |
| `GET /admin/v1/conversations/{id}` | Get a conversation with its messages |
| `PATCH /admin/v1/conversations/{id}` | Update title, model, system prompt, temperature, max tokens |
| `DELETE /admin/v1/conversations/{id}` | Delete a conversation and all its messages |
| `POST /admin/v1/conversations/{id}/messages` | Append a message |
| `PATCH /admin/v1/conversations/{id}/messages/{mid}` | Edit a message |
| `DELETE /admin/v1/conversations/{id}/messages/{mid}` | Delete a message |
| `POST /admin/v1/conversations/{id}/attachments` | Upload an attachment |
| `GET /admin/v1/attachments/{id}` | Download an attachment |
| `DELETE /admin/v1/attachments/{id}` | Delete an attachment |
| `POST /admin/v1/chat/files` | Upload a document or spreadsheet for use in a conversation |
| `POST /admin/v1/chat/export-pdf` | Export a conversation transcript as a PDF |

---

## See also

- [Playground](../observability/playground.md) — side-by-side multi-model comparison without conversation history
- [Provider Key Management (BYOK)](../security/byok.md) — adding provider keys to a gateway
- [Guardrail Pipeline](../security/guardrails.md) — content policies applied to every message
