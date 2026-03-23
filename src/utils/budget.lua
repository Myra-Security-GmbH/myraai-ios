-- utils/budget.lua — budget period helpers
-- Converts a period type string into the canonical period key for the current moment.
--
-- period_type:
--   "monthly"  → "YYYY-MM"        (default, resets each calendar month)
--   "daily"    → "YYYY-MM-DD"     (resets each calendar day, UTC)
--   "total"    → "total"          (lifetime, never resets automatically)

local M = {}

function M.current_period(period_type)
    local t = os.date("*t", os.time())
    if period_type == "daily" then
        return string.format("%04d-%02d-%02d", t.year, t.month, t.day)
    elseif period_type == "total" then
        return "total"
    else
        -- monthly (default, also used for nil / unknown values)
        return string.format("%04d-%02d", t.year, t.month)
    end
end

return M
