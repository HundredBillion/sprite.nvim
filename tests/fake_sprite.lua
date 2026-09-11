-- A stand-in for Sprite: listens on a Unix socket, plays the handshake, sends a
-- resize, and records every line the adapter writes. Drives the real adapter in
-- a child `nvim -l` so the whole pipeline runs.
local uv = vim.uv
local M = {}

-- Starts a server at `path`. `opts.refuse` sends a refusal instead of opening.
-- Calls `opts.on_line(line)` for every line the adapter sends. Returns a table
-- with `send(obj)` and `close()`.
function M.serve(path, opts)
  opts = opts or {}
  os.remove(path)
  local server = uv.new_pipe(false)
  server:bind(path)
  local conn
  local self = { lines = {} }
  local buf = ""

  function self.send(obj)
    conn:write(vim.json.encode(obj) .. "\n")
  end
  function self.close()
    if conn then
      conn:close()
    end
    server:close()
    os.remove(path)
  end

  server:listen(16, function()
    conn = uv.new_pipe(false)
    server:accept(conn)
    conn:read_start(function(err, data)
      if err or not data then
        return
      end
      buf = buf .. data
      while true do
        local nl = buf:find("\n", 1, true)
        if not nl then
          break
        end
        local line = buf:sub(1, nl - 1)
        buf = buf:sub(nl + 1)
        if not self.opened then
          -- The first line is "<key> <open json>"; answer it.
          self.opened = true
          if opts.refuse then
            self.send({ type = "refused", reason = "test refuses" })
          else
            self.send({ type = "opened", surface = 1 })
            self.send({ type = "resize", width = 640, height = 384, cols = 80, rows = 24 })
          end
        else
          self.lines[#self.lines + 1] = line
          if opts.on_line then
            opts.on_line(line)
          end
        end
      end
    end)
  end)
  return self
end

return M
