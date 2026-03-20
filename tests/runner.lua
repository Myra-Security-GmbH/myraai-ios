-- tests/runner.lua — minimal busted-compatible test runner for resty
-- Usage: resty tests/runner.lua tests/integration/test_foo.lua
--
-- Supports: describe(), it(), before_each(), after_each(), assert.*

-- Suppress resty's global-write guard for test DSL globals
local _orig_newindex = debug.getmetatable(_G) and debug.getmetatable(_G).__newindex
if debug.getmetatable(_G) then
    debug.getmetatable(_G).__newindex = rawset
end

local total, passed, failed, errors_list = 0, 0, 0, {}

-- ---------------------------------------------------------------------------
-- assert extensions
-- ---------------------------------------------------------------------------
local assert_mt = {}
assert_mt.__index = assert_mt

function assert_mt.equal(a, b, msg)
    if a ~= b then
        error((msg or ("expected " .. tostring(a) .. " == " .. tostring(b))), 2)
    end
end

function assert_mt.not_equal(a, b, msg)
    if a == b then
        error((msg or ("expected " .. tostring(a) .. " ~= " .. tostring(b))), 2)
    end
end

function assert_mt.is_nil(v, msg)
    if v ~= nil then error((msg or ("expected nil, got " .. tostring(v))), 2) end
end

function assert_mt.not_nil(v, msg)
    if v == nil then error((msg or "expected non-nil"), 2) end
end

function assert_mt.is_true(v, msg)
    if v ~= true then error((msg or ("expected true, got " .. tostring(v))), 2) end
end

function assert_mt.is_false(v, msg)
    if v ~= false then error((msg or ("expected false, got " .. tostring(v))), 2) end
end

function assert_mt.is_string(v, msg)
    if type(v) ~= "string" then
        error((msg or ("expected string, got " .. type(v))), 2)
    end
end

-- assert.has_no.errors(fn)
local has_no = {
    errors = function(fn, msg)
        local ok, err = pcall(fn)
        if not ok then
            error((msg or ("unexpected error: " .. tostring(err))), 2)
        end
    end
}

-- assert.has_error(fn)
local function has_error(fn, msg)
    local ok = pcall(fn)
    if ok then error((msg or "expected an error but none raised"), 2) end
end

_G.assert = setmetatable({
    has_no    = has_no,
    has_error = has_error,
}, {
    __index = assert_mt,
    __call  = function(_, cond, msg)
        if not cond then error((msg or "assertion failed"), 2) end
    end,
})

-- ---------------------------------------------------------------------------
-- describe / it / before_each / after_each
-- ---------------------------------------------------------------------------
local current_before_each = nil
local current_after_each  = nil

_G.describe = function(name, fn)
    io.write("\n  " .. name .. "\n")
    local saved_before = current_before_each
    local saved_after  = current_after_each
    current_before_each = nil
    current_after_each  = nil
    fn()
    current_before_each = saved_before
    current_after_each  = saved_after
end

_G.before_each = function(fn) current_before_each = fn end
_G.after_each  = function(fn) current_after_each  = fn end

_G.it = function(name, fn)
    total = total + 1
    if current_before_each then
        local ok, err = pcall(current_before_each)
        if not ok then
            io.write("    [BEFORE_ERR] " .. name .. "\n               " .. tostring(err) .. "\n")
            failed = failed + 1
            errors_list[#errors_list + 1] = name .. ": before_each: " .. tostring(err)
            return
        end
    end

    local ok, err = pcall(fn)

    if current_after_each then pcall(current_after_each) end

    if ok then
        passed = passed + 1
        io.write("    [PASS] " .. name .. "\n")
    else
        failed = failed + 1
        io.write("    [FAIL] " .. name .. "\n           " .. tostring(err) .. "\n")
        errors_list[#errors_list + 1] = name .. ": " .. tostring(err)
    end
end

-- ---------------------------------------------------------------------------
-- Load and run each test file given as argument
-- ---------------------------------------------------------------------------
-- Fix package.path for project layout
package.path = "src/?.lua;src/?/init.lua;tests/?.lua;tests/?/init.lua;" .. package.path

local files = {}
for i = 1, #arg do files[#files + 1] = arg[i] end

if #files == 0 then
    -- Auto-discover if no args
    local handle = io.popen("find tests -name 'test_*.lua' | sort")
    for f in handle:lines() do files[#files + 1] = f end
    handle:close()
end

for _, file in ipairs(files) do
    io.write("\n" .. file .. "\n")
    local ok, err = pcall(dofile, file)
    if not ok then
        io.write("  [LOAD ERROR] " .. tostring(err) .. "\n")
        errors_list[#errors_list + 1] = file .. ": " .. tostring(err)
        failed = failed + 1
        total  = total  + 1
    end
end

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
io.write(string.format("\n%d tests: %d passed, %d failed\n", total, passed, failed))
if #errors_list > 0 then
    io.write("\nFailed:\n")
    for _, e in ipairs(errors_list) do
        io.write("  - " .. e .. "\n")
    end
    os.exit(1)
end
