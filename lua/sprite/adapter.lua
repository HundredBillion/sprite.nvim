-- The editor adapter. Run as `nvim -l adapter.lua <user args>` by the launcher,
-- which has already decided we are inside Sprite. Connects to the Surface
-- Channel, spawns a second `nvim --embed`, attaches as its UI, and shuttles the
-- redraw stream out as grid operations and Surface events back as input.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local Rpc = dofile(here .. "/rpc.lua")
local Redraw = dofile(here .. "/redraw.lua")
local Input = dofile(here .. "/input.lua")
local Log = dofile(here .. "/log.lua")

local uv = vim.uv
Log.open()

local user_args = arg -- the launcher passed the user's Neovim arguments through
local socket_path = uv.os_getenv("SPRITE_SURFACE_SOCKET")
local key = uv.os_getenv("SPRITE_SURFACE_KEY")
local pane = tonumber(uv.os_getenv("SPRITE_PANE"))

-- Fail open: run the real editor on the terminal's own streams, wait, and exit
-- with its code. Used for any refusal before the editor is drawing.
local function fail_open(reason)
  Log.write("failopen", reason)
  local done
  local handle = uv.spawn(vim.v.progpath, {
    args = user_args,
    stdio = { 0, 1, 2 },
  }, function(code)
    done = code or 0
    uv.stop()
  end)
  if not handle then
    os.exit(1)
  end
  uv.run()
  os.exit(done or 0)
end

-- The Surface socket: newline-delimited JSON in both directions.
local sock = uv.new_pipe(false)
local sock_buf = ""
local editor -- the embedded nvim's process handle
local editor_exit -- its code, once known
local rpc -- the RPC client to the editor
local translator = Redraw.new()
local attached = false

-- Referenced by on_surface_event below; assigned after declaration so the
-- closure sees a local, never a global.
local start_editor

local function sock_send(obj)
  local line = vim.json.encode(obj)
  Log.trace("->surface", line)
  sock:write(line .. "\n")
end

-- Everything the editor draws between one flush and the next, as one batch.
local function on_flush()
  local ops = translator:take_batch()
  if ops then
    sock_send({ type = "batch", ops = ops })
  end
end

-- One redraw notification carries many events; translate each, flush at the end.
local function on_redraw(_, events)
  for _, event in ipairs(events) do
    if event[1] == "flush" then
      on_flush()
    else
      translator:event(event)
    end
  end
end

-- Kill the editor and exit as a hangup would (129), leaving swap files to
-- preserve unsaved work — exactly what a closed terminal does today.
local function sprite_gone(reason)
  Log.write("spritegone", reason)
  if editor then
    editor:kill("sigterm")
  end
  uv.stop()
  os.exit(129)
end

-- A decoded Surface event.
local function on_surface_event(event)
  local t = event.type
  if t == "resize" and not attached then
    -- The first resize carries the real grid size; attach the editor to it.
    start_editor(event.cols, event.rows)
    return
  end
  if t == "warning" then
    Log.write("warning", event.message or "")
    return
  end
  if t == "refused" or t == "closed" then
    sprite_gone(t)
    return
  end
  local call = Input.call(event)
  if call and rpc then
    rpc:notify(call.method, call.args)
  elseif event.type == "input" and event.key then
    Log.write("dropkey", event.key)
  end
end

function start_editor(cols, rows)
  attached = true
  local ein = uv.new_pipe(false)
  local eout = uv.new_pipe(false)
  editor = uv.spawn(vim.v.progpath, {
    args = vim.list_extend({ "--embed" }, user_args),
    stdio = { ein, eout, 2 },
  }, function(code)
    editor_exit = code or 0
    uv.stop()
  end)
  if not editor then
    fail_open("could not spawn the editor")
    return
  end
  rpc = Rpc.new(function(bytes)
    ein:write(bytes)
  end)
  rpc:on_notification(function(method, args)
    if method == "redraw" then
      on_redraw(method, args)
    end
  end)
  eout:read_start(function(err, data)
    if err or not data then
      return
    end
    rpc:feed(data)
  end)
  rpc:request("nvim_ui_attach", { cols, rows, { rgb = true, ext_linegrid = true } }, function(err)
    if err ~= nil and err ~= vim.NIL then
      Log.write("attach", "nvim_ui_attach failed: " .. vim.inspect(err))
      -- The editor is spawned but will not draw; end the session like a
      -- refusal so the person is not left with a blank Surface.
      sprite_gone("attach failed")
    end
  end)
end

-- Read the socket: split newline-delimited JSON, decode, dispatch.
local function on_socket(err, data)
  if err then
    sprite_gone("socket error: " .. err)
    return
  end
  if not data then
    sprite_gone("socket closed")
    return
  end
  sock_buf = sock_buf .. data
  while true do
    local nl = sock_buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = sock_buf:sub(1, nl - 1)
    sock_buf = sock_buf:sub(nl + 1)
    Log.trace("<-surface", line)
    local ok, event = pcall(vim.json.decode, line)
    if ok and type(event) == "table" then
      on_surface_event(event)
    end
  end
end

-- Drain our own standard input for the whole session and discard it: the
-- editor's input arrives over the socket, and anything reaching the pty by
-- another route must not be left for the shell to read after we exit. In a
-- Sprite pane fd 0 is a tty; a pipe or file when run from a test or a script.
local function drain_stdin()
  local kind = uv.guess_handle(0)
  local stdin
  if kind == "tty" then
    stdin = uv.new_tty(0, true)
  else
    stdin = uv.new_pipe(false)
    local ok = pcall(function()
      stdin:open(0)
    end)
    if not ok then
      return
    end
  end
  if stdin then
    stdin:read_start(function() end)
  end
end

-- Connect, handshake, then read the first reply (opened or a refusal).
local function connect()
  if not (socket_path and key and pane) then
    fail_open("missing Surface credentials")
    return
  end
  sock:connect(socket_path, function(err)
    if err then
      fail_open("connect failed: " .. err)
      return
    end
    local open = {
      type = "open",
      version = 1,
      pane = pane,
      position = "fill",
      focus = true,
      description = { version = 1, root = { kind = "grid", cols = 80, rows = 24 } },
    }
    sock:write(key .. " " .. vim.json.encode(open) .. "\n")
    -- The very first line is the verdict; read it, then switch to the event loop.
    local first = ""
    sock:read_start(function(rerr, data)
      if rerr then
        fail_open("read failed: " .. rerr)
        return
      end
      if not data then
        fail_open("closed before opening")
        return
      end
      first = first .. data
      local nl = first:find("\n", 1, true)
      if not nl then
        return
      end
      local line = first:sub(1, nl - 1)
      local rest = first:sub(nl + 1)
      local ok, verdict = pcall(vim.json.decode, line)
      if not (ok and type(verdict) == "table" and verdict.type == "opened") then
        fail_open("open refused: " .. line)
        return
      end
      Log.write("handshake", "opened surface " .. tostring(verdict.surface))
      -- Hand the rest of the stream to the steady reader.
      sock:read_stop()
      sock_buf = rest
      -- Process anything already buffered, then read on.
      on_socket(nil, "")
      sock:read_start(on_socket)
    end)
  end)
end

drain_stdin()
connect()
uv.run()
os.exit(editor_exit or 0)
