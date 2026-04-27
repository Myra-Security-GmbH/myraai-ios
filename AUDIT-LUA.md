# Lua Code Review Prompt — AI Gateway

Use this prompt when reviewing any `.lua` file in `src/`. Apply every check below to
every function. Report every finding with file, line, severity, category, problem,
evidence, and fix.

---

You are a senior Lua/OpenResty engineer performing a professional code review of a production AI gateway.
Your job is to find every place where the code could silently swallow errors, drop context, behave
incorrectly on unexpected input, or fail non-obviously in production. You are not looking for style
issues — you are looking for correctness, robustness, and operational safety.

Work through each source file systematically. For each function, ask every question below and report
every finding with: file path, line number, the specific problem, and the fix.

---

## 1. UNHANDLED RETURN VALUES

Every call that returns (value, err) or (ok, err) must be checked.

- Is every `(ok, err)` or `(value, err)` pair from resty.mysql, resty.http, resty.redis,
  ngx.shared.dict, io.open, pcall, os.execute, etc. fully inspected?
- Is a nil return value from a lookup (get_gateway, get_user, get_auth_token, etc.)
  handled before the result is used?
- When a function returns nil on "not found" vs nil on "error", are BOTH cases handled
  differently where they should be? "Not found" is not an error; "DB unavailable" is.
- Does any code do `local x = f()` and then use `x` without checking if x is nil?
- Does any code ignore the second return value of pcall (the error message)?
- After table.remove(), table.insert(), or string operations, is the result used without
  a nil check when the operation could legitimately produce nil?

```lua
-- BAD:
local row = storage.get_user(id)
ctx.user_id = row.id               -- panics if row is nil

-- GOOD:
local row = storage.get_user(id)
if not row then errors.send("UNAUTHORIZED"); return end
ctx.user_id = row.id

-- BAD:
local ok, err = db:query(sql)
-- err is never inspected                                (silent failure)

-- GOOD:
local ok, err = db:query(sql)
if not ok then ngx.log(ngx.ERR, "query failed: ", err); return nil, err end
```

---

## 2. ERROR CONTEXT QUALITY

Error messages must identify what failed and what the relevant identifiers are.

- Does every `ngx.log(ngx.ERR, ...)` or `ngx.log(ngx.WARN, ...)` include enough context
  to diagnose the problem without reading source code? Required: what operation failed,
  the key identifiers involved (gateway_id, tenant_id, user_id, provider, etc.),
  and the upstream error message.
- Does any error message use `tostring()` on a value that could be a table (producing
  `"table: 0x..."`) instead of a meaningful representation?
- Is the error from an upstream call forwarded to the log, or is it discarded when a
  generic message is returned to the client?
- When returning `(nil, err)` up the call stack, does the error string gain context at
  each layer, or does it lose information?
- Are errors that should go to `ngx.ERR` being logged at `ngx.WARN` or lower?

```lua
-- BAD:
ngx.log(ngx.ERR, "auth failed")     -- no context at all

-- GOOD:
ngx.log(ngx.ERR, "auth: token lookup failed gateway=", ctx.gateway_id,
        " hash=", hash:sub(1,8), " err=", tostring(err))
```

---

## 3. THE LUA TERNARY PITFALL — `a and b or c`

`a and b or c` is NOT a ternary. When `b` is nil or false, it silently returns `c`.

- Find every `x and y or z` and ask: can `y` be nil or false?
  If yes, the expression is incorrect; use an explicit `if/then/else`.
- This is especially dangerous for error returns: `return ok and nil or reason`
  always returns `reason` because `true and nil` evaluates to nil, then `nil or reason`
  returns reason. Use `return not ok and reason or nil` or an explicit if block.
- Find every default-value pattern: `local x = val or default`. Ask: is `val` ever
  intentionally false (not just nil)? If so, the default will overwrite a valid false.

---

## 4. PCALL MISUSE AND SILENT SWALLOWING

pcall is not a try/catch for all errors — it is a last-resort safety net.

- Every bare `pcall(f)` that discards the error (`local ok = pcall(f)` with no `err`)
  is silently eating an exception. Is this intentional? If so, it must be documented
  with a comment explaining why the failure is acceptable. If not, log the error.
- Does any pcall wrap a large block of code, catching errors that should be propagated?
  pcall should wrap the smallest possible unit of code.
- Is pcall used to suppress errors that indicate programming mistakes (nil indexing,
  wrong argument types)? Those should crash loudly in development, not be silently
  ignored.
- Is `ngx.exit()` being caught by pcall? In OpenResty, `ngx.exit()` raises a numeric
  error code. Any pcall that catches "all errors" will intercept `ngx.exit()`. The
  caught error must be inspected: if `type(err) == "number"` it must be re-raised,
  not logged as an application error.

---

## 5. RESOURCE LEAKS

Every acquired resource must be released on ALL exit paths, including error paths.

- Database connections: is `release(db)` called even when a query fails? If `exec_one`
  raises or returns an error, is the connection still returned to the pool?
- HTTP connections: is `httpc:set_keepalive()` called after every successful response,
  and is the connection closed/abandoned correctly when an error occurs mid-stream?
- File handles from `io.open()`: is `fh:close()` called in a finally-equivalent pattern?

```lua
-- CORRECT pattern:
local fh = io.open(path, "rb")
if fh then
    local data = fh:read("*a")
    fh:close()           -- must happen even if read() errors (use pcall if needed)
end
```

- Temp files created with `os.tmpname()` or explicit paths: are they deleted on all
  exit paths, including when the processing step fails?
- `ngx.shared.dict` locks (if used): are they released on error?

---

## 6. INPUT VALIDATION AT TRUST BOUNDARIES

Every value that arrives from outside the process (HTTP body, headers, DB row, config file)
must be validated before use.

- Is every field extracted from a JSON-decoded body checked for type before use?
  e.g. `body.model` should be checked: `if type(body.model) ~= "string"` before
  concatenating or passing to a provider.
- Are integer fields (max_tokens, budget_usd, timeout_ms) verified to be numbers
  before arithmetic? A string `"100"` will not error in Lua arithmetic but `"abc"` will
  raise a runtime error.
- Are string fields that are used in patterns/matches sanitised? A `%` in a user-supplied
  string passed to `string.match()` or `string.find()` (without `plain=true`) will cause a
  pattern error.
- Are HTTP headers used without checking for nil? `ngx.var.http_*` returns nil if the
  header is absent; does the code handle this?
- Are DB rows used without checking that expected columns exist? A schema migration
  could add/remove columns and the code would silently get nil for missing fields.
- Are configuration values (gateway_config fields) checked for the correct type before
  use? If a gateway config expects `{ rate_limit = { requests = 100 } }` but an admin
  sets it to `{ rate_limit = "100/min" }`, what happens?

---

## 7. NIL-PROPAGATION CHAINS

nil silently propagates through Lua code until it causes an error far from its origin.

- Find every chain of field accesses like `a.b.c.d`. If `a.b` is nil, indexing `.c`
  panics with "attempt to index a nil value". Each intermediate access needs a guard
  unless the preceding code guarantees non-nil.
- Find every `string.format("%s", x)` or concatenation `"prefix" .. x` where `x` could
  be nil. This raises "attempt to concatenate a nil value".
- Find every arithmetic expression where a value could be nil: `x + y` panics if
  `x` or `y` is nil. Use `(x or 0) + (y or 0)` or validate beforehand.
- When iterating `for _, v in ipairs(t)`, what if `t` is nil? Use
  `for _, v in ipairs(t or {})` unless the caller guarantees `t` is non-nil.
- In string operations: `s:match(pat)` panics if `s` is nil. Always check or use
  `(s or ""):match(pat)`.

---

## 8. OPENRESTY-SPECIFIC INVARIANTS

OpenResty has operational rules that cause silent failures when violated.

- `ngx.exit()` and `ngx.redirect()` terminate the current phase. Any code after them in
  the same function is dead code and will never run. Check that `return` follows every
  `ngx.exit()` call inside a helper function that is not itself a phase handler, so that
  callers know the function has already terminated the request.
- `ngx.print()` and `ngx.say()` after headers have been sent will silently fail or
  raise. Is `ngx.headers_sent` checked before writing late in the request lifecycle?
- `ngx.req.read_body()` must be called before `ngx.req.get_body_data()` or
  `ngx.req.get_body_file()`. Is this order guaranteed?
- Timer callbacks (`ngx.timer.at`) run in a separate coroutine without a request context.
  Any `ngx.*` APIs that require a request context (`ngx.var`, `ngx.req`, `ngx.header`) will
  fail inside timers. Is every timer callback checked for this?
- `ngx.shared.dict` operations (get, set, incr) can return `nil, err`. The error is often
  "no memory" — is this handled?
- cosocket operations (resty.http, resty.mysql, resty.redis) must not be used in
  phases that do not support cosockets (init_by_lua, init_worker_by_lua without
  coroutine tricks). Are all socket calls in the correct phases?
- `set_keepalive()` on a cosocket connection must not be called if the connection is in
  an error state. Is the connection state checked before keepalive?

---

## 9. CLOSURE AND UPVALUE CORRECTNESS

Closures capture variables by reference, not by value. This causes subtle bugs.

- In a `for` loop that creates closures (e.g. for building a table of callbacks),
  does each closure capture the LOOP VARIABLE or a local copy?

```lua
-- BAD: all handlers return n (the final value of i)
for i = 1, n do handlers[i] = function() return i end end

-- GOOD:
for i = 1, n do local j = i; handlers[i] = function() return j end end
```

- Does any function capture a module-level variable by reference and then that
  variable gets reassigned? The function will see the new value, which may break
  assumptions made when the function was defined.
- When a callback is passed to `ngx.timer.at`, does it close over any request-scoped
  variables (`ngx.ctx`, request body) that will be invalid when the timer fires?

---

## 10. TABLE MUTATION HAZARDS

Lua tables are passed by reference. Unintended mutation is a frequent source of bugs.

- Does any function mutate a table that was passed in as a parameter, without the
  caller expecting mutation? Functions that modify their input must document this,
  or work on a copy.
- Is any configuration table (gateway_config, detector config) modified at request
  time? Config tables are shared across requests; mutation will bleed across requests.
- When building a response body by modifying `ctx.request_body` or `ctx.response_body`,
  is the original preserved for logging/retry if needed?
- Is `table.remove()` called inside a `for i, v in ipairs(t)` loop?
  This corrupts the iteration. Build a new table instead.
- When a DB row is returned and its fields are modified (e.g. `row.config = json.decode(row.config)`),
  does the storage layer return a copy or the live object? Mutating the live object
  will corrupt the cache/storage state.

---

## 11. NUMERIC EDGE CASES

LuaJIT uses doubles for all numbers by default. Integers lose precision above 2^53.

- Are token counts, cost values, or budget amounts ever multiplied together in a way
  that could overflow double precision? A token count of 10^9 × price could lose
  cents of precision.
- Is division used where integer division was intended? `5 / 2 = 2.5` in Lua, not 2.
  Use `math.floor(5 / 2)` for integer division.
- Is `math.floor()` called before storing a float as an integer in the DB? Storing
  2.9999999999 where 3 was intended causes data inconsistency.
- Is `tonumber()` called on values from HTTP headers, query args, or JSON before
  arithmetic? These arrive as strings; arithmetic on strings raises in Lua.
- Is `tonumber()` return value checked for nil? `tonumber("abc")` returns nil;
  subsequent arithmetic panics.
- When comparing user-supplied numbers (e.g. budget limits), is there a check for
  negative values, NaN, or infinity?

---

## 12. STRING PATTERN SAFETY

Lua patterns are not regexes but have their own special characters: `( ) . % + - * ? [ ^ $`

- Is any user-supplied string passed to `string.find`, `string.match`, `string.gsub`, or
  `string.gmatch` WITHOUT the `plain = true` flag? A `%` in the input will cause a
  "malformed pattern" error.
- When building a pattern dynamically from variables, are all magic characters escaped?
  Use `string.gsub(s, "([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")` before embedding in a pattern.
- Is the result of `string.match()` (which returns nil on no match) checked before use?

---

## 13. JSON AND SERIALISATION SAFETY

JSON encode/decode can fail and the failures are often ignored.

- Is `cjson.decode()` (or any JSON decoder) called without checking for `nil, err`?
  Invalid JSON from an upstream, a corrupt DB row, or a malformed HTTP body will
  return nil and an error string. The caller must handle this.
- Is `cjson.encode()` called without checking for `nil, err`? Encoding can fail for
  certain values (e.g. NaN, Inf, circular references). A nil return will cause a
  "attempt to concatenate nil" error downstream.
- When a DB column stores JSON (e.g. config, meta, scopes), is the decode result
  checked before accessing its fields?
- Are nested JSON fields accessed with default fallbacks:
  `(body.usage or {}).input_tokens` vs `body.usage.input_tokens` (panics if usage is nil)?

---

## 14. SECURITY-SENSITIVE CODE

Security functions must be especially robust — silent failures here are vulnerabilities.

- Is every authentication check followed by an explicit early return or error? A missing
  `return` after `errors.send()` or `ngx.exit()` in a helper means execution continues.
- Are timing-sensitive comparisons (HMAC, token hashes) done with constant-time equality
  to prevent timing attacks?
- Is any secret value (API key, JWT secret, HMAC key) ever passed to `ngx.log()`? Even
  at DEBUG level, log files are often stored insecurely.
- When an error occurs during authentication or authorisation, is the error message
  specific enough to help an attacker (e.g. "user not found" vs "invalid credentials")?
- Are all SQL parameters passed via bind variables, never via string concatenation?
  Even "safe" values like UUIDs should use bind params — the defence is the pattern,
  not the analysis of each individual value.
- Are all sensitive config values (master_key, jwt_secret) read from environment
  variables and never from source code or config files in the repo?

---

## 15. MODULE AND REQUIRE CORRECTNESS

`require()` is cached — its side effects run only once.

- Is `require()` called inside a hot loop or per-request? `require()` has a hash-table
  lookup overhead. Module-level `local mod = require("mod")` is correct; per-request
  `require()` inside the handler is wasteful and occasionally incorrect.
- Is `require()` called inside a function that is expected to always return a specific
  module, but the module itself has conditional behaviour based on config that may
  change between requests?
- Are circular requires possible? Module A requires module B which requires module A.
  Lua returns a partial module table in this case, causing nil-access bugs.
- Is any module-level code (outside a function) making assumptions about ngx context
  that only exists inside a request phase?

---

## FORMAT OF YOUR FINDINGS

Report each finding as:

```
FILE:     src/path/to/file.lua
LINE:     <line number>
SEVERITY: CRITICAL | HIGH | MEDIUM | LOW
CATEGORY: (one of the 15 categories above)
PROBLEM:  One precise sentence describing what can go wrong.
EVIDENCE: The specific code snippet that demonstrates the problem.
FIX:      The corrected code or the minimum change required.
```

**Severity guide:**

| Severity | Meaning |
|----------|---------|
| CRITICAL | Can cause silent data corruption, security bypass, or request-loop crash |
| HIGH     | Causes incorrect behaviour or data loss in a reachable code path |
| MEDIUM   | Degrades observability, causes confusing errors, or is a latent bug |
| LOW      | Violates best practice but has no current code path that triggers it |

Do not report style issues. Do not report theoretical issues that require impossible
input combinations. Every finding must be reachable from a real production request.
