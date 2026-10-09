-- Scenarios for programs/gitget.lua against the fake CC:Tweaked and GitHub in
-- fakes.lua.
local T = require("testlib")
local F = require("fakes")
local test, eq, ok, contains, notContains = T.test, T.eq, T.ok, T.contains, T.notContains

local BINARY = ""
for i = 0, 255 do BINARY = BINARY .. string.char(i) end

local function sampleRepo(w, extra)
  local repo = {
    files = {
      ["README.md"] = "# Sample\r\nCRLF kept\r\n",
      ["apis/util.lua"] = "return 1\n",
      ["programs/run.lua"] = "print('hi')\n",
      ["img/logo.bin"] = BINARY,
      ["dir with space/a+b.txt"] = "plus and space\n",
    },
  }
  for k, v in pairs(extra or {}) do repo[k] = v end
  return w:addRepo("someone/sample", repo)
end

local function noBug(text, err)
  if err then error("gitget raised: " .. err .. "\n" .. text, 2) end
  return text
end

test("downloads the default branch into a folder named after the repo", function()
  local w = F.new()
  sampleRepo(w)
  local text = noBug(w:run("get", "someone/sample"))
  eq(w.files["sample/README.md"], "# Sample\r\nCRLF kept\r\n", "README")
  eq(w.files["sample/apis/util.lua"], "return 1\n", "util")
  eq(w.files["sample/img/logo.bin"], BINARY, "binary bytes")
  eq(w.files["sample/dir with space/a+b.txt"], "plus and space\n", "encoded path")
  contains(text, "Downloaded 5 files")
  contains(text, "someone/sample@main (a1b2c3d)")
  eq(#w.errors, 0, "errors")
  eq(#w:authed(), 0, "no Authorization without login")
  for _, r in ipairs(w.requests) do
    if r.url:find("raw.githubusercontent", 1, true) then
      eq(r.binary, true, "raw downloads are binary")
      ok(r.url:find("/a1b2c3d4", 1, true), "pinned to the commit: " .. r.url)
    end
  end
  for p in pairs(w.files) do notContains(p, "gitget-new", "no checked copy left") end
end)

test("uses three API requests and fetches file contents from raw", function()
  local w = F.new()
  sampleRepo(w)
  noBug(w:run("get", "someone/sample"))
  local api = 0
  for _, r in ipairs(w.requests) do
    if r.url:find("api.github.com", 1, true) then
      api = api + 1
      eq(r.headers["X-GitHub-Api-Version"], "2022-11-28", "API version")
    end
    ok(r.headers["User-Agent"] and r.headers["User-Agent"]:find("^gitget%-cc/"), "User-Agent")
  end
  eq(api, 3, "API requests")
end)

test("accepts a github.com URL", function()
  local w = F.new()
  sampleRepo(w)
  noBug(w:run("get", "https://github.com/someone/sample.git"))
  ok(w.files["sample/README.md"], "downloaded")
end)

test("an @ref downloads that ref", function()
  local w = F.new()
  sampleRepo(w, { refs = { main = ("1"):rep(40), ["release/v2"] = ("2"):rep(40) } })
  local text = noBug(w:run("get", "someone/sample@release/v2", "out"))
  contains(text, "someone/sample@release/v2 (2222222)")
  ok(w.files["out/README.md"], "into out/")
end)

test("an unknown ref says so", function()
  local w = F.new()
  sampleRepo(w)
  noBug(w:run("get", "someone/sample@nope"))
  contains(w:errorText(), "has no branch, tag or commit called nope")
end)

test("a :path downloads one folder with the prefix removed", function()
  local w = F.new()
  sampleRepo(w)
  noBug(w:run("get", "someone/sample:apis"))
  eq(w.files["apis/util.lua"], "return 1\n", "folder named after the path")
  ok(not w.files["apis/README.md"] and not w.files["sample/README.md"], "nothing else")
end)

test("a :path lists only that folder, not the whole repository", function()
  local w = F.new()
  sampleRepo(w, { files = { ["a/b/c/deep.lua"] = "deep", ["a/b/other.lua"] = "o", ["big/x.lua"] = "x" } })
  noBug(w:run("get", "someone/sample:a/b"))
  eq(w.files["b/c/deep.lua"], "deep", "nested file")
  eq(w.files["b/other.lua"], "o", "file in the folder")
  ok(not w.files["b/x.lua"], "nothing from elsewhere")
  for _, r in ipairs(w.requests) do
    if r.url:find("recursive=1", 1, true) then
      ok(r.url:find(F.blobSha("a/b"), 1, true), "only the folder is listed recursively: " .. r.url)
    end
  end
end)

test("a :path to one file downloads just that file", function()
  local w = F.new()
  sampleRepo(w)
  local text = noBug(w:run("get", "someone/sample:programs/run.lua"))
  eq(w.files["run.lua"], "print('hi')\n", "file in the current folder")
  contains(text, "Downloaded 1 file ")
  noBug(w:run("get", "someone/sample:programs/run.lua", "bin/go.lua"))
  eq(w.files["bin/go.lua"], "print('hi')\n", "file under a new name")
end)

test("a missing :path says so", function()
  local w = F.new()
  sampleRepo(w)
  noBug(w:run("get", "someone/sample:nothing"))
  contains(w:errorText(), "has no file or folder called nothing")
end)

test("downloads into the current folder and onto a target", function()
  local w = F.new({ cwd = "work" })
  w.dirs["work"] = true
  sampleRepo(w)
  noBug(w:run("get", "someone/sample", "copy"))
  ok(w.files["work/copy/README.md"], "relative to the current folder")
end)

test("skips symbolic links, submodules and names CC can't save", function()
  local w = F.new()
  sampleRepo(w, { links = { ["link.lua"] = "apis/util.lua" }, submodules = { "vendor/lib" },
    files = { ["ok.lua"] = "x", ["what?.txt"] = "y" } })
  local text = noBug(w:run("get", "someone/sample"))
  ok(w.files["sample/ok.lua"], "normal file")
  ok(not w.files["sample/link.lua"] and not w.dirs["sample/vendor"], "no link, no submodule")
  contains(text, "Skipped 1 symbolic link")
  contains(text, "Skipped 1 submodule")
  contains(text, "names CC can't save, such as what?.txt")
end)

test("refuses a tree with an unsafe path before writing anything", function()
  local w = F.new()
  sampleRepo(w, { extraPaths = { "a/../../evil.lua" } })
  noBug(w:run("get", "someone/sample"))
  contains(w:errorText(), "unsafe path")
  eq(next(w.files), nil, "nothing written")
end)

test("a truncated tree asks for a folder", function()
  local w = F.new()
  sampleRepo(w, { truncated = true })
  noBug(w:run("get", "someone/sample"))
  contains(w:errorText(), "too big for GitHub to list")
  eq(next(w.files), nil, "nothing written")
end)

test("an empty repository says so", function()
  local w = F.new()
  sampleRepo(w, { empty = true })
  noBug(w:run("get", "someone/sample"))
  contains(w:errorText(), "is empty")
end)

test("a bad spec or option prints a clear message", function()
  local w = F.new()
  noBug(w:run("get", "not-a-repo"))
  contains(w:errorText(), "Can't read not-a-repo")
  noBug(w:run("get", "a/b", "--nope"))
  contains(w:errorText(), "Unknown option --nope")
  local text = noBug(w:run())
  contains(text, "Usage:")
end)

test("without http it says the API is off", function()
  local w = F.new()
  w.httpOff = true
  local text = noBug(w:run("get", "someone/sample"))
  contains(text, "http API is turned off")
end)

test("the rate limit message explains the limit and the wait", function()
  local w = F.new()
  sampleRepo(w)
  w.rateLimited = true
  noBug(w:run("get", "someone/sample"))
  contains(w:errorText(), "rate limit is used up")
  contains(w:errorText(), "about 10 minutes")
end)

-- Private repositories and the device login ---------------------------------

test("a private repo: 404, login prompt, device flow, then download through the API", function()
  local w = F.new()
  sampleRepo(w, { private = true })
  w:deviceFlow({ "authorization_pending", "slow_down", "token" })
  w.answers = { "y" }
  local text = noBug(w:run("get", "someone/sample", "--client-id", F.CLIENT_ID))
  contains(text, "it doesn't exist, or it is private")
  contains(text, "ABCD-1234")
  contains(text, "https://github.com/login/device")
  contains(text, "Logged in.")
  eq(w.files["sample/img/logo.bin"], BINARY, "binary through the blob API")
  eq(w.files["sample/README.md"], "# Sample\r\nCRLF kept\r\n", "README")
  eq(table.concat(w.sleeps, ","), "5,5,10", "polls at the interval, slower after slow_down")
  notContains(text, F.TOKEN, "the token is never shown")
  -- before the login, no request carried a token; after it, only api.github.com did
  local seenLogin = false
  for _, r in ipairs(w.requests) do
    if r.url == "https://github.com/login/oauth/access_token" then seenLogin = true end
    if r.headers.Authorization then
      ok(seenLogin, "token sent before login: " .. r.url)
      ok(r.url:find("^https://api%.github%.com/"), "token sent outside the API: " .. r.url)
      eq(r.headers.Authorization, "Bearer " .. F.TOKEN, "bearer token")
    end
    if r.url:find("^https://github%.com/login/") then
      eq(r.headers.Accept, "application/json", "login asks for JSON")
      eq(r.headers.Authorization, nil, "no token to the login endpoints")
    end
  end
  for _, data in pairs(w.files) do notContains(data, F.TOKEN, "token in a file") end
end)

test("--login logs in first, without trying anonymously", function()
  local w = F.new()
  sampleRepo(w, { private = true })
  w:deviceFlow({ "token" })
  noBug(w:run("get", "someone/sample", "--login", "--client-id", F.CLIENT_ID))
  ok(w.files["sample/README.md"], "downloaded")
  eq(w.requests[1].url, "https://github.com/login/device/code", "first request")
end)

test("declining the login stops without downloading", function()
  local w = F.new()
  sampleRepo(w, { private = true })
  w.answers = { "n" }
  noBug(w:run("get", "someone/sample", "--client-id", F.CLIENT_ID))
  contains(w:errorText(), "Nothing was downloaded")
  eq(next(w.files), nil, "nothing written")
end)

test("expired and denied device codes stop with a clear message", function()
  for step, message in pairs({ expired_token = "code expired", access_denied = "cancelled on GitHub" }) do
    local w = F.new()
    sampleRepo(w, { private = true })
    w:deviceFlow({ "authorization_pending", step })
    noBug(w:run("get", "someone/sample", "--login", "--client-id", F.CLIENT_ID))
    contains(w:errorText(), message)
  end
end)

test("a wrong client ID is reported", function()
  local w = F.new()
  sampleRepo(w, { private = true })
  w:deviceFlow({ "token" })
  noBug(w:run("get", "someone/sample", "--login", "--client-id", "wrong"))
  contains(w:errorText(), "GitHub refused the login: incorrect_client_credentials")
end)

test("a server error from the login service says to try again later", function()
  local w = F.new()
  sampleRepo(w, { private = true })
  w:deviceFlow({ "token" })
  w.device.codeStatus = 500
  noBug(w:run("get", "someone/sample", "--login", "--client-id", F.CLIENT_ID))
  contains(w:errorText(), "login service had a problem (HTTP 500). Try again in a few minutes.")
end)

test("still not found after login points at installing the app", function()
  local w = F.new()
  sampleRepo(w, { private = true, appInstalled = false })
  w:deviceFlow({ "token" })
  w.answers = { "y" }
  noBug(w:run("get", "someone/sample", "--client-id", F.CLIENT_ID))
  contains(w:errorText(), "/installations/new")
end)

-- The login kept in memory ---------------------------------------------------

local function loggedIn()
  local w = F.new()
  sampleRepo(w, { private = true })
  w:deviceFlow({ "token" })
  w.answers = { "y" }
  noBug(w:run("get", "someone/sample", "--client-id", F.CLIENT_ID))
  ok(w.files["sample/README.md"], "first download")
  w.files, w.dirs, w.requests = {}, { [""] = true }, {}
  return w
end

local function loginRequests(w)
  local n = 0
  for _, r in ipairs(w.requests) do
    if r.url:find("^https://github%.com/login/") then n = n + 1 end
  end
  return n
end

test("a second private download uses the login from earlier", function()
  local w = loggedIn()
  local text = noBug(w:run("get", "someone/sample", "--client-id", F.CLIENT_ID))
  ok(w.files["sample/README.md"], "downloaded")
  contains(text, "Using your login from earlier")
  notContains(text, "Log in to GitHub")
  eq(loginRequests(w), 0, "no new login")
  notContains(text, F.TOKEN, "the token is never shown")
  for _, data in pairs(w.files) do notContains(data, F.TOKEN, "token in a file") end
end)

test("--login uses the login from earlier", function()
  local w = loggedIn()
  noBug(w:run("get", "someone/sample", "--login", "--client-id", F.CLIENT_ID))
  ok(w.files["sample/README.md"], "downloaded")
  eq(loginRequests(w), 0, "no new login")
end)

test("public downloads still carry no token after a login", function()
  local w = loggedIn()
  w:addRepo("someone/open", { files = { ["a.lua"] = "x" } })
  noBug(w:run("get", "someone/open", "--client-id", F.CLIENT_ID))
  eq(w.files["open/a.lua"], "x", "downloaded")
  eq(#w:authed(), 0, "no Authorization")
end)

test("a restart, an expiring token, another app and logout each mean a new login", function()
  local cases = {
    restart = function(w) w:reboot() end,
    expiry = function(w) w.epoch = w.epoch + (8 * 3600 - 299) * 1000 end,
    app = function(w) w.memory.gitget_login.clientId = "other" end,
    logout = function(w)
      local text = noBug(w:run("logout"))
      contains(text, "forgot your login")
      eq(w.memory.gitget_login, nil, "forgotten")
    end,
  }
  for name, change in pairs(cases) do
    local w = loggedIn()
    change(w)
    w:deviceFlow({ "token" })
    w.answers = { "y" }
    local text = noBug(w:run("get", "someone/sample", "--client-id", F.CLIENT_ID))
    contains(text, "Log in to GitHub", name)
    ok(w.files["sample/README.md"], name .. ": downloaded")
  end
end)

test("a token that is about to expire in more than five minutes is still used", function()
  local w = loggedIn()
  w.epoch = w.epoch + (8 * 3600 - 301) * 1000
  noBug(w:run("get", "someone/sample", "--client-id", F.CLIENT_ID))
  eq(loginRequests(w), 0, "no new login")
end)

test("a login revoked on GitHub is forgotten and replaced", function()
  local w = loggedIn()
  w.revoked = true
  w:deviceFlow({ "token" })
  local fresh = w.device
  w.device.script = setmetatable({}, { __index = function() w.revoked = false return "token" end })
  local text = noBug(w:run("get", "someone/sample", "--client-id", F.CLIENT_ID))
  contains(text, "no longer accepts that login")
  contains(text, "Logged in.")
  ok(fresh.polls > 0, "logged in again")
  ok(w.files["sample/README.md"], "downloaded")
end)

-- Disks, space and checked writes -------------------------------------------

test("--disk with one drive downloads onto it", function()
  local w = F.new()
  w:addDisk("left", "disk")
  sampleRepo(w)
  local text = noBug(w:run("get", "someone/sample", "--disk"))
  ok(w.files["disk/sample/README.md"], "on the disk")
  contains(text, "to /disk/sample")
end)

test("--disk with several drives asks which", function()
  local w = F.new()
  w:addDisk("left", "disk")
  w:addDisk("right", "disk2", nil, "Backup")
  sampleRepo(w)
  w.answers = { "2" }
  local text = noBug(w:run("get", "someone/sample", "prog", "--disk"))
  contains(text, '2. /disk2 "Backup"')
  ok(w.files["disk2/prog/README.md"], "on the second disk")
end)

test("--disk without a disk says so", function()
  local w = F.new()
  sampleRepo(w)
  noBug(w:run("get", "someone/sample", "--disk"))
  contains(w:errorText(), "No disk found")
end)

test("not enough space stops before writing anything", function()
  local w = F.new()
  w:addDisk("left", "disk", 3000)
  sampleRepo(w)
  noBug(w:run("get", "someone/sample", "--disk"))
  contains(w:errorText(), "Not enough space on disk")
  eq(next(w.files), nil, "nothing written")
end)

test("the space estimate is enough for the real writes", function()
  -- 5 files of at most 500 bytes, 4 new folders (sample, apis, programs, img
  -- and 'dir with space' -> 5): 10 * 500, plus the checked copy of one file
  local w = F.new()
  w:addDisk("left", "disk", 5 * 500 + 5 * 500 + 500)
  sampleRepo(w)
  noBug(w:run("get", "someone/sample", "--disk"))
  eq(#w.errors, 0, "errors: " .. w:errorText())
  ok(w.files["disk/sample/README.md"], "downloaded")
end)

test("a failed write keeps the old file and reports progress", function()
  local w = F.new()
  sampleRepo(w)
  w:writeFile("sample/programs/run.lua", "old version")
  w.failWrite = "run%.lua"
  w.answers = { "y" }
  noBug(w:run("get", "someone/sample"))
  contains(w:errorText(), "Can't save /sample/programs/run.lua: Out of space")
  contains(w:errorText(), "files were saved")
  eq(w.files["sample/programs/run.lua"], "old version", "old file intact")
  ok(not w.files["sample/programs/run.lua.gitget-new"], "checked copy removed")
end)

test("a write cut short without an error is caught by reading it back", function()
  local w = F.new()
  sampleRepo(w)
  w:writeFile("sample/img/logo.bin", "old")
  w.shortWrite = "logo%.bin"
  w.answers = { "y" }
  noBug(w:run("get", "someone/sample"))
  contains(w:errorText(), "Can't save /sample/img/logo.bin: Out of space")
  eq(w.files["sample/img/logo.bin"], "old", "old file intact")
end)

test("replacing files on a nearly full disk leaves room for the checked copy", function()
  local w = F.new()
  w:addDisk("left", "disk", 5 * 500 + 5 * 500 + 500)
  sampleRepo(w)
  noBug(w:run("get", "someone/sample", "--disk"))
  ok(w.files["disk/sample/README.md"], "first download")
  w:writeFile("disk/filler", "x") -- takes the last 500 bytes: no room for a checked copy
  noBug(w:run("get", "someone/sample", "--disk", "--force"))
  contains(w:errorText(), "Not enough space on disk")
end)

test("a download cut short is not saved", function()
  local w = F.new()
  sampleRepo(w)
  w.cutShort = "apis/util.lua"
  noBug(w:run("get", "someone/sample"))
  contains(w:errorText(), "Can't download apis/util.lua: the download was cut short")
  ok(not w.files["sample/apis/util.lua"], "not saved")
end)

test("a non-empty target asks before replacing, --force does not", function()
  local w = F.new()
  sampleRepo(w)
  w:writeFile("sample/mine.txt", "keep")
  w.answers = { "n" }
  noBug(w:run("get", "someone/sample"))
  contains(w:errorText(), "Nothing was downloaded")
  ok(not w.files["sample/README.md"], "nothing downloaded")
  noBug(w:run("get", "someone/sample", "--force"))
  ok(w.files["sample/README.md"], "downloaded with --force")
  eq(w.files["sample/mine.txt"], "keep", "other files stay")
end)

test("a folder where the repo has a file stops before writing", function()
  local w = F.new()
  sampleRepo(w)
  w:makeDir("sample/README.md")
  noBug(w:run("get", "someone/sample", "--force"))
  contains(w:errorText(), "is a folder, but the repository has a file there")
  ok(w.dirs["sample/README.md"], "folder kept")
  ok(not w.files["sample/apis/util.lua"], "nothing written")
end)

test("a file where the repo has a folder stops before writing", function()
  local w = F.new()
  sampleRepo(w)
  w:writeFile("sample/apis", "a file")
  noBug(w:run("get", "someone/sample", "--force"))
  contains(w:errorText(), "is a file, but the repository has a folder there")
  eq(w.files["sample/apis"], "a file", "file kept")
end)

test("a target that is a file is refused", function()
  local w = F.new()
  sampleRepo(w)
  w:writeFile("sample", "x")
  noBug(w:run("get", "someone/sample"))
  contains(w:errorText(), "/sample is a file")
end)

-- update -------------------------------------------------------------------

test("update replaces the running program", function()
  local w = F.new()
  w:writeFile("gitget.lua", "old")
  w.selfUpdate = '-- GitGet: new\nlocal VERSION = "9.9.9"\n'
  local text = noBug(w:run("update"))
  eq(w.files["gitget.lua"], w.selfUpdate, "replaced")
  contains(text, "GitGet 9.9.9 saved to /gitget.lua")
end)

test("update refuses something that is not GitGet", function()
  local w = F.new()
  w:writeFile("gitget.lua", "old")
  w.selfUpdate = "<html>captive portal</html>"
  noBug(w:run("update"))
  contains(w:errorText(), "not GitGet")
  eq(w.files["gitget.lua"], "old", "kept")
end)

return T.finish("test_gitget.lua")
