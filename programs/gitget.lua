-- GitGet: downloads a GitHub repository, or one folder or file of it, onto this
-- computer or a floppy disk. Public repositories need nothing. Private ones use
-- a GitHub device login. The token stays in the computer's memory until it
-- restarts, so later downloads need no new login. `gitget login --save` also
-- saves it, encrypted with a passphrase, until it expires.
--
-- Usage:
--   gitget get <owner>/<repo>[@ref][:path] [target] [--disk] [--login] [--force] [--client-id <id>]
--   gitget login [--save] [--client-id <id>]
--   gitget logout
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
-- Loads the bundled xEncrypt (defined at the end of this file).
local loadXEncrypt

local function usage()
  print("Usage:")
  print("  gitget get <owner>/<repo>[@ref][:path] [target]")
  print("      [--disk] [--login] [--force] [--client-id <id>]")
  print("  gitget login [--save] [--client-id <id>]")
  print("  gitget logout")
  print("  gitget update")
  print("")
  print("--disk   save to a floppy disk")
  print("--login  log in to GitHub first (private repos)")
  print("--force  overwrite without asking")
  print("--save   also save the login to a file, encrypted")
  print("Example: gitget get octocat/Spoon-Knife")
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

-- Logs in with GitHub's device flow and returns the access token and how many
-- seconds it lasts. The token is never printed or written to a file.
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
      local expiresIn = tonumber(result.expires_in)
      if not expiresIn or expiresIn > 28800 then expiresIn = 28800 end
      return result.access_token, expiresIn
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

---------------------------------------------------------------------------
-- Kept and saved logins
---------------------------------------------------------------------------

-- A login is kept in _G, which every program on this computer shares until it
-- shuts down or restarts. Keep it until five minutes before GitHub expires the
-- token (8 hours for a GitHub App).
local MEMORY = "gitget_login"
local MARGIN = 300
-- `gitget login --save` also writes it to this file until then, encrypted with
-- a key derived from a passphrase.
local SAVED = ".gitget_login"
local ITERATIONS = 2000
local MIN_PASSPHRASE = 8

local function keep(clientId, token, expires)
  _G[MEMORY] = { clientId = clientId, token = token, expires = expires }
end

local function forget()
  _G[MEMORY] = nil
end

local function kept(clientId)
  local k = _G[MEMORY]
  if type(k) == "table" and k.clientId == clientId and type(k.token) == "string"
    and type(k.expires) == "number" and os.epoch("utc") < k.expires then
    return k
  end
  forget()
  return nil
end

local function timeLeft(expires)
  local minutes = math.max(0, math.floor((expires - os.epoch("utc")) / 60000))
  if minutes >= 120 then return tostring(math.floor(minutes / 60)) .. " hours" end
  return tostring(minutes) .. " minutes"
end

-- The saved login, or nil when there is none or it is damaged.
local function readSaved()
  if not fs.exists(SAVED) or fs.isDir(SAVED) then return nil end
  local data = decode(readFile(SAVED))
  if not data or data.version ~= 1 or type(data.clientId) ~= "string" or type(data.salt) ~= "string"
    or type(data.token) ~= "string" or type(data.expires) ~= "string" or not tonumber(data.expires)
    or type(data.iterations) ~= "number" or data.iterations < 1 or data.iterations > 5000
    or data.iterations % 1 ~= 0 then
    return nil
  end
  return data
end

-- Authenticated along with the token, so a changed app or expiry stops it
-- from decrypting.
local function savedAad(data)
  return "gitget login|" .. data.clientId .. "|" .. data.expires
end

local function deleteSaved()
  if fs.exists(SAVED) then fs.delete(SAVED) end
end

-- Asks for the passphrase of a saved login for this app and returns its token.
local function unlockSaved(clientId)
  local data = readSaved()
  if not data or data.clientId ~= clientId then return nil end
  local expires = tonumber(data.expires)
  if os.epoch("utc") >= expires then
    deleteSaved()
    print("Your saved GitHub login has expired, so GitGet deleted it.")
    return nil
  end
  local crypto = loadXEncrypt()
  for _ = 1, 3 do
    write("Passphrase of your saved GitHub login (Enter to skip): ")
    local passphrase = read("*") or ""
    if passphrase == "" then return nil end
    print("Unlocking...")
    local key = crypto.deriveKey(passphrase, data.salt, data.iterations)
    local token = crypto.decrypt(key, data.token, savedAad(data))
    if token then
      keep(clientId, token, expires)
      print("Using your saved login (gitget logout deletes it).")
      return token
    end
    printError("Wrong passphrase.")
  end
  return nil
end

-- The token of a kept or saved login, or nil.
local function remembered(clientId)
  local k = kept(clientId)
  if k then
    print("Using your login from earlier (gitget logout forgets it).")
    return k.token
  end
  return unlockSaved(clientId)
end

local function freshLogin(clientId)
  local token, expiresIn = deviceLogin(clientId)
  keep(clientId, token, os.epoch("utc") + (expiresIn - MARGIN) * 1000)
  print("GitGet keeps this login until the computer restarts (gitget logout forgets it).")
  return token
end

-- Forgets the login for this app everywhere, after GitHub rejected it.
local function dropLogin(clientId)
  forget()
  local data = readSaved()
  if data and data.clientId == clientId then deleteSaved() end
end

local function saveLogin(clientId)
  local k = kept(clientId)
  print("")
  colourPrint(colours.yellow, "Only save your login on a single-player world or on a server whose operators you trust.")
  print("The file is encrypted with your passphrase, but whoever can copy it (server operators, programs on this computer) can try to guess the passphrase on a fast PC. Use a long one that you use nowhere else.")
  if not ask("Save the login for the next " .. timeLeft(k.expires) .. "? (y/n)") then
    stop("Nothing was saved. The login stays in memory until the computer restarts.")
  end
  write("Passphrase (at least " .. MIN_PASSPHRASE .. " characters): ")
  local passphrase = read("*") or ""
  if #passphrase < MIN_PASSPHRASE then stop("That passphrase is too short. Nothing was saved.") end
  write("Type it again: ")
  if (read("*") or "") ~= passphrase then stop("The passphrases differ. Nothing was saved.") end
  print("Encrypting...")
  local crypto = loadXEncrypt()
  local data = {
    version = 1,
    clientId = clientId,
    expires = string.format("%.0f", k.expires),
    salt = crypto.toHex(crypto.randomBytes(16)),
    iterations = ITERATIONS,
  }
  data.token = crypto.encrypt(crypto.deriveKey(passphrase, data.salt, ITERATIONS), k.token, savedAad(data))
  local ok, err = writeChecked(SAVED, textutils.serialiseJSON(data))
  if not ok then stop("Can't save /" .. SAVED .. ": " .. err) end
  colourPrint(colours.lime, "Saved to /" .. SAVED .. " for the next " .. timeLeft(k.expires) .. ". gitget logout deletes it.")
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
  if login then token = remembered(clientId) or freshLogin(clientId) end
  print("Looking up " .. name .. "...")
  local info, res, step = fetchRepo(spec, token)
  if not info and step == "repo" and res.status == 404 and not token then
    token = remembered(clientId)
    if not token then
      print("GitHub can't find " .. name .. ": it doesn't exist, or it is private.")
      if not ask("Log in to GitHub and try again? (y/n)") then
        stop("Nothing was downloaded.")
      end
      token = freshLogin(clientId)
    end
    print("Looking up " .. name .. "...")
    info, res, step = fetchRepo(spec, token)
  end
  if not info and step == "repo" and res.status == 401 and token then
    -- the login was revoked on GitHub since
    dropLogin(clientId)
    print("GitHub no longer accepts that login. Log in again.")
    token = freshLogin(clientId)
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

local function login(args)
  local save, clientId = false, CLIENT_ID
  local i = 2
  while args[i] do
    local a = args[i]
    if a == "--save" then save = true
    elseif a == "--client-id" then
      i = i + 1
      clientId = args[i]
      if not clientId then stop("--client-id needs a value.") end
    else stop("Unknown argument " .. a .. ". Run gitget help.") end
    i = i + 1
  end
  local k = kept(clientId)
  if k then
    print("You are logged in for the next " .. timeLeft(k.expires) .. ".")
  else
    freshLogin(clientId)
  end
  if save then saveLogin(clientId) end
end

local function logout()
  forget()
  local saved = fs.exists(SAVED)
  deleteSaved()
  print("GitGet forgot your login on this computer" .. (saved and " and deleted the saved one." or "."))
  print("To revoke it on GitHub too, open")
  print("https://github.com/settings/apps/authorizations")
end

local COMMANDS = { get = get, update = update, login = login, logout = logout }

local function main(...)
  local args = { ... }
  local command = COMMANDS[args[1]]
  if not command then
    usage()
    return
  end
  if not http and command ~= logout then
    print("The http API is turned off in the CC: Tweaked configuration, so GitGet can't download anything.")
    return
  end
  local ok, err = pcall(command, args)
  if not ok then
    if type(err) == "table" and getmetatable(err) == Stop then
      printError(err.msg)
    else
      error(err, 0)
    end
  end
end

---------------------------------------------------------------------------
-- xEncrypt, bundled
---------------------------------------------------------------------------

-- An unchanged copy of apis/xEncrypt.lua from
-- https://github.com/Andriesmenze/ComputerCraft-XEncrypt between the marker
-- lines, with its global functions made local. tests/sync_xencrypt.py copies
-- it in, and the simulator suite compares it with ../XEncrypt. It only loads
-- for a saved login.
local xEncrypt
loadXEncrypt = function()
  if xEncrypt then return xEncrypt end
  local xEncrypt_VERSION, toHex, fromHex, constantTimeEquals, sha256, hmac, hkdf, pbkdf2,
    chacha20, seed, addEntropy, randomBytes, randomInt, generateKey, deriveKey, encrypt,
    decrypt, hashPassword, verifyPassword
-- xEncrypt.lua begins
-- xEncrypt: authenticated encryption, hashing and password storage for
-- ComputerCraft / CC:Tweaked, in pure Lua.
--
--   os.loadAPI("apis/xEncrypt.lua")
--   local key = xEncrypt.generateKey()               -- 64 hex characters, share it with the peer
--   local token = xEncrypt.encrypt(key, "hello")     -- hex string, safe for rednet, files and settings
--   local text, err = xEncrypt.decrypt(key, token)   -- "hello", or nil and a reason
--   local stored = xEncrypt.hashPassword("secret")   -- store this, not the password
--   xEncrypt.verifyPassword("secret", stored)        -- true
--
-- Primitives: SHA-256, HMAC-SHA256, HKDF-SHA256, PBKDF2-HMAC-SHA256 and ChaCha20
-- (RFC 8439), checked against the official test vectors in tests/.
-- encrypt() is ChaCha20 + HMAC-SHA256 (encrypt-then-MAC) with a random 96 bit nonce.
--
-- Errors: wrong argument types or malformed keys raise an error (programming
-- mistakes); a token that is malformed, too long, tampered with or encrypted
-- with another key makes decrypt() return nil and a message.
--
-- Randomness: CC has no secure random source. On first use (or seed()) the
-- generator is seeded from clocks, IDs, math.random, table addresses and timing
-- jitter, plus the seed file "/.xEncrypt.seed", which is rewritten so entropy
-- accumulates over reboots. Call addEntropy(string) with local data other
-- players cannot observe, such as tostring(os.epoch("utc")) at each key press.
-- Never pass data received over the network: it is public, and the sender
-- picks its type and size (hashing it does not yield).
--
-- The library never yields; keep single calls well below CC's 7 second limit.

xEncrypt_VERSION = "1.0"

local bit32 = bit32
if not bit32 then
    error("xEncrypt needs the bit32 library", 0)
end
local band, bor, bxor, bnot = bit32.band, bit32.bor, bit32.bxor, bit32.bnot
local rshift, lrotate, rrotate = bit32.rshift, bit32.lrotate, bit32.rrotate
local byte, char, rep, format = string.byte, string.char, string.rep, string.format
local concat = table.concat
local floor, ceil = math.floor, math.ceil
local unpack = table.unpack or unpack

local MOD32 = 4294967296
local SEED_FILE = "/.xEncrypt.seed"
local DEFAULT_ITERATIONS = 1000
-- About 0.6 ms per iteration on CC's Cobalt VM, so the cap keeps one PBKDF2
-- run at around half of CC's 7 second "too long without yielding" limit. It
-- bounds the total work: iterations times the number of 32-byte output blocks.
local MAX_ITERATIONS = 5000
local MAX_RANDOM_BYTES = 16777216 -- far more than one call can produce in 7 s
local DEFAULT_MAX_LENGTH = 65536

local function expectString(value, index, name)
    if type(value) ~= "string" then
        error(format("bad argument #%d to '%s' (string expected, got %s)", index, name, type(value)), 3)
    end
end

local function be32(x)
    return char(floor(x / 16777216) % 256, floor(x / 65536) % 256, floor(x / 256) % 256, x % 256)
end

local function be64(x)
    local t = {}
    for i = 8, 1, -1 do
        t[i] = char(x % 256)
        x = floor(x / 256)
    end
    return concat(t)
end

local function le32(s, i)
    local a, b, c, d = byte(s, i, i + 3)
    return ((d * 256 + c) * 256 + b) * 256 + a
end

---------------------------------------------------------------------------
-- Encoding helpers
---------------------------------------------------------------------------

function toHex(data)
    expectString(data, 1, "toHex")
    return (data:gsub(".", function(c) return format("%02x", byte(c)) end))
end

-- Returns nil for anything that is not an even-length hexadecimal string.
function fromHex(hex)
    if type(hex) ~= "string" or #hex % 2 ~= 0 or hex:find("[^%x]") then
        return nil
    end
    return (hex:gsub("%x%x", function(h) return char(tonumber(h, 16)) end))
end

-- Compares two strings in time that depends only on their length.
function constantTimeEquals(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then
        return false
    end
    local diff = 0
    for i = 1, #a do
        diff = bor(diff, bxor(byte(a, i), byte(b, i)))
    end
    return diff == 0
end

---------------------------------------------------------------------------
-- SHA-256 (FIPS 180-4)
---------------------------------------------------------------------------

local K256 = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}
local IV256 = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }

-- Processes the 64 byte block of `data` that starts at `offset` into state H.
local function compress(H, data, offset)
    local w = {}
    for t = 0, 15 do
        local a, b, c, d = byte(data, offset + 4 * t, offset + 4 * t + 3)
        w[t] = ((a * 256 + b) * 256 + c) * 256 + d
    end
    for t = 16, 63 do
        local x, y = w[t - 15], w[t - 2]
        local s0 = bxor(rrotate(x, 7), rrotate(x, 18), rshift(x, 3))
        local s1 = bxor(rrotate(y, 17), rrotate(y, 19), rshift(y, 10))
        w[t] = (w[t - 16] + s0 + w[t - 7] + s1) % MOD32
    end
    local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    for t = 0, 63 do
        local s1 = bxor(rrotate(e, 6), rrotate(e, 11), rrotate(e, 25))
        local ch = bxor(band(e, f), band(bnot(e), g))
        local t1 = h + s1 + ch + K256[t + 1] + w[t]
        local s0 = bxor(rrotate(a, 2), rrotate(a, 13), rrotate(a, 22))
        local maj = bxor(band(a, b), band(a, c), band(b, c))
        h, g, f, e = g, f, e, (d + t1) % MOD32
        d, c, b, a = c, b, a, (t1 + s0 + maj) % MOD32
    end
    H[1], H[2], H[3], H[4] = (H[1] + a) % MOD32, (H[2] + b) % MOD32, (H[3] + c) % MOD32, (H[4] + d) % MOD32
    H[5], H[6], H[7], H[8] = (H[5] + e) % MOD32, (H[6] + f) % MOD32, (H[7] + g) % MOD32, (H[8] + h) % MOD32
end

-- Finishes a hash whose state H has already absorbed `processed` bytes (a
-- multiple of 64) and still has to absorb `data`.
local function finish(H, data, processed)
    local len = #data
    local full = floor(len / 64)
    for i = 0, full - 1 do
        compress(H, data, i * 64 + 1)
    end
    local total = processed + len
    local tail = data:sub(full * 64 + 1) .. "\128" .. rep("\0", (55 - total) % 64) .. be64(total * 8)
    for i = 1, #tail, 64 do
        compress(H, tail, i)
    end
    return be32(H[1]) .. be32(H[2]) .. be32(H[3]) .. be32(H[4])
        .. be32(H[5]) .. be32(H[6]) .. be32(H[7]) .. be32(H[8])
end

local function copyState(H)
    return { H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8] }
end

-- Returns the raw 32 byte SHA-256 digest of data (use toHex for text).
function sha256(data)
    expectString(data, 1, "sha256")
    return finish(copyState(IV256), data, 0)
end

---------------------------------------------------------------------------
-- HMAC-SHA256 (RFC 2104), HKDF (RFC 5869), PBKDF2 (RFC 8018)
---------------------------------------------------------------------------

local function xorPad(key, value)
    return (key:gsub(".", function(c) return char(bxor(byte(c), value)) end))
end

-- Precomputes the states after the inner and outer key blocks, so every
-- further MAC with the same key costs two compressions less.
local function hmacInit(key)
    if #key > 64 then
        key = finish(copyState(IV256), key, 0)
    end
    key = key .. rep("\0", 64 - #key)
    local inner, outer = copyState(IV256), copyState(IV256)
    compress(inner, xorPad(key, 0x36), 1)
    compress(outer, xorPad(key, 0x5c), 1)
    return inner, outer
end

local function hmacWith(inner, outer, data)
    return finish(copyState(outer), finish(copyState(inner), data, 64), 64)
end

-- Returns the raw 32 byte HMAC-SHA256 of data under key.
function hmac(key, data)
    expectString(key, 1, "hmac")
    expectString(data, 2, "hmac")
    local inner, outer = hmacInit(key)
    return hmacWith(inner, outer, data)
end

-- Derives `length` raw bytes (at most 8160) from input keying material.
function hkdf(ikm, salt, info, length)
    expectString(ikm, 1, "hkdf")
    salt, info = salt or "", info or ""
    expectString(salt, 2, "hkdf")
    expectString(info, 3, "hkdf")
    if type(length) ~= "number" or length < 0 or length > 255 * 32 or length % 1 ~= 0 then
        error("bad argument #4 to 'hkdf' (length must be an integer from 0 to 8160)", 2)
    end
    if salt == "" then
        salt = rep("\0", 32)
    end
    local saltInner, saltOuter = hmacInit(salt)
    local inner, outer = hmacInit(hmacWith(saltInner, saltOuter, ikm))
    local okm, t = {}, ""
    for i = 1, ceil(length / 32) do
        t = hmacWith(inner, outer, t .. info .. char(i))
        okm[i] = t
    end
    return concat(okm):sub(1, length)
end

-- Derives `length` raw bytes from a password with PBKDF2-HMAC-SHA256.
local function expectIterations(iterations, index, name)
    if type(iterations) ~= "number" or iterations < 1 or iterations > MAX_ITERATIONS or iterations % 1 ~= 0 then
        error(format("bad argument #%d to '%s' (iterations must be an integer from 1 to %d)", index, name, MAX_ITERATIONS), 3)
    end
end

function pbkdf2(password, salt, iterations, length)
    expectString(password, 1, "pbkdf2")
    expectString(salt, 2, "pbkdf2")
    expectIterations(iterations, 3, "pbkdf2")
    length = length or 32
    if type(length) ~= "number" or length < 1 or length > 1024 or length % 1 ~= 0 then
        error("bad argument #4 to 'pbkdf2' (length must be an integer from 1 to 1024)", 2)
    end
    if iterations * ceil(length / 32) > MAX_ITERATIONS then
        error(format("bad argument #4 to 'pbkdf2' (iterations * ceil(length / 32) must be at most %d)", MAX_ITERATIONS), 2)
    end
    local inner, outer = hmacInit(password)
    local blocks = {}
    for i = 1, ceil(length / 32) do
        local u = hmacWith(inner, outer, salt .. be32(i))
        local t = { byte(u, 1, 32) }
        for _ = 2, iterations do
            u = hmacWith(inner, outer, u)
            for j = 1, 32 do
                t[j] = bxor(t[j], byte(u, j))
            end
        end
        blocks[i] = char(unpack(t))
    end
    return concat(blocks):sub(1, length)
end

---------------------------------------------------------------------------
-- ChaCha20 (RFC 8439)
---------------------------------------------------------------------------

local function quarterRound(x, a, b, c, d)
    x[a] = (x[a] + x[b]) % MOD32
    x[d] = lrotate(bxor(x[d], x[a]), 16)
    x[c] = (x[c] + x[d]) % MOD32
    x[b] = lrotate(bxor(x[b], x[c]), 12)
    x[a] = (x[a] + x[b]) % MOD32
    x[d] = lrotate(bxor(x[d], x[a]), 8)
    x[c] = (x[c] + x[d]) % MOD32
    x[b] = lrotate(bxor(x[b], x[c]), 7)
end

local function chachaBlock(state)
    local x = { unpack(state, 1, 16) }
    for _ = 1, 10 do
        quarterRound(x, 1, 5, 9, 13)
        quarterRound(x, 2, 6, 10, 14)
        quarterRound(x, 3, 7, 11, 15)
        quarterRound(x, 4, 8, 12, 16)
        quarterRound(x, 1, 6, 11, 16)
        quarterRound(x, 2, 7, 12, 13)
        quarterRound(x, 3, 8, 9, 14)
        quarterRound(x, 4, 5, 10, 15)
    end
    for i = 1, 16 do
        x[i] = (x[i] + state[i]) % MOD32
    end
    return x
end

-- Encrypts or decrypts data with a raw 32 byte key and 12 byte nonce, starting
-- at block `counter`. Never reuse a key and nonce pair for different data.
function chacha20(key, nonce, counter, data)
    expectString(key, 1, "chacha20")
    expectString(nonce, 2, "chacha20")
    expectString(data, 4, "chacha20")
    if #key ~= 32 then error("bad argument #1 to 'chacha20' (key must be 32 bytes)", 2) end
    if #nonce ~= 12 then error("bad argument #2 to 'chacha20' (nonce must be 12 bytes)", 2) end
    -- Written without counter + blocks, which can overflow on integer Lua.
    if type(counter) ~= "number" or counter < 0 or counter % 1 ~= 0
        or counter > MOD32 - ceil(#data / 64) then
        error("bad argument #3 to 'chacha20' (counter out of range)", 2)
    end
    local state = {
        0x61707865, 0x3320646e, 0x79622d32, 0x6b206574,
        le32(key, 1), le32(key, 5), le32(key, 9), le32(key, 13),
        le32(key, 17), le32(key, 21), le32(key, 25), le32(key, 29),
        counter, le32(nonce, 1), le32(nonce, 5), le32(nonce, 9),
    }
    local out = {}
    for offset = 1, #data, 64 do
        local stream = chachaBlock(state)
        local bytes = { byte(data, offset, offset + 63) }
        local n, j = #bytes, 1
        for w = 1, 16 do
            local word = stream[w]
            for _ = 1, 4 do
                if j > n then break end
                bytes[j] = bxor(bytes[j], word % 256)
                word = floor(word / 256)
                j = j + 1
            end
        end
        out[#out + 1] = char(unpack(bytes, 1, n))
        state[13] = state[13] + 1
    end
    return concat(out)
end

---------------------------------------------------------------------------
-- Random bytes: ChaCha20 generator with fast key erasure
---------------------------------------------------------------------------

local generatorKey
local seedDirty = false -- addEntropy data not yet carried into the seed file
local ZERO_NONCE = rep("\0", 12)

-- Returns the seed file's 64 hex characters, or nil if it is missing or damaged.
local function readSeedFile()
    if not (fs and fs.exists and fs.exists(SEED_FILE)) then return nil end
    local ok, content = pcall(function()
        local handle = fs.open(SEED_FILE, "r")
        if not handle then return nil end
        local text = handle.readAll()
        handle.close()
        return text
    end)
    if ok and type(content) == "string" and #content == 64 and not content:find("[^0-9a-f]") then
        return content
    end
    return nil
end

local function writeSeedFile(hex)
    if not (fs and fs.open) then return end
    pcall(function()
        local handle = fs.open(SEED_FILE, "w")
        if handle then
            handle.write(hex)
            handle.close()
        end
    end)
end

-- Most of these values are public or guessable for other players; they only
-- make pools differ. math.random is not secret either (every rednet.send
-- broadcasts one of its outputs). The secret part comes from the timing
-- jitter, table addresses and the seed file.
local function gatherEntropy()
    local pool = {}
    local function add(value)
        pool[#pool + 1] = type(value) == "number" and format("%.17g", value) or tostring(value)
    end
    if os.getComputerID then add(os.getComputerID()) end
    if os.getComputerLabel then add(os.getComputerLabel()) end
    if os.epoch then
        for _, kind in ipairs({ "utc", "ingame", "local", "nano" }) do
            local ok, value = pcall(os.epoch, kind)
            if ok then add(value) end
        end
    end
    add(os.clock())
    if os.time then add(os.time()) end
    if os.day then add(os.day()) end
    add({})
    add(function() end)
    for _ = 1, 4 do add(math.random()) end
    -- Timing jitter: how many loop iterations fit in one clock tick varies with
    -- JIT, garbage collection and server load. Bounded in time (clock ticks can
    -- be ~16 ms on some hosts) and in total iterations (in case the clock does
    -- not move at all).
    if os.epoch then
        local deadline, budget = os.epoch("utc") + 250, 1000000
        for _ = 1, 256 do
            local start, n = os.epoch("utc"), 0
            repeat n = n + 1 until os.epoch("utc") ~= start or n >= budget
            budget = budget - n
            add(n)
            if budget <= 0 or os.epoch("utc") >= deadline then break end
        end
    end
    add(readSeedFile())
    return concat(pool, "|")
end

local function ensureSeeded()
    if generatorKey then return end
    generatorKey = finish(copyState(IV256), gatherEntropy(), 0)
    writeSeedFile(toHex(randomBytes(32)))
end

-- Seeds the random generator now (it otherwise seeds on first use, which takes
-- up to about a quarter of a second). Calling it again does nothing.
function seed()
    ensureSeeded()
end

-- Mixes extra unpredictable data into the generator. It reaches the seed file
-- (and so later boots) the next time random bytes are drawn, which keeps a
-- program that calls this on every key press from writing the disk each time.
function addEntropy(data)
    expectString(data, 1, "addEntropy")
    ensureSeeded()
    generatorKey = finish(copyState(IV256), generatorKey .. data, 0)
    seedDirty = true
end

-- Returns n random bytes (raw string).
function randomBytes(n)
    if type(n) ~= "number" or n < 0 or n % 1 ~= 0 or n > MAX_RANDOM_BYTES then
        error("bad argument #1 to 'randomBytes' (integer from 0 to " .. MAX_RANDOM_BYTES .. " expected)", 2)
    end
    ensureSeeded()
    local stream = chacha20(generatorKey, ZERO_NONCE, 0, rep("\0", 32 + n))
    generatorKey = stream:sub(1, 32)
    if seedDirty then
        seedDirty = false
        writeSeedFile(toHex(randomBytes(32)))
    end
    return stream:sub(33)
end

-- Returns a uniformly distributed random integer from min to max (inclusive),
-- like math.random(min, max) but from the secure generator. The bounds must lie
-- within +/-2^53 (where doubles are exact) and span less than 2^32.
function randomInt(min, max)
    if type(min) ~= "number" or type(max) ~= "number" or min % 1 ~= 0 or max % 1 ~= 0
        or min < -2 ^ 53 or max > 2 ^ 53 or min > max or max - min >= MOD32 then
        error("bad argument to 'randomInt' (integers -2^53 <= min <= max <= 2^53 with max - min < 2^32 expected)", 2)
    end
    local range = max - min + 1
    local limit = MOD32 - MOD32 % range -- reject values above the last full multiple of range
    while true do
        local a, b, c, d = byte(randomBytes(4), 1, 4)
        local value = ((a * 256 + b) * 256 + c) * 256 + d
        if value < limit then
            return min + value % range
        end
    end
end

-- Returns a new random key as 64 hex characters.
function generateKey()
    return toHex(randomBytes(32))
end

-- Derives a key (64 hex characters) from a password or passphrase. Both sides
-- must use the same salt and iteration count.
function deriveKey(password, salt, iterations)
    expectString(password, 1, "deriveKey")
    expectString(salt, 2, "deriveKey")
    iterations = iterations or DEFAULT_ITERATIONS
    expectIterations(iterations, 3, "deriveKey")
    return toHex(pbkdf2(password, salt, iterations, 32))
end

---------------------------------------------------------------------------
-- Authenticated encryption
---------------------------------------------------------------------------

local TOKEN_VERSION = "\1"
local NONCE_SIZE, TAG_SIZE = 12, 32

local function rawKey(key, index, name)
    if type(key) ~= "string" or #key ~= 64 or not fromHex(key) then
        error(format("bad argument #%d to '%s' (key must be 64 hexadecimal characters, see generateKey)", index, name), 3)
    end
    return fromHex(key)
end

local function subkeys(key)
    local inner, outer = hmacInit(key)
    return hmacWith(inner, outer, "xEncrypt v1 encryption"), hmacWith(inner, outer, "xEncrypt v1 authentication")
end

local function authTag(macKey, header, aad, ciphertext)
    return hmac(macKey, header .. be64(#aad) .. aad .. ciphertext)
end

-- Encrypts plaintext with a key from generateKey/deriveKey. `aad` is optional
-- extra data (for example a sender ID) that is authenticated but not
-- encrypted; decrypt needs the same value. Returns a hex string.
function encrypt(key, plaintext, aad)
    local raw = rawKey(key, 1, "encrypt")
    expectString(plaintext, 2, "encrypt")
    aad = aad or ""
    expectString(aad, 3, "encrypt")
    local encKey, macKey = subkeys(raw)
    local header = TOKEN_VERSION .. randomBytes(NONCE_SIZE)
    local ciphertext = chacha20(encKey, header:sub(2), 1, plaintext)
    return toHex(header .. ciphertext .. authTag(macKey, header, aad, ciphertext))
end

-- Returns the plaintext, or nil and a message if the token is malformed, was
-- modified, or was made with another key or aad. Tokens for plaintexts longer
-- than maxLength bytes (default 65536) are rejected with "token too long"
-- before any work is done, so a huge token received over rednet cannot stall
-- the computer; pass a larger maxLength to accept bigger messages.
function decrypt(key, token, aad, maxLength)
    local raw = rawKey(key, 1, "decrypt")
    aad = aad or ""
    expectString(aad, 3, "decrypt")
    maxLength = maxLength or DEFAULT_MAX_LENGTH
    if type(maxLength) ~= "number" or not (maxLength >= 0) then -- also rejects NaN
        error("bad argument #4 to 'decrypt' (non-negative number expected)", 2)
    end
    local overhead = 1 + NONCE_SIZE + TAG_SIZE
    if type(token) ~= "string" then
        return nil, "invalid token"
    end
    if #token > 2 * (overhead + maxLength) then
        return nil, "token too long"
    end
    if #token < 2 * overhead or #token % 2 ~= 0 or token:find("[^0-9a-f]") then
        return nil, "invalid token"
    end
    if token:sub(1, 2) ~= toHex(TOKEN_VERSION) then
        return nil, "unsupported token version"
    end
    local data = fromHex(token)
    local header = data:sub(1, 1 + NONCE_SIZE)
    local ciphertext = data:sub(2 + NONCE_SIZE, -TAG_SIZE - 1)
    local encKey, macKey = subkeys(raw)
    if not constantTimeEquals(data:sub(-TAG_SIZE), authTag(macKey, header, aad, ciphertext)) then
        return nil, "authentication failed"
    end
    return chacha20(encKey, header:sub(2), 1, ciphertext)
end

---------------------------------------------------------------------------
-- Password storage
---------------------------------------------------------------------------

-- Returns a salted PBKDF2 hash to store instead of the password:
-- "pbkdf2-sha256$<iterations>$<salt hex>$<hash hex>".
function hashPassword(password, iterations)
    expectString(password, 1, "hashPassword")
    iterations = iterations or DEFAULT_ITERATIONS
    expectIterations(iterations, 2, "hashPassword")
    local salt = randomBytes(16)
    return format("pbkdf2-sha256$%d$%s$%s", iterations, toHex(salt), toHex(pbkdf2(password, salt, iterations, 32)))
end

-- Checks a password against a string from hashPassword. Anything that is not
-- exactly in hashPassword's format (16 byte salt, 32 byte hash) is rejected.
function verifyPassword(password, stored)
    if type(password) ~= "string" or type(stored) ~= "string" then
        return false
    end
    local iterations, saltHex, hashHex = stored:match("^pbkdf2%-sha256%$([1-9]%d*)%$([0-9a-f]+)%$([0-9a-f]+)$")
    iterations = tonumber(iterations)
    if not iterations or iterations > MAX_ITERATIONS or #saltHex ~= 32 or #hashHex ~= 64 then
        return false
    end
    local hash = fromHex(hashHex)
    return constantTimeEquals(pbkdf2(password, fromHex(saltHex), iterations, #hash), hash)
end
-- xEncrypt.lua ends
  xEncrypt = { toHex = toHex, randomBytes = randomBytes, deriveKey = deriveKey, encrypt = encrypt, decrypt = decrypt }
  return xEncrypt
end

main(...)
