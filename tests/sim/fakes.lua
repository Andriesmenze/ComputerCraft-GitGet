-- A small model of the parts of CC:Tweaked that GitGet uses (fs with drives and
-- CC's space accounting, http, term, read, peripheral/disk, shell, os.sleep),
-- plus a fake GitHub that serves repositories from Lua tables. Each test makes
-- a World, puts repositories and answers in it, and runs programs/gitget.lua.
local J = require("json")

local F = {}
F.MIN_FILE = 500 -- CC:Tweaked counts at least 500 bytes per file and folder
F.TOKEN = "ghu_testtoken123"
F.CLIENT_ID = "Iv1.testclient"

local World = {}
World.__index = World

function F.new(opts)
  opts = opts or {}
  local w = setmetatable({
    files = {}, dirs = { [""] = true },
    capacity = { [""] = opts.capacity or 1000000 },
    drives = {},          -- { name, mount, label }
    cwd = opts.cwd or "",
    answers = {},         -- what read() returns, in order
    out = {}, errors = {},
    requests = {},        -- every http request: { method, url, headers, body, binary }
    sleeps = {},
    repos = {},           -- "owner/repo" -> repo (see World:addRepo)
    device = nil,         -- device flow script (see World:deviceFlow)
    failWrite = nil,      -- path pattern whose writes raise "Out of space"
    program = "gitget.lua",
    epoch = 1700000000000,
  }, World)
  return w
end

---------------------------------------------------------------------------
-- fs
---------------------------------------------------------------------------

local function norm(p)
  local parts = {}
  for part in p:gmatch("[^/\\]+") do
    if part == ".." then
      if #parts > 0 then parts[#parts] = nil end
    elseif part ~= "." then
      parts[#parts + 1] = part
    end
  end
  return table.concat(parts, "/")
end
F.norm = norm

function World:mountOf(p)
  p = norm(p)
  local first = p:match("^[^/]+")
  if first and self.capacity[first] then return first end
  return ""
end

function World:used(mount)
  local used = 0
  local function on(p) return self:mountOf(p) == mount end
  for p, data in pairs(self.files) do
    if on(p) then used = used + math.max(#data, F.MIN_FILE) end
  end
  for p in pairs(self.dirs) do
    if p ~= "" and p ~= mount and on(p) then used = used + F.MIN_FILE end
  end
  return used
end

function World:free(p)
  local m = self:mountOf(p)
  return self.capacity[m] - self:used(m)
end

function World:addDisk(name, mount, capacity, label)
  self.capacity[mount] = capacity or 125000
  self.dirs[mount] = true
  self.drives[#self.drives + 1] = { name = name, mount = mount, label = label }
end

function World:writeFile(p, data)
  p = norm(p)
  local dir = p:match("^(.*)/[^/]*$")
  if dir then self:makeDir(dir) end
  self.files[p] = data
end

function World:makeDir(p)
  p = norm(p)
  local acc = ""
  for part in p:gmatch("[^/]+") do
    acc = acc == "" and part or (acc .. "/" .. part)
    if self.files[acc] then error("/" .. acc .. ": File exists", 0) end
    if not self.dirs[acc] then
      if self:free(acc) < F.MIN_FILE then error("Out of space", 0) end
      self.dirs[acc] = true
    end
  end
end

local function getDir(p)
  p = norm(p)
  if p == "" then return ".." end
  return p:match("^(.*)/[^/]*$") or ""
end

function World:makeFs()
  local w = self
  local fs = {}
  fs.combine = function(a, ...)
    local all = { a, ... }
    return norm(table.concat(all, "/"))
  end
  fs.getDir = getDir
  fs.getName = function(p)
    p = norm(p)
    if p == "" then return "root" end
    return p:match("([^/]+)$")
  end
  fs.exists = function(p) p = norm(p) return w.files[p] ~= nil or w.dirs[p] == true end
  fs.isDir = function(p) return w.dirs[norm(p)] == true end
  fs.list = function(p)
    p = norm(p)
    if not w.dirs[p] then error("/" .. p .. ": Not a directory", 2) end
    local out, seen = {}, {}
    local prefix = p == "" and "" or (p .. "/")
    local function add(q)
      if q:sub(1, #prefix) == prefix and q ~= p then
        local child = q:sub(#prefix + 1):match("^[^/]+")
        if child and not seen[child] then seen[child] = true out[#out + 1] = child end
      end
    end
    for q in pairs(w.files) do add(q) end
    for q in pairs(w.dirs) do if q ~= "" then add(q) end end
    table.sort(out)
    return out
  end
  fs.getSize = function(p)
    p = norm(p)
    if w.files[p] then return #w.files[p] end
    if w.dirs[p] then return 0 end
    error("/" .. p .. ": No such file", 2)
  end
  fs.getFreeSpace = function(p) return w:free(p) end
  fs.getDrive = function(p)
    local m = w:mountOf(p)
    if m == "" then return "hdd" end
    return m
  end
  fs.makeDir = function(p) w:makeDir(p) end
  fs.delete = function(p)
    p = norm(p)
    w.files[p] = nil
    local prefix = p .. "/"
    for q in pairs(w.files) do if q:sub(1, #prefix) == prefix then w.files[q] = nil end end
    for q in pairs(w.dirs) do if q == p or q:sub(1, #prefix) == prefix then w.dirs[q] = nil end end
  end
  fs.move = function(a, b)
    a, b = norm(a), norm(b)
    if fs.exists(b) then error("/" .. b .. ": File exists", 2) end
    if not w.files[a] then error("/" .. a .. ": No such file", 2) end
    w.files[b] = w.files[a]
    w.files[a] = nil
  end
  fs.open = function(p, mode)
    p = norm(p)
    if mode == "r" or mode == "rb" then
      local data = w.files[p]
      if not data then return nil, "/" .. p .. ": No such file" end
      local done = false
      return {
        readAll = function() if done then return nil end done = true return data end,
        close = function() end,
      }
    end
    assert(mode == "w" or mode == "wb", "mode " .. tostring(mode))
    if w.dirs[p] then return nil, "/" .. p .. ": Is a directory" end
    local dir = getDir(p)
    if dir ~= "" and not w.dirs[dir] then
      local ok = pcall(w.makeDir, w, dir)
      if not ok then return nil, "Out of space" end
    end
    if not w.files[p] and w:free(p) < F.MIN_FILE then return nil, "Out of space" end
    w.files[p] = ""
    return {
      write = function(data)
        if w.failWrite and p:find(w.failWrite) then error("Out of space", 0) end
        -- before CC:Tweaked 1.109 a full disk cut writes short without an error
        if w.shortWrite and p:find(w.shortWrite) then data = data:sub(1, math.floor(#data / 2)) end
        local old = w.files[p]
        w.files[p] = old .. data
        if w:free(p) < 0 then
          w.files[p] = old
          error("Out of space", 0)
        end
      end,
      close = function() end,
    }
  end
  return fs
end

---------------------------------------------------------------------------
-- Fake GitHub
---------------------------------------------------------------------------

-- repo = { files = { path = content }, links = { path = target }, submodules = { path },
--          default = "main", refs = { name = sha }, private = bool, truncated = bool,
--          appInstalled = bool (default true) }
function World:addRepo(name, repo)
  repo.default = repo.default or "main"
  repo.refs = repo.refs or { [repo.default] = ("a1b2c3d4"):rep(5) }
  if repo.appInstalled == nil then repo.appInstalled = true end
  self.repos[name] = repo
  return repo
end

local function blobSha(path) -- any stable 40-hex id
  local h = 0
  for i = 1, #path do h = (h * 31 + path:byte(i)) % 4294967296 end
  return ("%08x"):format(h):rep(5)
end

local function urlDecode(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function reply(status, body, headers)
  return { status = status, body = body or "", headers = headers or {} }
end

function World:github(req)
  local url = req.url
  local auth = req.headers and req.headers.Authorization
  local authed = auth == "Bearer " .. F.TOKEN

  if url == "https://github.com/login/device/code" then
    return self:deviceCode(req)
  elseif url == "https://github.com/login/oauth/access_token" then
    return self:deviceToken(req)
  end

  local path = url:match("^https://api%.github%.com(/.*)$")
  if path then
    if self.rateLimited and not authed then
      return reply(403, J.encode({ message = "API rate limit exceeded" }),
        { ["x-ratelimit-remaining"] = "0", ["x-ratelimit-reset"] = tostring(self.epoch / 1000 + 600) })
    end
    local owner, rname, rest = path:match("^/repos/([^/]+)/([^/]+)(.*)$")
    local repo = owner and self.repos[owner .. "/" .. rname]
    if not repo or (repo.private and not (authed and repo.appInstalled)) then
      return reply(404, J.encode({ message = "Not Found" }))
    end
    if rest == "" then
      return reply(200, J.encode({ default_branch = repo.default, private = repo.private == true }))
    end
    local ref = rest:match("^/commits/(.+)$")
    if ref then
      if repo.empty then return reply(409, J.encode({ message = "Git Repository is empty." })) end
      local sha = repo.refs[urlDecode(ref)]
      if not sha then return reply(422, J.encode({ message = "No commit found for SHA: " .. ref })) end
      if req.headers.Accept ~= "application/vnd.github.sha" then return reply(415, "") end
      return reply(200, sha)
    end
    local treeSha, query = rest:match("^/git/trees/(%x+)(.*)$")
    if treeSha and (query == "" or query == "?recursive=1") then
      local tree, dirs = {}, {}
      local function addDirs(p)
        local d = p:match("^(.*)/[^/]*$")
        while d and not dirs[d] do
          dirs[d] = true
          tree[#tree + 1] = { path = d, mode = "040000", type = "tree", sha = blobSha(d) }
          d = d:match("^(.*)/[^/]*$")
        end
      end
      local paths = {}
      for p in pairs(repo.files) do paths[#paths + 1] = p end
      table.sort(paths)
      for _, p in ipairs(paths) do
        addDirs(p)
        tree[#tree + 1] = { path = p, mode = "100644", type = "blob", sha = blobSha(p), size = #repo.files[p] }
      end
      for p, target in pairs(repo.links or {}) do
        tree[#tree + 1] = { path = p, mode = "120000", type = "blob", sha = blobSha(p), size = #target }
      end
      for _, p in ipairs(repo.submodules or {}) do
        tree[#tree + 1] = { path = p, mode = "160000", type = "commit", sha = blobSha(p) }
      end
      for _, p in ipairs(repo.extraPaths or {}) do
        tree[#tree + 1] = { path = p, mode = "100644", type = "blob", sha = blobSha(p), size = 1 }
      end
      -- which folder the sha names: the commit (the root) or a folder
      local base
      for _, sha in pairs(repo.refs) do if sha == treeSha then base = "" end end
      for d in pairs(dirs) do if blobSha(d) == treeSha then base = d end end
      if not base then return reply(404, J.encode({ message = "Not Found" })) end
      self.treeRequests = (self.treeRequests or 0) + 1
      local listed = {}
      local prefix = base == "" and "" or (base .. "/")
      for _, e in ipairs(tree) do
        if e.path:sub(1, #prefix) == prefix and e.path ~= base then
          local rel = e.path:sub(#prefix + 1)
          if query ~= "" or not rel:find("/", 1, true) then
            listed[#listed + 1] = { path = rel, mode = e.mode, type = e.type, sha = e.sha, size = e.size }
          end
        end
      end
      tree = listed
      if #tree == 0 then tree = nil end
      local body = J.encode({ sha = treeSha, tree = tree or {}, truncated = repo.truncated == true })
      if not tree then body = body:gsub('"tree":{}', '"tree":[]') end
      return reply(200, body)
    end
    local blob = rest:match("^/git/blobs/(%x+)$")
    if blob then
      if req.headers.Accept ~= "application/vnd.github.raw+json" then return reply(415, "") end
      for p, data in pairs(repo.files) do
        if blobSha(p) == blob then return reply(200, data) end
      end
      return reply(404, J.encode({ message = "Not Found" }))
    end
    return reply(404, J.encode({ message = "Not Found" }))
  end

  local owner, rname, sha, file = url:match("^https://raw%.githubusercontent%.com/([^/]+)/([^/]+)/(%x+)/(.+)$")
  if owner then
    local repo = self.repos[owner .. "/" .. rname]
    if auth then return reply(400, "the token must never go to raw.githubusercontent.com") end
    if not repo or repo.private then return reply(404, "404: Not Found") end
    local data = repo.files[urlDecode(file)]
    if not data then return reply(404, "404: Not Found") end
    if self.cutShort and urlDecode(file) == self.cutShort then data = data:sub(1, -2) end
    return reply(200, data)
  end
  if self.selfUpdate and url == "https://raw.githubusercontent.com/Andriesmenze/ComputerCraft-GitGet/main/programs/gitget.lua" then
    return reply(200, self.selfUpdate)
  end
  return nil, "Could not connect"
end

-- Device flow: script = { "authorization_pending", "slow_down", "token" } (one per poll),
-- or a first entry "denied_code" to refuse the device code request.
function World:deviceFlow(script)
  self.device = { script = script, polls = 0 }
end

function World:deviceCode(req)
  if not self.device then return reply(404, "") end
  if self.device.codeStatus then return reply(self.device.codeStatus, "<!DOCTYPE html>") end
  if not req.body:find("client_id=" .. F.CLIENT_ID:gsub("%p", "%%%0"), 1) then
    return reply(200, J.encode({ error = "incorrect_client_credentials" }))
  end
  return reply(200, J.encode({
    device_code = "dev123", user_code = "ABCD-1234", verification_uri = "https://github.com/login/device",
    expires_in = 900, interval = 5,
  }))
end

function World:deviceToken(req)
  local d = self.device
  d.polls = d.polls + 1
  local step = d.script[d.polls] or "expired_token"
  if not req.body:find("device_code=dev123", 1, true)
    or not req.body:find("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code", 1, true) then
    return reply(200, J.encode({ error = "unsupported_grant_type" }))
  end
  if step == "token" then
    return reply(200, J.encode({ access_token = F.TOKEN, token_type = "bearer", scope = "", expires_in = 28800 }))
  elseif step == "slow_down" then
    return reply(200, J.encode({ error = "slow_down", interval = 10 }))
  end
  return reply(200, J.encode({ error = step }))
end

---------------------------------------------------------------------------
-- Environment
---------------------------------------------------------------------------

function World:makeHttp()
  local w = self
  local function handle(res)
    return {
      readAll = function() return res.body end,
      close = function() end,
      getResponseCode = function() return res.status end,
      getResponseHeaders = function() return res.headers end,
    }
  end
  local function call(method, req)
    if type(req) ~= "table" then req = { url = req } end
    local copy = {}
    for k, v in pairs(req.headers or {}) do copy[k] = v end
    w.requests[#w.requests + 1] = { method = method, url = req.url, headers = copy, body = req.body, binary = req.binary }
    local res, err = w:github({ url = req.url, headers = copy, body = req.body or "" })
    if not res then return nil, err end
    if res.status >= 200 and res.status < 300 then return handle(res) end
    return nil, "HTTP " .. res.status, handle(res)
  end
  return {
    get = function(req) return call("GET", req) end,
    post = function(req) return call("POST", req) end,
  }
end

function World:env(args)
  local w = self
  local out = {}
  local function write(s)
    s = tostring(s)
    w.out[#w.out + 1] = s
  end
  local function print(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    write(table.concat(parts, "\t") .. "\n")
  end
  local term = {
    getSize = function() return 51, 19 end,
    getCursorPos = function() return 1, 1 end,
    setCursorPos = function() end,
    clearLine = function() write("\r") end,
    clear = function() write("\f") end,
    isColour = function() return true end,
    setTextColour = function() end,
  }
  local env = {
    print = print, write = write,
    printError = function(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
      w.errors[#w.errors + 1] = table.concat(parts, "\t")
      print(...)
    end,
    read = function()
      if #w.answers == 0 then error("read() was called with no answer left", 0) end
      local a = table.remove(w.answers, 1)
      write(a .. "\n")
      return a
    end,
    term = term,
    colours = { white = 1, yellow = 16, lightBlue = 8, lime = 32 },
    fs = self:makeFs(),
    http = not self.httpOff and self:makeHttp() or nil,
    textutils = { unserialiseJSON = J.decode, unserializeJSON = J.decode },
    os = {
      sleep = function(n) w.sleeps[#w.sleeps + 1] = n end,
      epoch = function() return w.epoch end,
    },
    peripheral = {
      getNames = function()
        local names = {}
        for _, d in ipairs(w.drives) do names[#names + 1] = d.name end
        return names
      end,
      getType = function(name)
        for _, d in ipairs(w.drives) do if d.name == name then return "drive" end end
        return nil
      end,
    },
    disk = {
      hasData = function(name) for _, d in ipairs(w.drives) do if d.name == name then return true end end return false end,
      getMountPath = function(name) for _, d in ipairs(w.drives) do if d.name == name then return d.mount end end return nil end,
      getLabel = function(name) for _, d in ipairs(w.drives) do if d.name == name then return d.label end end return nil end,
    },
    shell = {
      resolve = function(p) return norm(w.cwd .. "/" .. p) end,
      getRunningProgram = function() return w.program end,
    },
    -- the Lua standard library, as Cobalt has it
    string = string, table = table, math = math,
    pairs = pairs, ipairs = ipairs, next = next, select = select, type = type,
    tostring = tostring, tonumber = tonumber, pcall = pcall, error = error,
    setmetatable = setmetatable, getmetatable = getmetatable, unpack = unpack,
    rawget = rawget, rawset = rawset, rawequal = rawequal,
  }
  env._G = env
  return env
end

-- Runs gitget with the given arguments. Returns the output and, when the
-- program raised (a bug, not a printed problem), the error.
function World:run(...)
  local fn = assert(loadfile(REPO .. "/programs/gitget.lua"))
  setfenv(fn, self:env())
  local before = #self.out
  local ok, err = pcall(fn, ...)
  local text = table.concat(self.out, "", before + 1)
  return text, (not ok) and tostring(err) or nil
end

function World:errorText()
  return table.concat(self.errors, "\n")
end

-- Every request that carried an Authorization header.
function World:authed()
  local list = {}
  for _, r in ipairs(self.requests) do
    if r.headers.Authorization then list[#list + 1] = r end
  end
  return list
end

F.blobSha = blobSha
return F
