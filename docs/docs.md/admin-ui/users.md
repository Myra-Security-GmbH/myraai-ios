# User Management

The **Users** page lets `admin` and `tenant_admin` users create, view, edit, and delete users within their tenant. Admins additionally see global admin accounts.

Navigate to **Users** in the sidebar (only visible to `admin` and `tenant_admin` roles).

![Users list](../assets/screenshots/users-list.png)

---

## User list

The table shows all users accessible to the currently logged-in user. Clicking a row opens the user detail panel.

**Columns:**

| Column | Description |
|---|---|
| Email | User's email address |
| Name | Display name (if set) |
| Role | `admin`, `tenant_admin`, `member`, or `viewer` |
| Tenant | The tenant the user belongs to |
| Created | Account creation timestamp |

---

## Creating a user

Click **+ New User**. Fill in email, name (optional), and role, then click **Create User**. The new user can immediately log in via the [login page](authentication.md).

---

## Editing a user

Open the user detail panel and click **Edit**. You can update the email, name, and role.

`admin` users can additionally reassign the user to a different **tenant** from the edit dialog. `tenant_admin` users cannot change a user's tenant (they can only manage users within their own tenant).

---

## Deleting a user

Open the user detail panel and click **Delete User**. Deletion is immediate and revokes all tokens associated with that user.

---

## Token management

Open the user detail panel to view, create, and revoke inference tokens for that user. See [Users & Tokens API](../api-reference/users-tokens.md) for the underlying endpoints.

`member` users can manage their own tokens self-service via [My Tokens](my-tokens.md) — no admin action required.

---

## Access control

| Role | Can see Users page | Can manage other users |
|---|---|---|
| `admin` | Yes — all tenants | Yes |
| `tenant_admin` | Yes — own tenant | Yes (own tenant only) |
| `member` | No | — |
| `viewer` | No | — |
