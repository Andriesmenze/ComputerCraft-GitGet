-- Tiny test runner shared by the test_*.lua files (run through run.py, which sets
-- REPO, HERE, FILES and FILTER).
local T = { pass = 0, fail = 0, failed = {} }

function T.test(name, fn)
  if FILTER ~= nil and FILTER ~= "" and not name:find(FILTER, 1, true) then return end
  local t0 = os.clock()
  local ok, err = xpcall(fn, debug.traceback)
  local dt = os.clock() - t0
  if ok then
    T.pass = T.pass + 1
    print(("PASS  %s  (%.1fs)"):format(name, dt))
  else
    T.fail = T.fail + 1
    T.failed[#T.failed + 1] = name
    print("FAIL  " .. name .. "\n      " .. tostring(err):gsub("\n", "\n      "))
  end
  io.stdout:flush()
end

local function show(v)
  if type(v) == "string" then return ("%q"):format(v) end
  return tostring(v)
end
T.show = show

function T.eq(a, b, msg)
  if a ~= b then error((msg or "value") .. ": expected " .. show(b) .. ", got " .. show(a), 2) end
end
function T.ok(v, msg)
  if not v then error(msg or "assertion failed", 2) end
  return v
end
function T.contains(haystack, needle, msg)
  if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
    error((msg or "text") .. ": expected to contain " .. show(needle) .. ", got:\n" .. tostring(haystack), 2)
  end
end
function T.notContains(haystack, needle, msg)
  if type(haystack) == "string" and haystack:find(needle, 1, true) then
    error((msg or "text") .. ": must not contain " .. show(needle), 2)
  end
end
-- case-insensitive plain search
function T.has(haystack, needle)
  return type(haystack) == "string" and haystack:lower():find(needle:lower(), 1, true) ~= nil
end

function T.finish(file)
  print(("%s: %d passed, %d failed"):format(file or "tests", T.pass, T.fail))
  if T.fail > 0 then print("  failed: " .. table.concat(T.failed, ", ")) end
  return T.fail > 0
end

return T
