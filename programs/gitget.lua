-- GitGet: downloads a GitHub repository, or one folder or file of it, onto this
-- computer or a floppy disk. Public repositories need nothing. Private ones use
-- a GitHub device login on every run: the token stays in memory and is never
-- stored.
--
-- Usage:
--   gitget get <owner>/<repo>[@ref][:path] [target] [--disk] [--login] [--force] [--client-id <id>]
--   gitget update
--   gitget help
--
-- https://github.com/Andriesmenze/ComputerCraft-GitGet

local VERSION = "1.0.0"
local SELF_URL = "https://raw.githubusercontent.com/Andriesmenze/ComputerCraft-GitGet/main/programs/gitget.lua"
local SELF_MARK = "-- GitGet: "
local API = "https://api.github.com"
local RAW = "https://raw.githubusercontent.com"
local LOGIN = "https://github.com/login"
-- The GitHub App that private downloads log in through (see README.md, "Your
-- own GitHub App"). A client ID is public; the device flow needs no secret.
local CLIENT_ID = "Iv23liEghrx81amcdhOG"
local APP_URL = "https://github.com/apps/gitget-for-computercraft"
-- CC:Tweaked counts at least 500 bytes for every file and folder.
local MIN_FILE = 500

local function usage()
  print("Usage:")
  print("  gitget get <owner>/<repo>[@ref][:path] [target]")
  print("      [--disk] [--login] [--force] [--client-id <id>]")
  print("  gitget update")
  print("")
  print("--disk   save to a floppy disk")
  print("--login  log in to GitHub first (private repos)")
  print("--force  overwrite without asking")
  print("Example: gitget get Andriesmenze/ComputerCraft-NTP")
end

-- An expected problem: main shows its message, without a stack trace.
local Stop = {}
local function stop(msg)
  error(setmetatable({ msg = msg }, Stop), 0)
end

local function colourPrint(colour, text)
  local coloured = term.isColour and term.isColour()
  if coloured then term.setTextColour(colour) end
  print(text)
  if coloured then term.setTextColour(colours.white) end
end

local function ask(question)
  write(question .. " ")
  local answer = read() or ""
  return answer:sub(1, 1):lower() == "y"
end

local function kb(bytes)
  return tostring(math.ceil(bytes / 1024)) .. " KB"
end

-- Percent-encodes everything but unreserved characters and "/".
local function encodePath(path)
  return (path:gsub("[^%w%-%._~/]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local function encodeForm(fields)
  local parts = {}
  for _, field in ipairs(fields) do
    parts[#parts + 1] = field[1] .. "=" .. encodePath(field[2]):gsub("/", "%%2F")
  end
  return table.concat(parts, "&")
end

local function header(headers, name)
  if not headers then return nil end
  name = name:lower()
  for k, v in pairs(headers) do
    if type(k) == "string" and k:lower() == name then return v end
  end
  return nil
end

---------------------------------------------------------------------------
-- HTTP
---------------------------------------------------------------------------

-- Makes one request and returns { status, body, headers, err }. The token is
-- only ever sent to api.github.com.
local function request(url, opts)
  opts = opts or {}
  local headers = { ["User-Agent"] = "gitget-cc/" .. VERSION }
  if url:sub(1, #API + 1) == API .. "/" then
    headers["X-GitHub-Api-Version"] = "2022-11-28"
    headers.Accept = "application/vnd.github+json"
    if opts.token then headers.Authorization = "Bearer " .. opts.token end
  end
  if opts.accept then headers.Accept = opts.accept end
  local req = { url = url, headers = headers, binary = opts.binary }
  local called, response, err, failed
  if opts.body then
    headers["Content-Type"] = "application/x-www-form-urlencoded"
    req.body = opts.body
    called, response, err, failed = pcall(http.post, req)
  else
    called, response, err, failed = pcall(http.get, req)
  end
  if not called then
    return { err = tostring(response) }
  end
  local handle = response or failed
  if not handle then
    return { err = err or "no response" }
  end
  local result = {
    status = handle.getResponseCode and handle.getResponseCode() or (response and 200),
    headers = handle.getResponseHeaders and handle.getResponseHeaders() or {},
    body = handle.readAll() or "",
    err = err,
  }
  handle.close()
  return result
end

local function decode(body)
  if type(body) ~= "string" then return nil end
  local ok, data = pcall(textutils.unserialiseJSON, body, { parse_empty_array = false })
  if ok and type(data) == "table" then return data end
  return nil
end

-- A sentence about a failed request.
local function describe(res)
  if not res.status then
    return "no answer (" .. tostring(res.err) .. ")"
  end
  if (res.status == 403 or res.status == 429) and header(res.headers, "x-ratelimit-remaining") == "0" then
    local reset = tonumber(header(res.headers, "x-ratelimit-reset"))
    local wait = ""
    if reset then
      wait = " It resets in about " .. tostring(math.max(1, math.ceil((reset - os.epoch("utc") / 1000) / 60))) .. " minutes."
    end
    return "GitHub's rate limit is used up (60 requests an hour without logging in; --login raises it)." .. wait
  end
  local data = decode(res.body)
  local message = data and type(data.message) == "string" and (": " .. data.message) or ""
  return "HTTP " .. tostring(res.status) .. message
end

---------------------------------------------------------------------------
-- Device login
---------------------------------------------------------------------------

-- Logs in with GitHub's device flow and returns the access token. The token is
-- never printed or written anywhere.
local function deviceLogin(clientId)
  if not clientId or clientId == "" then
    stop("This copy of GitGet has no GitHub App to log in with. Pass --client-id <id> (see the README).")
  end
  local res = request(LOGIN .. "/device/code", {
    body = encodeForm({ { "client_id", clientId } }),
    accept = "application/json",
  })
  local data = res.status == 200 and decode(res.body)
  if not data or data.error or not data.device_code then
    if data and data.error == "device_flow_disabled" then
      stop("Device login is turned off for this GitHub App (enable it in the app's settings).")
    end
    if res.status and res.status >= 500 then
      stop("GitHub's login service had a problem (HTTP " .. res.status .. "). Try again in a few minutes.")
    end
    stop("GitHub refused the login: " .. (data and tostring(data.error_description or data.error) or describe(res)))
  end

  term.clear()
  term.setCursorPos(1, 1)
  colourPrint(colours.yellow, "Log in to GitHub")
  print("")
  print("1. On your phone or PC, open")
  colourPrint(colours.lightBlue, "   " .. tostring(data.verification_uri))
  print("2. Enter this code:")
  print("")
  colourPrint(colours.yellow, "   " .. tostring(data.user_code))
  print("")
  print("3. Approve GitGet.")
  print("")
  print("Waiting... (hold Ctrl+T to cancel)")

  local interval = tonumber(data.interval) or 5
  local poll = encodeForm({
    { "client_id", clientId },
    { "device_code", data.device_code },
    { "grant_type", "urn:ietf:params:oauth:grant-type:device_code" },
  })
  while true do
    os.sleep(interval)
    local answer = request(LOGIN .. "/oauth/access_token", { body = poll, accept = "application/json" })
    local result = answer.status == 200 and decode(answer.body)
    if result and type(result.access_token) == "string" and result.access_token ~= "" then
      colourPrint(colours.lime, "Logged in.")
      return result.access_token
    elseif result and result.error == "authorization_pending" then
      -- keep waiting
    elseif result and result.error == "slow_down" then
      interval = tonumber(result.interval) or (interval + 5)
    elseif result and result.error == "expired_token" then
      stop("The code expired before it was approved. Run the command again for a new code.")
    elseif result and result.error == "access_denied" then
      stop("The login was cancelled on GitHub.")
    elseif result and result.error then
      stop("Login failed: " .. tostring(result.error_description or result.error))
    elseif not answer.status then
      -- a dropped connection: try again at the next interval
    else
      stop("Login failed: " .. describe(answer))
    end
  end
end

---------------------------------------------------------------------------
-- Repository
---------------------------------------------------------------------------

-- Reads "owner/repo[@ref][:path]" (a github.com URL also works).
local function parseSpec(s)
  s = s:gsub("^https?://", ""):gsub("^github%.com/", "")
  local owner, repo, rest = s:match("^([%w%-%._]+)/([%w%-%._]+)(.*)$")
  if not owner then return nil end
  local plainRepo = repo:gsub("%.git$", "")
  repo = plainRepo
  local ref, path
  if rest:sub(1, 1) == "@" then
    ref, rest = rest:match("^@([^:]+)(.*)$")
    if not ref then return nil end
  end
  if rest:sub(1, 1) == ":" then
    path = rest:sub(2)
  elseif rest ~= "" then
    return nil
  end
  path = (path or ""):gsub("^/+", ""):gsub("/+$", "")
  return { owner = owner, repo = repo, ref = ref, path = path }
end

-- Fetches the repository, the commit the ref points at, and its file tree.
-- Returns the info, or nil, the failed response and which step failed.
local function fetchRepo(spec, token)
  local base = API .. "/repos/" .. spec.owner .. "/" .. spec.repo
  local res = request(base, { token = token })
  if res.status ~= 200 then return nil, res, "repo" end
  local repoInfo = decode(res.body)
  if not repoInfo then return nil, res, "repo" end
  local ref = spec.ref or repoInfo.default_branch
  if type(ref) ~= "string" then return nil, res, "empty" end

  res = request(base .. "/commits/" .. encodePath(ref), { token = token, accept = "application/vnd.github.sha" })
  if res.status == 409 then return nil, res, "empty" end
  if res.status ~= 200 then return nil, res, "ref" end
  local sha = res.body:match("^%s*(%x+)%s*$")
  if not sha or (#sha ~= 40 and #sha ~= 64) then return nil, res, "ref" end

  -- For a :path, walk down one folder at a time and list only that part, so a
  -- folder of a big repository doesn't need the whole repository's tree.
  local treeSha, prefix = sha, ""
  for part in spec.path:gmatch("[^/]+") do
    res = request(base .. "/git/trees/" .. treeSha, { token = token })
    local level = res.status == 200 and decode(res.body)
    if not level or type(level.tree) ~= "table" then return nil, res, "tree" end
    local found
    for _, entry in ipairs(level.tree) do
      if entry.path == part then found = entry end
    end
    local here = prefix == "" and part or (prefix .. "/" .. part)
    if not found or (found.type ~= "tree" and here ~= spec.path) then
      return { ref = ref, sha = sha, tree = {} }
    end
    if found.type ~= "tree" then
      found.path = here
      return { ref = ref, sha = sha, tree = { found } }
    end
    treeSha, prefix = found.sha, here
  end

  res = request(base .. "/git/trees/" .. treeSha .. "?recursive=1", { token = token })
  local tree = res.status == 200 and decode(res.body)
  if not tree or type(tree.tree) ~= "table" then return nil, res, "tree" end
  if prefix ~= "" then
    for _, entry in ipairs(tree.tree) do
      if type(entry.path) == "string" then entry.path = prefix .. "/" .. entry.path end
    end
  end
  return { ref = ref, sha = sha, tree = tree.tree, truncated = tree.truncated == true }
end

-- Characters CC:Tweaked does not allow in file names.
local BAD_NAME = '[%c"%*:<>%?|\\]'

-- Whether a path from the tree is safe to write under the target.
local function safePath(rel)
  if rel == "" or rel:sub(1, 1) == "/" then return false end
  for part in (rel .. "/"):gmatch("([^/]*)/") do
    if part == "" or part == "." or part == ".." then return false end
  end
  return true
end

-- Picks the files to download: everything under spec.path, with that prefix
-- removed. A path that names a single file selects just that file.
local function selectFiles(spec, tree)
  local files, skipped = {}, { links = 0, submodules = 0, names = {} }
  local prefix = spec.path
  local single = false
  for _, entry in ipairs(tree) do
    local rel
    if type(entry.path) ~= "string" then
      rel = nil
    elseif prefix == "" then
      rel = entry.path
    elseif entry.path == prefix and entry.type == "blob" then
      rel = entry.path:match("([^/]+)$")
      single = true
    elseif entry.path:sub(1, #prefix + 1) == prefix .. "/" then
      rel = entry.path:sub(#prefix + 2)
    end
    if rel then
      if entry.type == "commit" then
        skipped.submodules = skipped.submodules + 1
      elseif entry.type == "blob" and entry.mode == "120000" then
        skipped.links = skipped.links + 1
      elseif entry.type == "blob" then
        if not safePath(rel) then
          stop("The repository has a file with an unsafe path (" .. entry.path .. "); nothing was downloaded.")
        end
        if rel:find(BAD_NAME) then
          skipped.names[#skipped.names + 1] = entry.path
        else
          files[#files + 1] = { path = entry.path, rel = rel, sha = entry.sha, size = tonumber(entry.size) or 0 }
        end
      end
    end
  end
  return files, skipped, single
end

---------------------------------------------------------------------------
-- Disks and space
---------------------------------------------------------------------------

local function listDisks()
  local found = {}
  for _, name in ipairs(peripheral.getNames()) do
    if peripheral.getType(name) == "drive" and disk.hasData(name) then
      local mount = disk.getMountPath(name)
      if mount then
        found[#found + 1] = { name = name, mount = mount, label = disk.getLabel(name) }
      end
    end
  end
  table.sort(found, function(a, b) return a.mount < b.mount end)
  return found
end

local function chooseDisk()
  local found = listDisks()
  if #found == 0 then
    stop("No disk found. Put a floppy disk in a disk drive next to this computer.")
  end
  if #found == 1 then return found[1].mount end
  print("Which disk?")
  for i, d in ipairs(found) do
    local free = fs.getFreeSpace(d.mount)
    local label = d.label and (" \"" .. d.label .. "\"") or ""
    print(i .. ". /" .. d.mount .. label .. (type(free) == "number" and (", " .. kb(free) .. " free") or ""))
  end
  write("Number: ")
  local choice = found[tonumber(read() or "")]
  if not choice then stop("No disk chosen; nothing was downloaded.") end
  return choice.mount
end

-- The nearest folder of path that exists.
local function existingParent(path)
  while path ~= "" and not fs.exists(path) do
    path = fs.getDir(path)
    if path == ".." then return "" end
  end
  return path
end

-- Checks every destination before anything is written: no folder in the way of
-- a file, no file in the way of a folder, and enough free space. The estimate
-- counts CC's 500-byte minimum per file and folder, and room for the checked
-- copy of the largest file.
local function checkTarget(target, files)
  local need, biggest, newDirs = 0, 0, {}
  for _, f in ipairs(files) do
    local dest = fs.combine(target, f.rel)
    if fs.isDir(dest) then
      stop("/" .. dest .. " is a folder, but the repository has a file there; nothing was downloaded.")
    end
    local size = math.max(f.size, MIN_FILE)
    need = need + size
    if fs.exists(dest) then
      need = need - math.max(fs.getSize(dest), MIN_FILE)
    end
    biggest = math.max(biggest, size)
    local dir = fs.getDir(dest)
    while dir ~= "" and dir ~= ".." and not newDirs[dir] do
      if fs.exists(dir) then
        if not fs.isDir(dir) then
          stop("/" .. dir .. " is a file, but the repository has a folder there; nothing was downloaded.")
        end
        break
      end
      newDirs[dir] = true
      need = need + MIN_FILE
      dir = fs.getDir(dir)
    end
  end
  need = need + biggest
  local parent = existingParent(target)
  local free = fs.getFreeSpace(parent)
  if type(free) == "number" and free ~= math.huge and need > free then
    local drive = fs.getDrive(parent) or "this computer"
    stop("Not enough space on " .. drive .. ": this needs about " .. kb(need) .. " and " .. kb(free) .. " is free. Nothing was downloaded.")
  end
end

local function readFile(path)
  local f = fs.open(path, "rb")
  if not f then return nil end
  local data = f.readAll() or ""
  f.close()
  return data
end

-- Writes data to path through a checked copy: path .. ".gitget-new" is written
-- and read back, then moved into place. When anything fails the old file is
-- left as it was. Returns true, or false and a message.
local function writeChecked(path, data)
  local tmp = path .. ".gitget-new"
  local ok, err = pcall(function()
    local dir = fs.getDir(path)
    if dir ~= "" and dir ~= ".." and not fs.exists(dir) then fs.makeDir(dir) end
    if fs.exists(tmp) then fs.delete(tmp) end
    local f, openErr = fs.open(tmp, "wb")
    if not f then error(openErr or "Out of space", 0) end
    local written, writeErr = pcall(f.write, data)
    local closed, closeErr = pcall(f.close)
    if not written or not closed then error(written and closeErr or writeErr, 0) end
    if readFile(tmp) ~= data then error("Out of space", 0) end
    if fs.exists(path) then fs.delete(path) end
    fs.move(tmp, path)
  end)
  if not ok then
    pcall(fs.delete, tmp)
    return false, tostring(err)
  end
  return true
end

local function progress(text)
  local width = term.getSize()
  local _, y = term.getCursorPos()
  term.setCursorPos(1, y)
  term.clearLine()
  write(text:sub(1, width))
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

local function get(args)
  local specText, targetArg
  local useDisk, login, force, clientId = false, false, false, CLIENT_ID
  local i = 2
  while i <= #args do
    local a = args[i]
    if a == "--disk" then useDisk = true
    elseif a == "--login" then login = true
    elseif a == "--force" then force = true
    elseif a == "--client-id" then
      i = i + 1
      clientId = args[i]
      if not clientId then stop("--client-id needs a value.") end
    elseif a:sub(1, 2) == "--" then stop("Unknown option " .. a .. ". Run gitget help.")
    elseif not specText then specText = a
    elseif not targetArg then targetArg = a
    else stop("Too many arguments. Run gitget help.") end
    i = i + 1
  end
  if not specText then
    usage()
    return
  end
  local spec = parseSpec(specText)
  if not spec then
    stop("Can't read " .. specText .. ". Use owner/repo, owner/repo@ref or owner/repo:folder.")
  end
  local name = spec.owner .. "/" .. spec.repo

  local token
  if login then token = deviceLogin(clientId) end
  print("Looking up " .. name .. "...")
  local info, res, step = fetchRepo(spec, token)
  if not info and step == "repo" and res.status == 404 and not token then
    print("GitHub can't find " .. name .. ": it doesn't exist, or it is private.")
    if not ask("Log in to GitHub and try again? (y/n)") then
      stop("Nothing was downloaded.")
    end
    token = deviceLogin(clientId)
    print("Looking up " .. name .. "...")
    info, res, step = fetchRepo(spec, token)
  end
  if not info then
    if step == "repo" and res.status == 404 then
      stop("GitHub still can't find " .. name .. ". Check the name, and that the GitGet app is installed on it: " .. APP_URL .. "/installations/new")
    elseif step == "empty" then
      stop(name .. " is empty.")
    elseif step == "ref" and (res.status == 404 or res.status == 422) then
      stop(name .. " has no branch, tag or commit called " .. tostring(spec.ref) .. ".")
    end
    stop("Can't read " .. name .. ": " .. describe(res))
  end
  if info.truncated then
    stop(name .. " is too big for GitHub to list in one go. Download one folder at a time with " .. name .. ":<folder>.")
  end

  local files, skipped, single = selectFiles(spec, info.tree)
  if #files == 0 then
    if spec.path ~= "" then stop(name .. " has no file or folder called " .. spec.path .. " at " .. info.ref .. ".") end
    stop(name .. " has no files to download.")
  end

  -- Where the files go.
  local targetName = targetArg
  if not targetName then
    if single then targetName = files[1].rel
    elseif spec.path ~= "" then targetName = spec.path:match("([^/]+)$")
    else targetName = spec.repo end
  end
  local target
  if useDisk then
    target = fs.combine(chooseDisk(), targetName)
  else
    target = shell.resolve(targetName)
  end
  if single then
    -- the target is the file itself
    files[1].rel = fs.getName(target)
    target = fs.getDir(target)
    if target == ".." then target = "" end
    local dest = fs.combine(target, files[1].rel)
    if fs.exists(dest) and not fs.isDir(dest) and not force then
      if not ask("/" .. dest .. " already exists. Replace it? (y/n)") then stop("Nothing was downloaded.") end
    end
  elseif fs.exists(target) then
    if not fs.isDir(target) then
      stop("/" .. target .. " is a file. Choose another target.")
    end
    if #fs.list(target) > 0 and not force then
      if not ask("/" .. target .. " is not empty. Files with the same name get replaced. Go on? (y/n)") then
        stop("Nothing was downloaded.")
      end
    end
  end
  checkTarget(target, files)

  -- Download, pinned to one commit.
  local total = 0
  for n, f in ipairs(files) do
    progress("[" .. n .. "/" .. #files .. "] " .. f.path)
    local body
    if token then
      body = request(API .. "/repos/" .. name .. "/git/blobs/" .. f.sha,
        { token = token, accept = "application/vnd.github.raw+json", binary = true })
    else
      body = request(RAW .. "/" .. name .. "/" .. info.sha .. "/" .. encodePath(f.path), { binary = true })
    end
    if body.status ~= 200 or #body.body ~= f.size then
      print("")
      local why = body.status ~= 200 and describe(body) or "the download was cut short"
      stop("Can't download " .. f.path .. ": " .. why .. ". " .. (n - 1) .. " of " .. #files .. " files were saved; run the command again to finish.")
    end
    local ok, err = writeChecked(fs.combine(target, f.rel), body.body)
    if not ok then
      print("")
      stop("Can't save /" .. fs.combine(target, f.rel) .. ": " .. err .. ". " .. (n - 1) .. " of " .. #files .. " files were saved.")
    end
    total = total + f.size
  end
  token = nil
  progress("")

  local where = single and ("/" .. fs.combine(target, files[1].rel)) or ("/" .. target)
  colourPrint(colours.lime, "Downloaded " .. #files .. (#files == 1 and " file" or " files") .. " (" .. kb(total) .. ") to " .. where)
  print("from " .. name .. "@" .. info.ref .. " (" .. info.sha:sub(1, 7) .. ")")
  if skipped.links > 0 then print("Skipped " .. skipped.links .. " symbolic link(s).") end
  if skipped.submodules > 0 then print("Skipped " .. skipped.submodules .. " submodule(s); get those with gitget too.") end
  if #skipped.names > 0 then
    print("Skipped " .. #skipped.names .. " file(s) with names CC can't save, such as " .. skipped.names[1])
  end
end

local function update()
  print("Downloading the latest GitGet...")
  local res = request(SELF_URL, { binary = true })
  if res.status ~= 200 then stop("Can't download GitGet: " .. describe(res)) end
  if res.body:sub(1, #SELF_MARK) ~= SELF_MARK then stop("The download is not GitGet; nothing was changed.") end
  local path = shell.getRunningProgram()
  if not path or path:sub(1, 4) == "rom/" or not fs.exists(path) then path = "gitget.lua" end
  local ok, err = writeChecked(path, res.body)
  if not ok then stop("Can't save /" .. path .. ": " .. err) end
  local version = res.body:match('local VERSION = "([^"]+)"') or "?"
  colourPrint(colours.lime, "GitGet " .. version .. " saved to /" .. path .. ".")
end

local function main(...)
  local args = { ... }
  local command = args[1]
  if command ~= "get" and command ~= "update" then
    usage()
    return
  end
  if not http then
    print("The http API is turned off in the CC: Tweaked configuration, so GitGet can't download anything.")
    return
  end
  local ok, err = pcall(function()
    if command == "get" then get(args) else update() end
  end)
  if not ok then
    if type(err) == "table" and getmetatable(err) == Stop then
      printError(err.msg)
    else
      error(err, 0)
    end
  end
end

main(...)
