-- The adapter's only output channel. Never the terminal: its standard streams
-- are the pane's pty, which the Surface replaced. `path`, `line`, and `tracing`
-- are pure (they take an env table for testing); the rest append to the file.
local Log = {}

local function env(e, key)
  if e then
    return e[key]
  end
  return vim.uv.os_getenv(key)
end

function Log.path(e)
  local state = env(e, "XDG_STATE_HOME")
  if not state or state == "" then
    state = (env(e, "HOME") or "") .. "/.local/state"
  end
  return state .. "/sprite-nvim/adapter.log"
end

function Log.line(kind, message)
  return string.format("%s %s %s", os.date("!%Y-%m-%dT%H:%M:%SZ"), kind, message)
end

function Log.tracing(e)
  return env(e, "SPRITE_NVIM_TRACE") == "1"
end

function Log.open()
  local path = Log.path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  Log._file = io.open(path, "a")
end

function Log.write(kind, message)
  if Log._file then
    Log._file:write(Log.line(kind, message) .. "\n")
    Log._file:flush()
  end
end

function Log.trace(direction, text)
  if Log._traceon == nil then
    Log._traceon = Log.tracing()
  end
  if Log._traceon then
    Log.write("trace", direction .. " " .. text)
  end
end

return Log
