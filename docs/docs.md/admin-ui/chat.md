---
title: Chat
description: How to use the Chat view in the AI Gateway admin panel to send messages, attach files, and export conversations.
---

# Chat

## View: Chat

![View: Chat](../assets/screenshots/chat.png)
*View: Chat*

The **Chat** view provides a persistent, multi-turn conversation interface that routes messages through the gateway. It is accessible to all authenticated users. The view is available from the **Chat** entry in the sidebar.

The view is divided into three areas:

- **Configuration bar** — runs along the top of the view. Contains the tenant, gateway, and model selectors, as well as the export buttons.
- **Conversation list** — a panel on the left side. Lists all saved conversations for the current user.
- **Message area** — the main area on the right. Shows the message history for the active conversation and contains the message input field.

### Configuration bar

The configuration bar contains three selectors that determine which gateway handles your messages:

| Control | Description |
|---|---|
| **Tenant** drop-down list | Selects the tenant whose gateways are available |
| **Gateway** drop-down list | Selects a gateway within the chosen tenant. The provider keys, routing rules, and guardrails of the gateway apply to every message. |
| **Model** drop-down list | Selects the model to use. Lists models from all providers with a key configured on the selected gateway. |

Selections are stored in your browser's local storage and restored when you return to the view.

When a conversation with messages is active, two export buttons appear in the configuration bar:

| Button | Description |
|---|---|
| **Download Markdown** button | Downloads the conversation as a `.md` file. Attached images and documents appear as labelled references. |
| **Download PDF** button | Downloads the conversation as a formatted `.pdf` file. |

Both buttons are inactive when no conversation is selected or the active conversation has no messages.

### Conversation list

The conversation list panel shows all conversations belonging to the current user, ordered by most recently updated. Clicking a conversation loads its message history in the message area. Conversations are private — only the user who created them can see them.

| Action | Control |
|---|---|
| Create a new conversation | **+ New Chat** button at the top of the list |
| Rename a conversation | Double-click the conversation title to edit it inline |
| Delete a conversation | Click the **×** button on the conversation row |

### Message area

The message area shows the full message history for the active conversation. Each assistant response displays the token counts (input and output) and the cost for that turn.

A settings drawer is accessible by clicking the **gear** (⚙) icon. Settings apply to the current conversation:

| Setting | Description |
|---|---|
| **System prompt** text field | An initial instruction sent to the model before any user messages. A default prompt is pre-filled. |
| **Temperature** slider | Controls response randomness. Range: 0–2. Default: 0.7. |
| **Max tokens** field | The maximum number of tokens the model generates per response. Default: 8 192. |
| **Web search** toggle | Enables live web search augmentation for the current conversation. The globe icon in the message toolbar also toggles this setting. See [Web search](../features/web-search.md). |
| **Extended thinking** toggle | Enables the model's internal reasoning process before it generates a response. Appears only when the selected model supports extended thinking. |
| **Thinking budget** slider | Controls the maximum number of tokens the model may use for internal reasoning. Available only when extended thinking is enabled. |

The message input field sits at the bottom of the message area. Text typed here is sent when you press **Enter** or click the **Send** button. A **Stop** button appears while a response is streaming — clicking it aborts the current response.

All messages in the active conversation are sent to the model on every turn, giving the model full context. Documents and spreadsheets attached in earlier turns remain accessible throughout the conversation.

---

## Starting a conversation

Proceed as follows to start a new conversation:

1. Click the **+ New Chat** button at the top of the conversation list.
   - A new, empty conversation appears in the list and becomes active.
2. Select a tenant from the **Tenant** drop-down list in the configuration bar.
3. Select a gateway from the **Gateway** drop-down list.
4. Select a model from the **Model** drop-down list.
5. Type your message in the input field at the bottom of the message area.
6. Press **Enter** or click the **Send** button.
   - A status indicator appears in the message area while the system processes the request.

→ The model's response streams into the message area in real time.

---

## Importing a file

![View: Chat — file attachment](../assets/screenshots/chat-file-attach.png)
*View: Chat — file attachment*

Proceed as follows to attach a file to a message:

1. Click the **paperclip** icon in the message input area, or drag a file from your desktop and drop it anywhere on the message area.
   - A blue drop target appears when you drag a file over the message area.
   - The attached file appears in the input area.
2. Type a message to accompany the file, or leave the input field empty to let the model describe the file.
3. Press **Enter** or click the **Send** button.

→ The file is sent with your message. The model processes the file content and responds.

The following file types are supported:

| Format | Extensions |
|---|---|
| Images | `.jpg`, `.jpeg`, `.png`, `.gif`, `.webp` |
| PDF | `.pdf` |
| Plain text | `.txt` |
| Word document | `.docx` |
| Spreadsheet | `.csv`, `.tsv`, `.xlsx`, `.xlsm`, `.ods` |
| Presentation | `.pptx` |

> 💡 **Note:** Word, spreadsheet, and presentation files require an **Anthropic** provider key on the selected gateway. Claude reads and analyses the document content and can answer questions about it.

Attaching an unsupported file type shows an error message listing the supported formats.

---

## Exporting a conversation

Proceed as follows to export a conversation:

1. Open the conversation you want to export by clicking it in the conversation list.
2. To copy to the clipboard: click the **Copy as Markdown** button (clipboard icon) in the configuration bar.
   - The full conversation is copied to your clipboard as a Markdown-formatted text. The button briefly shows **Copied!** to confirm the action.
3. To download as Markdown: click the **Download Markdown** button in the configuration bar.
   - The conversation downloads as a `.md` file. Attached images and documents appear as labelled references.
4. To export as PDF: click the **Download PDF** button in the configuration bar.

→ The conversation downloads as a formatted `.pdf` file.

---

## Rating a conversation

Proceed as follows to rate a conversation:

1. Hover over the conversation row in the conversation list.
   - A flag icon (🚩) appears on the right side of the row.
2. Click the flag icon.
   - The **Feedback** dialog opens.
3. Click the star that corresponds to your rating (1 = poor, 5 = excellent).
4. If required, enter a comment in the **Comment** text field.
5. Click the **Save** button.

→ The rating is saved. The flag icon on the conversation row is filled to indicate that feedback has been recorded for this conversation.

---

## Using commands in Chat

Commands are personal prompt shortcuts that insert a saved prompt text into the message input. You create and manage commands in the [My commands](my-commands.md) view.

Proceed as follows to use a command:

1. Type `/` in the message input field.
   - A list of your saved commands appears.
2. Click on the command you want to use, or continue typing the command name to filter the list and then press **Enter**.
   - The prompt text of the command is inserted into the message input field.
3. If required, edit the inserted text before sending.
4. Press **Enter** or click the **Send** button to submit the message.

→ The message is sent with the command's prompt text as the content.

---

## Starring and archiving conversations

Conversations can be starred or archived to help organise the conversation list.

| Action | Control |
|---|---|
| Star a conversation | Click the **star** icon on a conversation row. Starred conversations appear at the top of the list. |
| Archive a conversation | Click the **archive** icon on a conversation row. Archived conversations are hidden from the main list. |
| Show archived conversations | Click the **Show archived** toggle at the top of the conversation list. |
| Unarchive a conversation | Open the archived list, then click the **unarchive** icon on the conversation row. |

Starring and archiving do not affect the conversation content or accessibility via direct URL.

---

## Sharing a conversation

You can generate a public share link for any conversation. Anyone with the link can view the conversation in a read-only page — no authentication is required.

Proceed as follows to share a conversation:

1. Open the conversation you want to share.
2. Click the **Share** button (link icon) in the configuration bar.
   - The **Share conversation** dialog opens.
3. Click **Generate link**.
   - A unique URL is generated and displayed.
4. Copy the link and send it to the intended recipients.

→ Recipients can view the conversation at the shared URL without logging in.

To revoke a share link, open the dialog again and click **Remove link**. Previously shared URLs stop working immediately.

---

## Conversation URL sync

The active conversation is reflected in the browser URL as a `?conv=` query parameter. You can copy the URL from the browser address bar to link directly to a specific conversation. When you open the link, the Chat view loads and selects that conversation automatically.

---

## Ghost mode

Ghost mode disables all database writes and request logging for the duration of the session. Use it for exploratory or sensitive conversations that should not be stored.

Proceed as follows to enable ghost mode:

1. Click the **ghost** icon in the conversation list header.
   - The icon turns active and a visual indicator shows that ghost mode is on.

→ All messages sent while ghost mode is active are kept in memory only. They are not saved to the database, do not appear in request logs, and are lost when you leave the page.

To disable ghost mode, click the ghost icon again. Subsequent conversations are saved normally.

> 💡 **Note:** Conversations created in ghost mode cannot be starred, archived, shared, or exported.

---

## Memory

The memory system allows the model to remember facts about you across conversations. Memories are injected into the system prompt automatically.

There are three types of memory:

| Type | Description |
|---|---|
| **Fact** | A piece of information about you (for example, "I work in the legal department"). |
| **Preference** | A preference for how the model should behave (for example, "Always respond in German"). |
| **Instruction** | A standing instruction (for example, "Cite sources in APA format"). |

### Creating a memory manually

1. Click the **Memories** button in the message toolbar.
   - The memories panel opens.
2. Click **+ Add memory**.
3. Select a type and enter the memory content.
4. Click **Save**.

→ The memory is saved and will be included in all future conversations.

### Auto-learned memories

The model can also learn memories automatically during a conversation by emitting `<memory>` tags. Auto-learned memories appear in the memories panel and can be edited or deleted like any other memory.

### Disabling memory for a conversation

To prevent memory injection in a specific conversation, open the memories panel and toggle **Memory for this conversation** off. The conversation proceeds without any memory context.

---

## Chat presets

When a tenant administrator has configured **chat presets** on the tenant, the configuration bar displays a row of preset buttons instead of the gateway and model drop-down lists. Clicking a preset button selects the associated gateway and model automatically.

Users with the `member` or `viewer` role see only the preset buttons and cannot override the gateway or model selection. Users with the `admin` or `tenant_admin` role can still switch to any gateway or model.

For instructions on configuring presets, see [Tenants — Chat presets](tenants.md#chat-presets).

---

## Extended thinking display

When extended thinking is enabled, the model's internal reasoning appears in a collapsible **Thinking** block above the response. The block shows the duration of the thinking phase. Click the block header to expand or collapse it.

---

## Automatic context management

When a conversation exceeds approximately 75 % of the selected model's context window, earlier messages are automatically summarised. The summary replaces the original messages in the context sent to the model, preserving the key information while freeing space for new messages. This process is invisible — you can continue the conversation without interruption.

---

## See also

- [My commands](my-commands.md) — creating and managing personal prompt shortcuts
- [Projects](projects.md) — workspaces with shared instructions and a default gateway
- [Prompt examples (English)](prompts.md) — ready-to-use prompts for legal, marketing, sales, and finance documents
- [Prompt-Beispiele (Deutsch)](prompts-de.md) — einsatzbereite Prompts auf Deutsch
- [Playground](../observability/playground.md) — side-by-side multi-model comparison without conversation history
- [Provider key management (BYOK)](../security/byok.md) — adding provider keys to a gateway
- [Guardrail pipeline](../security/guardrails.md) — content policies applied to every message
