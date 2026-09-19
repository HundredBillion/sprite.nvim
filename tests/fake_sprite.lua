-- A stand-in for Sprite: listens on a Unix socket, plays the handshake, sends a
-- resize, and records every line the adapter writes. Drives the real adapter in
-- a child `nvim -l` so the whole pipeline runs.
local uv = vim.uv
local M = {}

local function object(value)
  return type(value) == "table" and not vim.islist(value)
end

local function integer(value)
  return type(value) == "number" and value >= 0 and value == math.floor(value)
end

function M.validate(message, state)
  state = state or {}
  if type(message) ~= "table" or type(message.type) ~= "string" then
    return nil, "message needs type"
  end
  if message.type == "capabilities" then
    if
      message.version ~= 1
      or not integer(message.pane)
      or not integer(message.owner_pid)
      or message.owner_pid == 0
      or (message.return_target ~= "terminal" and not integer(message.return_target))
    then
      return nil, "capabilities needs version, pane, owner and return target"
    end
  elseif message.type == "open" then
    if
      message.version ~= 1
      or not integer(message.pane)
      or not integer(message.owner_pid)
      or message.owner_pid == 0
      or not object(message.description)
      or type(message.focus) ~= "boolean"
      or (message.position ~= "fill" and message.position ~= "dock")
    then
      return nil, "open needs version, pane, owner and description"
    end
    if
      message.position == "dock"
      and (
        message.side ~= "left" and message.side ~= "right"
        or not integer(message.size)
        or message.return_target == nil
      )
    then
      return nil, "dock needs side, size and return target"
    end
  elseif message.type == "batch" then
    if type(message.ops) ~= "table" or not vim.islist(message.ops) then
      return nil, "batch needs ops"
    end
    for _, op in ipairs(message.ops) do
      if op.type == "rows" then
        for _, row in ipairs(op.rows or {}) do
          if not integer(row.row) or not integer(row.col) or type(row.cells) ~= "table" then
            return nil, "invalid row chunk"
          end
          for _, cell in ipairs(row.cells) do
            local repeat_count = cell[3] or 1
            if
              type(cell[1]) ~= "string"
              or not integer(repeat_count)
              or repeat_count < 1
              or repeat_count > 1024
            then
              return nil, "a cell's repeat is 1 to 1024"
            end
          end
        end
      elseif op.type == "highlights" and op.define then
        for _, attrs in pairs(op.define) do
          if not object(attrs) then
            return nil, "highlight attrs need object"
          end
        end
      end
    end
  elseif message.type == "assets" then
    if not object(message.entries) then
      return nil, "assets needs entries object"
    end
  elseif message.type == "update" then
    if not object(message.description) then
      return nil, "update needs description object"
    end
  elseif message.type == "focus" then
    if not integer(message.pane) or message.target == nil then
      return nil, "focus needs pane and target"
    end
  elseif message.type == "token" then
    if
      type(message.name) ~= "string"
      or type(message.default) ~= "string"
      or type(message.description) ~= "string"
    then
      return nil, "token needs name, default and description"
    end
  elseif message.type == "list_rows" then
    if
      not integer(message.revision)
      or message.revision < 1
      or not vim.islist(message.rows)
      or message.selected == nil
    then
      return nil, "list_rows needs revision, rows and selected"
    end
    if state.revision and message.revision <= state.revision then
      return nil, "rows revision must increase"
    end
    local ids = {}
    for _, row in ipairs(message.rows) do
      if
        not object(row)
        or type(row.id) ~= "string"
        or row.id == ""
        or type(row.text) ~= "string"
        or type(row.indent) ~= "number"
        or not vim.islist(row.guides)
      then
        return nil, "invalid list row"
      end
      if ids[row.id] then
        return nil, "duplicate row id"
      end
      ids[row.id] = true
    end
    if message.selected ~= vim.NIL and not ids[message.selected] then
      return nil, "selected row missing"
    end
    state.revision, state.ids = message.revision, ids
  elseif message.type == "list_state" then
    if message.revision ~= state.revision then
      return nil, "state revision differs from rows"
    end
    if message.scroll ~= nil and message.reveal ~= nil then
      return nil, "state cannot scroll and reveal"
    end
    for _, key in ipairs({ "selected", "reveal" }) do
      if message[key] ~= nil and message[key] ~= vim.NIL and not state.ids[message[key]] then
        return nil, key .. " row missing"
      end
    end
    if
      message.scroll ~= nil and (not object(message.scroll) or not state.ids[message.scroll.id])
    then
      return nil, "scroll row missing"
    end
  end
  return true
end

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
          local payload = line:match("^[^ ]+ (.+)$")
          if payload then
            self.first_open = vim.json.decode(payload)
          end
          local valid, reason = M.validate(self.first_open)
          if opts.refuse_capabilities and self.first_open.type == "capabilities" then
            self.send({ type = "refused", reason = "capabilities unavailable" })
          elseif not valid then
            self.invalid = reason
            self.send({ type = "refused", reason = reason })
          elseif opts.refuse then
            self.send({ type = "refused", reason = "test refuses" })
          elseif self.first_open.type == "capabilities" then
            self.send({
              type = "capabilities",
              version = 1,
              eligible = true,
              features = {},
              limits = {},
            })
          else
            self.send({ type = "opened", surface = opts.surface or 1 })
            self.send({ type = "resize", width = 640, height = 384, cols = 80, rows = 24 })
          end
        else
          self.lines[#self.lines + 1] = line
          local ok, message = pcall(vim.json.decode, line)
          local valid, reason
          if ok then
            valid, reason = M.validate(message, self)
          else
            reason = "invalid JSON"
          end
          if not valid then
            self.invalid = reason
            self.send({ type = "refused", reason = reason })
          elseif opts.ack_delay_ms and message.type == "assets" then
            vim.defer_fn(function()
              if conn and not conn:is_closing() then
                self.send({ type = "applied", operation = "assets" })
              end
            end, opts.ack_delay_ms)
          end
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
