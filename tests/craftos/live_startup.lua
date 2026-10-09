-- CraftOS-PC startup for tests/craftos/run.py: runs gitget against the real
-- GitHub with the commands in /live_cfg.lua, logs everything it prints to
-- /live.log and shuts down. read() answers come from the same config.
local cfg = dofile("/live_cfg.lua")
local log = fs.open("/live.log", "w")
local function note(text)
  log.write(text)
  log.flush()
end

local realWrite, realPrintError, realRead = write, printError, read
-- The ROM's print and printError write through _G.write, so only write logs
-- the text (printError also marks its message).
_G.write = function(text)
  note(tostring(text))
  return realWrite(text)
end
_G.printError = function(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
  note("ERROR: " .. table.concat(parts, "\t") .. "\n")
  return realPrintError(...)
end

periphemu.create("left", "drive")
peripheral.call("left", "insertDisk", 1)

for i, step in ipairs(cfg.steps) do
  local answers = step.answers or {}
  _G.read = function()
    local a = table.remove(answers, 1)
    if a == nil then error("read() with no scripted answer", 0) end
    note(a .. "\n")
    return a
  end
  -- keep: a dummy login for that client ID in memory; forget: a restart
  if step.keep then
    _G.gitget_login = { clientId = step.keep, token = "gho_dummy", expires = os.epoch("utc") + 3600000 }
  end
  if step.forget then _G.gitget_login = nil end
  note("=== STEP " .. i .. "\n")
  local started = os.epoch("utc")
  local ok, err = pcall(shell.execute, "/gitget.lua", table.unpack(step.args))
  if not ok then note("HARNESS ERROR: " .. tostring(err) .. "\n") end
  note(string.format("=== TOOK %.0f ms\n", os.epoch("utc") - started))
  note("=== SAVED " .. tostring(fs.exists("/.gitget_login")) .. "\n")
end
_G.read = realRead
note("=== DONE\n")
log.close()
os.shutdown()
