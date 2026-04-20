---
title: Start page and GUI structure
description: Overview of the AI Gateway admin panel layout, main navigation, and how views relate to each other.
---

# Start page and GUI structure

![View: Dashboard](../assets/screenshots/dashboard-overview.png)
*View: Dashboard*

The AI Gateway admin panel is a browser-based interface. After logging in, the panel opens at the **Dashboard** view. All other views are accessible from the main navigation sidebar on the left side of the screen.

---

## Layout

The admin panel has three structural areas:

| Area | Description |
|---|---|
| **Sidebar** | The main navigation. Present on every view. Lists all available views grouped by function. |
| **Main area** | The content area to the right of the sidebar. Displays the active view. |
| **Account section** | At the bottom of the sidebar. Contains links to **My tokens** and account settings for the currently logged-in user. |

---

## Main navigation

The sidebar groups views into the following sections:

### Overview

| View | Description |
|---|---|
| **Dashboard** | A summary of gateway activity, request counts, costs, and system status. |

### AI tools

| View | Description |
|---|---|
| **Chat** | A persistent, multi-turn conversation interface that routes messages through the gateway. |
| **Projects** | Workspaces that group conversations under shared instructions, a default gateway, and a shared knowledge base. |
| **Playground** | A side-by-side multi-model comparison interface without conversation history. |

### Administration

| View | Description |
|---|---|
| **Users** | Lists all users within the accessible scope. Allows creating, editing, and deleting user accounts. Visible to `admin` and `tenant_admin` roles only. |
| **Gateways** | Lists and manages gateways within the accessible scope. |
| **Tenants** | Lists and manages tenants. Visible to `admin` role only. |
| **Model prices** | Manages custom per-model pricing used for cost attribution. Visible to `admin` role only. |

### Observability

| View | Description |
|---|---|
| **Cost analytics** | Spend breakdown by tenant, gateway, provider, model, and user over time. |
| **Live monitor** | A real-time stream of requests passing through the gateway. |
| **Request logs** | A searchable, filterable record of all past requests. |

### Account

| View | Description |
|---|---|
| **My tokens** | Self-service management of personal inference tokens for the currently logged-in user. |
| **My commands** | Personal prompt shortcuts accessible directly in the **Chat** view. |
| **MCP Connectors** | Registration and management of external tool servers that models can call during conversations. Visible to `admin` and `tenant_admin` roles only. |

---

## View visibility by role

Not all views are visible to all users. The sidebar shows only the views the current user has access to.

| View | `admin` | `tenant_admin` | `member` | `viewer` |
|---|---|---|---|---|
| Dashboard | Yes | Yes | Yes | Yes |
| Chat | Yes | Yes | Yes | Yes |
| Projects | Yes | Yes | Yes | Yes |
| Playground | Yes | Yes | Yes | No |
| Users | Yes | Yes | No | No |
| Gateways | Yes | Yes | No | No |
| Tenants | Yes | No | No | No |
| Model prices | Yes | No | No | No |
| Cost analytics | Yes | Yes | No | No |
| Live monitor | Yes | Yes | No | No |
| Request logs | Yes | Yes | No | No |
| My tokens | Yes | Yes | Yes | No |
| My commands | Yes | Yes | Yes | Yes |
| MCP Connectors | Yes | Yes | No | No |

> 💡 **Note:** The sidebar displays only the views that are accessible to the currently logged-in user's role. Views not listed in the table above are not accessible.

---

## Moving between views

Proceed as follows to navigate to a view:

1. Click any entry in the sidebar.
   - The selected view opens in the main area. The active view is highlighted in the sidebar. No page reload occurs — the panel uses client-side navigation.

→ The selected view is displayed in the main area.

To return to the dashboard from any view, click the **Dashboard** entry at the top of the sidebar, or click the product logo at the top of the sidebar.

---

## See also

- [Logging in](authentication.md) — how to authenticate and what roles exist
- [User management](users.md) — managing user accounts
- [My tokens](my-tokens.md) — creating and revoking inference tokens
- [Chat](chat.md) — using the conversation interface
