---
title: Tenants
description: Create and manage tenants in AI Gateway by Myra Security. Tenants are the top-level organisational units that group users, gateways, and usage data.
---

# Tenants

![View: Tenants list](../assets/screenshots/tenants-list.png)
*The **Tenants** list.*

A tenant is the top-level organisational unit in AI Gateway. Each tenant has its own set of users, gateways, inference tokens, and usage data. Tenants are completely isolated from one another — users and tokens of one tenant cannot access the resources of another.

The **Tenants** view is accessible from the **Tenants** entry in the left sidebar. It is visible only to users with the `admin` role.

For background on the multi-tenancy architecture, see [Multi-tenancy](../concepts/multi-tenancy.md).

---

## Creating a tenant

Before you begin, ensure the following conditions are met:

- ☑ You are logged in as a user with the `admin` role.

Proceed as follows to create a tenant:

1. Click on **Tenants** in the left sidebar.
   - The **Tenants** list opens.
2. Click on the **+ New Tenant** button.
   - The **New Tenant** dialog opens.
3. Enter a name for the tenant in the **Name** text field.
4. If required, enter a description in the **Description** text field.
5. Click on the **Create Tenant** button.

→ The new tenant appears in the tenants list. The tenant is empty — add users and gateways to make it operational.

---

## Editing a tenant

Before you begin, ensure the following conditions are met:

- ☑ You are logged in as a user with the `admin` role.

Proceed as follows to edit a tenant:

1. Click on **Tenants** in the left sidebar.
   - The **Tenants** list opens.
2. Click on the tenant you want to edit.
   - The tenant detail view opens.
3. Click on the **Edit** button.
   - The edit form opens.
4. Update the **Name** or **Description** fields as required.
5. Click on the **Save** button.

→ The updated details are applied to the tenant immediately.

---

## Deleting a tenant

Before you begin, ensure the following conditions are met:

- ☑ You are logged in as a user with the `admin` role.

> ⚠️ **Caution:** Deleting a tenant is irreversible. All users, gateways, tokens, and usage data belonging to the tenant are permanently removed.

Proceed as follows to delete a tenant:

1. Click on **Tenants** in the left sidebar.
   - The **Tenants** list opens.
2. Click on the tenant you want to delete.
   - The tenant detail view opens.
3. Click on the **Delete Tenant** button.
   - A confirmation dialog opens.
4. Click on the **Delete** button to confirm.

→ The tenant and all its associated data are permanently deleted.

---

## Assigning users to a tenant

Users are assigned to a tenant when they are created or when an existing user is edited. The `admin` role is required to change a user's tenant assignment.

Proceed as follows to assign a user to a tenant:

1. Click on **Users** in the left sidebar.
   - The **Users** list opens.
2. Click on the user you want to assign.
   - The user detail panel opens.
3. Click on the **Edit** button.
4. Select the target tenant from the **Tenant** drop-down list.
5. Click on the **Save** button.

→ The user is now a member of the selected tenant and can access its gateways.

> 💡 **Note:** Users can belong to only one tenant at a time.

---

## Chat presets

Chat presets let a tenant administrator define a fixed set of gateway and model combinations that appear as quick-select buttons in the **Chat** view. When presets are configured, users with the `member` or `viewer` role see only the preset buttons and cannot select a different gateway or model. Users with the `admin` or `tenant_admin` role retain full access to all gateways and models.

Each preset has the following fields:

| Field | Description |
|---|---|
| **Name** | A short label displayed on the preset button (for example, "Claude Sonnet" or "GPT-4o"). |
| **Gateway** | The gateway that handles requests when this preset is selected. |
| **Provider** | The provider to use (for example, `anthropic`, `openai`). |
| **Model** | The model to use (for example, `claude-sonnet-4-6`, `gpt-4o`). |

### Configuring presets

Before you begin, ensure the following conditions are met:

- ☑ You are logged in as a user with the `admin` or `tenant_admin` role.
- ☑ At least one gateway with a configured provider key exists on the tenant.

Proceed as follows to configure chat presets:

1. Click on **Tenants** in the left sidebar.
   - The **Tenants** list opens.
2. Click on the tenant you want to configure.
   - The tenant detail view opens.
3. Scroll to the **Chat Presets** section.
4. Click on **+ Add Preset**.
   - A preset form opens.
5. Enter a name, select a gateway, provider, and model.
6. Click **Save**.

→ The preset is added and becomes visible to all users of the tenant in the Chat view immediately.

Repeat the process to add additional presets. You can edit or delete presets at any time.

> 💡 **Note:** If you remove all presets from a tenant, the Chat view reverts to showing the standard gateway and model drop-down lists for all users.

---

## See also

- [Users](users.md)
- [Gateways](../configuration/gateway-config.md)
- [Multi-tenancy](../concepts/multi-tenancy.md)
- [Chat — Chat presets](chat.md#chat-presets) — how presets appear in the Chat view
- [Tenants & Gateways API](../api-reference/tenants-gateways.md)
