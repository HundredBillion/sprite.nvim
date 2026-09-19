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

local function bounded(value, minimum, maximum)
  return type(value) == "number"
    and value == value
    and value ~= math.huge
    and value ~= -math.huge
    and value >= minimum
    and value <= maximum
end

local function label(value)
  return type(value) == "string" and #value > 0 and #value <= 4096
end

local function grid_index(value)
  return integer(value) and value <= 65535
end

local function color(value)
  return value == nil
    or value == vim.NIL
    or type(value) == "string" and value:match("^#%x%x%x%x%x%x$") ~= nil
end

local function remember_row_height(state, description)
  local root = description.root
  if object(root) and root.kind == "virtual_list" and bounded(root.row_height, 12, 128) then
    state.row_height = root.row_height
  end
end

local function grid_op(op)
  if not object(op) then
    return nil, "grid operation needs object"
  end
  if op.type == "rows" then
    if not vim.islist(op.rows) then
      return nil, "rows needs array"
    end
    for _, row in ipairs(op.rows) do
      if
        not object(row)
        or not grid_index(row.row)
        or row.col ~= nil and not grid_index(row.col)
        or not vim.islist(row.cells)
      then
        return nil, "invalid row chunk"
      end
      for _, cell in ipairs(row.cells) do
        if
          not vim.islist(cell)
          or #cell < 1
          or #cell > 3
          or type(cell[1]) ~= "string"
          or cell[2] ~= nil and (not integer(cell[2]) or cell[2] > 4294967295)
        then
          return nil, "invalid cell"
        end
        local repeat_count = cell[3] or 1
        if not integer(repeat_count) or repeat_count < 1 or repeat_count > 1024 then
          return nil, "a cell's repeat is 1 to 1024"
        end
      end
    end
  elseif op.type == "highlights" then
    for _, key in ipairs({ "define", "groups" }) do
      if op[key] ~= nil and not object(op[key]) then
        return nil, "highlights " .. key .. " needs object"
      end
    end
    for id, attrs in pairs(op.define or {}) do
      if
        type(id) ~= "string"
        or not id:match("^%d+$")
        or not integer(tonumber(id))
        or tonumber(id) < 1
        or tonumber(id) > 4294967295
        or not object(attrs)
      then
        return nil, "invalid highlight definition"
      end
      for _, key in ipairs({ "fg", "bg", "sp" }) do
        if not color(attrs[key]) then
          return nil, "invalid highlight color"
        end
      end
      for _, key in ipairs({ "bold", "italic", "reverse", "strikethrough" }) do
        if attrs[key] ~= nil and type(attrs[key]) ~= "boolean" then
          return nil, "invalid highlight flag"
        end
      end
    end
    for _, id in pairs(op.groups or {}) do
      if not integer(id) or id > 4294967295 then
        return nil, "invalid highlight group"
      end
    end
  elseif op.type == "cursor" then
    if
      not grid_index(op.row)
      or not grid_index(op.col)
      or op.shape ~= nil and not ({ block = true, bar = true, underline = true, hollow = true })[op.shape]
      or op.visible ~= nil and type(op.visible) ~= "boolean"
      or op.blink ~= nil and type(op.blink) ~= "boolean"
    then
      return nil, "invalid cursor"
    end
  elseif op.type == "resize" then
    if not grid_index(op.cols) or not grid_index(op.rows) then
      return nil, "invalid resize"
    end
  elseif op.type == "scroll" then
    if
      not grid_index(op.top)
      or not grid_index(op.bot)
      or not grid_index(op.left)
      or not grid_index(op.right)
      or type(op.rows) ~= "number"
      or op.rows ~= math.floor(op.rows)
      or op.rows < -2147483648
      or op.rows > 2147483647
    then
      return nil, "invalid scroll"
    end
  elseif op.type == "defaults" then
    for _, key in ipairs({ "fg", "bg", "sp" }) do
      if not color(op[key]) then
        return nil, "invalid default color"
      end
    end
    return true
  elseif op.type == "clear" then
    return true
  else
    return nil, "unknown grid operation"
  end
  return true
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
    remember_row_height(state, message.description)
  elseif message.type == "batch" then
    if not vim.islist(message.ops) then
      return nil, "batch needs ops"
    end
    for _, op in ipairs(message.ops) do
      local valid, reason = grid_op(op)
      if not valid then
        return nil, reason
      end
    end
  elseif message.type == "assets" then
    if not object(message.entries) then
      return nil, "assets needs entries object"
    end
    for id, svg in pairs(message.entries) do
      if not label(id) or type(svg) ~= "string" or not svg:match("^%s*<svg") then
        return nil, "invalid SVG asset"
      end
    end
  elseif message.type == "update" then
    if not object(message.description) then
      return nil, "update needs description object"
    end
    remember_row_height(state, message.description)
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
      or message.revision > 9007199254740991
      or not vim.islist(message.rows)
      or #message.rows > 100000
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
        or not label(row.id)
        or not label(row.text)
        or not bounded(row.indent, 0, 16384)
        or not vim.islist(row.guides)
        or #row.guides > 64
        or row.icon ~= nil and not label(row.icon)
        or row.leading ~= nil and not label(row.leading)
      then
        return nil, "invalid list row"
      end
      for _, guide in ipairs(row.guides) do
        if not bounded(guide, 0, 16384) then
          return nil, "invalid guide"
        end
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
    if
      message.revision ~= state.revision
      or not integer(message.revision)
      or message.revision > 9007199254740991
    then
      return nil, "state revision differs from rows"
    end
    if message.scroll ~= nil and message.reveal ~= nil then
      return nil, "state cannot scroll and reveal"
    end
    if message.status ~= nil and message.status ~= vim.NIL and type(message.status) ~= "string" then
      return nil, "invalid status"
    end
    for _, key in ipairs({ "selected", "reveal" }) do
      if message[key] ~= nil and message[key] ~= vim.NIL and not state.ids[message[key]] then
        return nil, key .. " row missing"
      end
    end
    if message.scroll ~= nil then
      local row_height = state.row_height or 128
      local max_offset = row_height - row_height * 1.1920928955078125e-7
      if
        not object(message.scroll)
        or not state.ids[message.scroll.id]
        or not bounded(message.scroll.offset, 0, max_offset)
      then
        return nil, "invalid scroll anchor"
      end
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
            local ok, decoded = pcall(vim.json.decode, payload)
            if ok then
              self.first_open = decoded
            end
          end
          local valid, reason = M.validate(self.first_open, self)
          if not valid then
            self.invalid = reason
            self.send({ type = "refused", reason = reason })
          elseif opts.refuse_capabilities and self.first_open.type == "capabilities" then
            self.send({ type = "refused", reason = "capabilities unavailable" })
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
