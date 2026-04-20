-- email/otp.lua — login OTP code email template
-- vars: code, expiry_minutes

local M = {}

M.subject = "AI Gateway - your login code"

function M.body(v)
    return table.concat({
        "Hi,",
        "",
        "Your login code for AI Gateway by Myra Security is:",
        "",
        "    " .. tostring(v.code),
        "",
        "This code expires in " .. tostring(v.expiry_minutes or 15) .. " minutes.",
        "Do not share it with anyone.",
        "",
        "If you did not request this code, you can safely ignore this email.",
        "",
        "— AI Gateway by Myra Security",
    }, "\n")
end

function M.body_html(v)
    local code    = tostring(v.code)
    local expiry  = tostring(v.expiry_minutes or 15)
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
            <p style="margin:0 0 24px;font-size:15px;color:#374151;line-height:1.6;">Hi,</p>
            <p style="margin:0 0 24px;font-size:15px;color:#374151;line-height:1.6;">
              Your login code for <strong>AI Gateway by Myra Security</strong> is:
            </p>
            <!-- Code box -->
            <table width="100%" cellpadding="0" cellspacing="0" style="margin:0 0 24px;">
              <tr>
                <td align="center" style="background:#f0f7ff;border:2px solid #002b4a;border-radius:8px;padding:20px;">
                  <span style="font-family:'Courier New',Courier,monospace;font-size:36px;font-weight:700;letter-spacing:12px;color:#002b4a;">]] .. code .. [[</span>
                </td>
              </tr>
            </table>
            <p style="margin:0 0 12px;font-size:13px;color:#6b7280;line-height:1.5;">
              This code expires in <strong>]] .. expiry .. [[ minutes</strong>. Do not share it with anyone.
            </p>
            <p style="margin:0;font-size:13px;color:#9ca3af;line-height:1.5;">
              If you did not request this code, you can safely ignore this email.
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
