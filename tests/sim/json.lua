-- Small JSON encoder and decoder for the simulator. decode behaves like
-- CC:Tweaked's textutils.unserialiseJSON where GitGet relies on it: null
-- becomes nil, "[]" becomes textutils.empty_json_array unless
-- parse_empty_array is false, and malformed input returns nil and a message.
local J = {}

J.EMPTY_ARRAY = setmetatable({}, { __tostring = function() return "empty_json_array" end })

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function isArray(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  for i = 1, n do if t[i] == nil then return false end end
  return n > 0
end

function J.encode(v)
  local t = type(v)
  if t == "string" then
    return '"' .. v:gsub('[%c"\\]', function(c) return escapes[c] or ("\\u%04x"):format(c:byte()) end) .. '"'
  elseif t == "number" then
    if v == math.floor(v) then return ("%d"):format(v) end
    return tostring(v)
  elseif t == "boolean" then
    return tostring(v)
  elseif t == "nil" then
    return "null"
  elseif t == "table" then
    local parts = {}
    if isArray(v) then
      for i = 1, #v do parts[i] = J.encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do parts[#parts + 1] = J.encode(tostring(k)) .. ":" .. J.encode(v[k]) end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  error("can't encode " .. t)
end

function J.decode(s, opts)
  if type(s) ~= "string" then error("bad argument #1 (expected string, got " .. type(s) .. ")", 2) end
  opts = opts or {}
  local pos = 1
  local function fail(msg) error({ json = "Malformed JSON at position " .. pos .. ": " .. msg }) end
  local function skip() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
  local value
  local function str()
    local out = {}
    pos = pos + 1
    while true do
      local c = s:sub(pos, pos)
      if c == "" then fail("unterminated string") end
      if c == '"' then pos = pos + 1 break end
      if c == "\\" then
        local e = s:sub(pos + 1, pos + 1)
        local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["/"] = "/", ["\\"] = "\\" }
        if e == "u" then
          local code = tonumber(s:sub(pos + 2, pos + 5), 16)
          if not code then fail("bad unicode escape") end
          out[#out + 1] = code < 256 and string.char(code) or "?"
          pos = pos + 6
        elseif map[e] then
          out[#out + 1] = map[e]
          pos = pos + 2
        else
          fail("bad escape")
        end
      else
        out[#out + 1] = c
        pos = pos + 1
      end
    end
    return table.concat(out)
  end
  value = function()
    skip()
    local c = s:sub(pos, pos)
    if c == '"' then return str()
    elseif c == "{" then
      local obj = {}
      pos = pos + 1
      skip()
      if s:sub(pos, pos) == "}" then pos = pos + 1 return obj end
      while true do
        skip()
        if s:sub(pos, pos) ~= '"' then fail("expected key") end
        local k = str()
        skip()
        if s:sub(pos, pos) ~= ":" then fail("expected ':'") end
        pos = pos + 1
        obj[k] = value()
        skip()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "}" then return obj end
        if d ~= "," then fail("expected ',' or '}'") end
      end
    elseif c == "[" then
      local arr = {}
      pos = pos + 1
      skip()
      if s:sub(pos, pos) == "]" then
        pos = pos + 1
        if opts.parse_empty_array == false then return {} end
        return J.EMPTY_ARRAY
      end
      while true do
        arr[#arr + 1] = value()
        skip()
        local d = s:sub(pos, pos)
        pos = pos + 1
        if d == "]" then return arr end
        if d ~= "," then fail("expected ',' or ']'") end
      end
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
      if not num or not tonumber(num) then fail("unexpected character") end
      pos = pos + #num
      return tonumber(num)
    end
  end
  local ok, result = pcall(value)
  if not ok then
    if type(result) == "table" and result.json then return nil, result.json end
    error(result, 0)
  end
  skip()
  if pos <= #s then return nil, "Malformed JSON: trailing characters" end
  return result
end

return J
