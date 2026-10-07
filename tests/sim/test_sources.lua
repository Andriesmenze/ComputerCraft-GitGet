-- Static checks on every Lua file that runs on a CC computer (FILES from
-- run.py). The scanner (codeOnly) and the feature list come from WorkerNet's
-- tests/sim/test_sources.lua, which took them from XEncrypt's.
local T = require("testlib")
local test, eq, ok = T.test, T.eq, T.ok

local function readRepo(rel)
  local f = io.open(REPO .. "/" .. rel, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local IN_GAME = {}
for i = 1, #FILES do IN_GAME[#IN_GAME + 1] = FILES[i] end

test("the file list covers programs/gitget.lua", function()
  local seen = {}
  for _, rel in ipairs(IN_GAME) do seen[rel] = true end
  ok(seen["programs/gitget.lua"], "programs/gitget.lua")
end)

-- Before CC:Tweaked 1.109 source files were read through a UTF-8 decoder, so a
-- non-ASCII byte could load differently depending on the version.
for _, rel in ipairs(IN_GAME) do
  test(rel .. " is pure ASCII", function()
    local src, line = assert(readRepo(rel)), 1
    for i = 1, #src do
      local b = src:byte(i)
      if b == 10 then line = line + 1 end
      if b > 127 then error("non-ASCII byte " .. b .. " on line " .. line, 0) end
    end
  end)
end

-- Replaces comments and string literals by spaces (keeping newlines), so only
-- code is left to check.
local function codeOnly(src)
  local out, i, n = {}, 1, #src
  local function blank(s) return (s:gsub("[^\n]", " ")) end
  while i <= n do
    local c = src:sub(i, i)
    local long = src:match("^%-%-%[(=*)%[", i) or src:match("^%[(=*)%[", i)
    if long then
      local open = src:match("^%-%-", i) and ("--[" .. long .. "[") or ("[" .. long .. "[")
      local _, close = src:find("]" .. long .. "]", i + #open, true)
      close = close or n
      out[#out + 1] = blank(src:sub(i, close))
      i = close + 1
    elseif src:match("^%-%-", i) then
      local e = src:find("\n", i, true) or n + 1
      out[#out + 1] = blank(src:sub(i, e - 1))
      i = e
    elseif c == '"' or c == "'" then
      local j = i + 1
      while j <= n do
        local d = src:sub(j, j)
        if d == "\\" then j = j + 2
        elseif d == c then break
        else j = j + 1 end
      end
      out[#out + 1] = blank(src:sub(i, j))
      i = j + 1
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
  return table.concat(out)
end

local function lineOf(code, at)
  local _, lines = code:sub(1, at):gsub("\n", "")
  return lines + 1
end

-- Lua features that newer desktop Luas have but CC:Tweaked's Cobalt does not:
-- https://tweaked.cc/reference/feature_compat.html
local UNSUPPORTED = {
  { "//", "floor division operator" },
  { "&", "bitwise and operator (use bit32.band)" },
  { "|", "bitwise or operator (use bit32.bor)" },
  { "<<", "shift operator (use bit32.lshift)" },
  { ">>", "shift operator (use bit32.rshift)" },
  { "~[^=]", "bitwise xor/not operator (use bit32.bxor/bnot)" },
  { "math%.type", "math.type" },
  { "math%.tointeger", "math.tointeger" },
  { "math%.ult", "math.ult" },
  { "math%.maxinteger", "math.maxinteger" },
  { "math%.mininteger", "math.mininteger" },
  { "collectgarbage", "collectgarbage" },
  { "string%.dump", "string.dump" },
  { "os%.exit", "os.exit" },
  { "os%.execute", "os.execute" },
  { "table%.setn", "table.setn" },
  { "gcinfo", "gcinfo" },
  { "%f[%w_]goto%f[^%w_]", "goto" },
}

for _, rel in ipairs(IN_GAME) do
  test(rel .. " only uses Lua features CC:Tweaked supports", function()
    local code = codeOnly(assert(readRepo(rel)))
    for _, rule in ipairs(UNSUPPORTED) do
      local at = code:find(rule[1])
      if at then error(rule[2] .. " on line " .. lineOf(code, at), 0) end
    end
  end)
end

-- GitGet only reads JSON from the network, and never turns it into code.
local NETWORK_UNSAFE = {
  { "textutils%.unseriali[sz]e%f[^%w_]", "textutils.unserialize" },
  { "%f[%w_]loadstring%f[^%w_]", "loadstring" },
  { "%f[%w_.:]load%s*%(", "load(...)" },
}

for _, rel in ipairs(IN_GAME) do
  test(rel .. " never turns received text into code", function()
    local code = codeOnly(assert(readRepo(rel)))
    for _, rule in ipairs(NETWORK_UNSAFE) do
      local at = code:find(rule[1])
      if at then error(rule[2] .. " on line " .. lineOf(code, at), 0) end
    end
  end)
end

-- The login token lives only in memory: GitGet never uses the settings API.
for _, rel in ipairs(IN_GAME) do
  test(rel .. " never uses settings", function()
    local code = codeOnly(assert(readRepo(rel)))
    local at = code:find("%f[%w_]settings%s*%.")
    if at then error("settings on line " .. lineOf(code, at), 0) end
  end)
end

test("the source checks find what they look for and ignore strings and comments", function()
  ok(codeOnly("local a = 1 // 2"):find("//"), "floor division")
  ok(not codeOnly('local s = "a // b" -- x & y'):find("[/&]"), "string and comment")
  ok(not codeOnly("--[[ a | b ]] local x = [==[ c >> d ]==]"):find("[|>]"), "long comment and string")
  ok(codeOnly("x = a ~ b"):find("~[^=]"), "xor")
  ok(not codeOnly("if a ~= b then end"):find("~[^=]"), "not equal")
  ok(codeOnly("local t = math.type(1)"):find("math%.type"), "math.type")
  ok(codeOnly("goto done"):find("%f[%w_]goto%f[^%w_]"), "goto")
  ok(not codeOnly("local gotox = 1"):find("%f[%w_]goto%f[^%w_]"), "goto inside a name")
  ok(codeOnly("settings.set('a', t)"):find("%f[%w_]settings%s*%."), "settings")
  ok(not codeOnly("-- settings.set"):find("%f[%w_]settings%s*%."), "settings in a comment")
  ok(codeOnly("local t = textutils.unserialize(s)"):find(NETWORK_UNSAFE[1][1]), "unserialize")
  ok(codeOnly("local t = textutils.unserialise(s)"):find(NETWORK_UNSAFE[1][1]), "unserialise")
  ok(not codeOnly("local t = textutils.unserializeJSON(s)"):find(NETWORK_UNSAFE[1][1]), "JSON is allowed")
  ok(codeOnly("local f = load (s)"):find(NETWORK_UNSAFE[3][1]), "load")
  ok(not codeOnly("local f = os.loadAPI(p)"):find(NETWORK_UNSAFE[3][1]), "os.loadAPI is not load")
  ok(not codeOnly("x.load(s) y:load(s) payload(s)"):find(NETWORK_UNSAFE[3][1]), "methods named load")
end)

return T.finish("test_sources.lua")
