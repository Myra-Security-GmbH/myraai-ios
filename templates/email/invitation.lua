-- email/invitation.lua — new user invitation email template
-- vars: name, email, role, login_url

local M = {}

M.subject = "You've been invited to AI Gateway"

local ROLE_DESC = {
    admin        = "You have full platform access across all tenants, gateways, and settings.",
    tenant_admin = "You can manage users and settings within your tenant.",
    member       = "You have full access within your tenant: gateways, users, and usage data.",
    viewer       = "You have read-only access to your tenant's resources. You cannot make changes or run inference.",
}

function M.body(v)
    local name      = type(v.name) == "string" and v.name ~= "" and v.name or nil
    local greeting  = name and ("Hi " .. name .. ",") or "Hi,"
    local role      = tostring(v.role or "member")
    local role_desc = ROLE_DESC[role] or "You can access the admin panel."
    local login_url = tostring(v.login_url or "the admin panel")

    return table.concat({
        greeting,
        "",
        "You've been added to AI Gateway by Myra Security as a " .. role .. ".",
        "",
        "Sign in at:",
        "  " .. login_url,
        "",
        "How to log in:",
        "  1. Click \"Continue with Email code\"",
        "  2. Enter your email: " .. tostring(v.email),
        "  3. Enter the 6-digit code we send you",
        "",
        role_desc,
        "",
        "If you weren't expecting this invitation, you can safely ignore this email.",
        "",
        "— AI Gateway by Myra Security",
    }, "\n")
end

function M.body_html(v)
    local name      = type(v.name) == "string" and v.name ~= "" and v.name or nil
    local greeting  = name and ("Hi " .. name .. ",") or "Hi,"
    local role      = tostring(v.role or "member")
    local role_desc = ROLE_DESC[role] or "You can access the admin panel."
    local login_url = tostring(v.login_url or "#")
    local email     = tostring(v.email or "")

    return [[<!DOCTYPE html>
<html lang="en">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>
<body style="margin:0;padding:0;background:#f4f4f5;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;">
  <table width="100%" cellpadding="0" cellspacing="0" style="background:#f4f4f5;padding:40px 0;">
    <tr><td align="center">
      <table width="480" cellpadding="0" cellspacing="0" style="background:#ffffff;border-radius:8px;overflow:hidden;box-shadow:0 1px 4px rgba(0,0,0,.08);">
        <!-- Header -->
        <tr>
          <td style="background:#002b4a;padding:28px 40px;">
            <span style="color:#ffffff;font-size:18px;font-weight:600;letter-spacing:.5px;">AI Gateway</span>
            <span style="color:#7eb3d4;font-size:12px;margin-left:8px;">by Myra Security</span>
          </td>
        </tr>
        <!-- Body -->
        <tr>
          <td style="padding:40px;">
            <p style="margin:0 0 16px;font-size:15px;color:#374151;line-height:1.6;">]] .. greeting .. [[</p>
            <p style="margin:0 0 24px;font-size:15px;color:#374151;line-height:1.6;">
              You've been added to <strong>AI Gateway by Myra Security</strong> as a
              <strong>]] .. role .. [[</strong>.
            </p>
            <p style="margin:0 0 8px;font-size:13px;color:#6b7280;">]] .. role_desc .. [[</p>
            <hr style="border:none;border-top:1px solid #e5e7eb;margin:24px 0;">
            <!-- Sign-in button -->
            <p style="margin:0 0 16px;font-size:14px;font-weight:600;color:#374151;">How to sign in:</p>
            <table width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 20px;">
              <tr>
                <td align="center">
                  <a href="]] .. login_url .. [[" style="display:inline-block;background:#002b4a;color:#ffffff;text-decoration:none;font-size:14px;font-weight:600;padding:12px 32px;border-radius:6px;">
                    Sign in to AI Gateway
                  </a>
                </td>
              </tr>
            </table>
            <ol style="margin:0 0 24px;padding-left:20px;font-size:13px;color:#6b7280;line-height:2;">
              <li>Click <strong>Continue with Email code</strong></li>
              <li>Enter your email: <span style="font-family:'Courier New',monospace;background:#f3f4f6;padding:1px 6px;border-radius:3px;">]] .. email .. [[</span></li>
              <li>Enter the 6-digit code we send you</li>
            </ol>
            <p style="margin:0;font-size:12px;color:#9ca3af;line-height:1.5;">
              If you weren't expecting this invitation, you can safely ignore this email.
            </p>
          </td>
        </tr>
        <!-- Footer -->
        <tr>
          <td style="background:#f9fafb;border-top:1px solid #e5e7eb;padding:20px 40px;">
            <p style="margin:0;font-size:12px;color:#9ca3af;">
              AI Gateway by Myra Security &mdash; <a href="https://www.myra.eu" style="color:#002b4a;text-decoration:none;">myra.eu</a>
            </p>
          </td>
        </tr>
      </table>
    </td></tr>
  </table>
</body>
</html>]]
end

return M
