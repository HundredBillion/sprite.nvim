-- Pure translation of Neovim's ext_linegrid redraw events into Sprite grid
-- operations. The only state is the cursor and the mode table, both copies of
-- what Neovim sent; there is no model of the screen's contents.
local Redraw = {}
Redraw.__index = Redraw

local function color(n)
  if type(n) ~= "number" or n < 0 then
    return nil
  end
  return string.format("#%06x", n)
end

-- Neovim spells cursor shape as block/horizontal/vertical; Sprite as
-- block/underline/bar. Sprite also has "hollow", which no mode reports.
local SHAPE = { block = "block", horizontal = "underline", vertical = "bar" }

function Redraw.new()
  return setmetatable({
    ops = {},
    mode_info = {},
    cursor = { row = 0, col = 0, shape = "block", visible = true, blink = false },
  }, Redraw)
end

function Redraw:take_batch()
  if #self.ops == 0 then
    return nil
  end
  local ops = self.ops
  self.ops = {}
  return ops
end

-- A complete cursor op from current state; Sprite requires row and col always.
function Redraw:emit_cursor()
  local c = self.cursor
  self.ops[#self.ops + 1] = {
    type = "cursor",
    row = c.row,
    col = c.col,
    shape = c.shape,
    visible = c.visible,
    blink = c.blink,
  }
end

-- Like emit_cursor, but a pure visibility toggle (busy_start/busy_stop) rides
-- on whatever cursor op is already pending rather than adding a new one: it
-- carries no information beyond "hide/show at the last known position", so if
-- the tail of the batch is already a cursor op, update it in place instead of
-- emitting a second one. A position (grid_cursor_goto) or mode (mode_change)
-- update is a distinct, meaningful transition and always gets its own op.
function Redraw:update_cursor_visibility()
  local c = self.cursor
  local last = self.ops[#self.ops]
  if last and last.type == "cursor" then
    last.row, last.col, last.shape, last.visible, last.blink =
      c.row, c.col, c.shape, c.visible, c.blink
  else
    self:emit_cursor()
  end
end

local handlers = {}

function handlers.grid_line(self, t)
  -- t = {grid, row, col_start, cells, wrap}. Cells are already [text],
  -- [text,hl], or [text,hl,repeat] — exactly Sprite's cell tuple.
  self.ops[#self.ops + 1] = { type = "rows", rows = { { row = t[2], col = t[3], cells = t[4] } } }
end

function handlers.hl_attr_define(self, t)
  local id, rgb = t[1], t[2] or {}
  local attrs = {}
  attrs.fg = color(rgb.foreground)
  attrs.bg = color(rgb.background)
  attrs.sp = color(rgb.special)
  if rgb.bold then
    attrs.bold = true
  end
  if rgb.italic then
    attrs.italic = true
  end
  if rgb.reverse then
    attrs.reverse = true
  end
  if rgb.strikethrough then
    attrs.strikethrough = true
  end
  if rgb.undercurl then
    attrs.underline = "curly"
  elseif rgb.underdouble then
    attrs.underline = "double"
  elseif rgb.underdotted then
    attrs.underline = "dotted"
  elseif rgb.underdashed then
    attrs.underline = "dashed"
  elseif rgb.underline then
    attrs.underline = "single"
  end
  self.ops[#self.ops + 1] = { type = "highlights", define = { [tostring(id)] = attrs } }
end

function handlers.hl_group_set(self, t)
  self.ops[#self.ops + 1] = { type = "highlights", groups = { [t[1]] = t[2] } }
end

function handlers.default_colors_set(self, t)
  self.ops[#self.ops + 1] =
    { type = "defaults", fg = color(t[1]), bg = color(t[2]), sp = color(t[3]) }
end

function handlers.mode_info_set(self, t)
  self.mode_info = t[2] or {}
end

function handlers.mode_change(self, t)
  local info = self.mode_info[(t[2] or 0) + 1]
  if info then
    self.cursor.shape = SHAPE[info.cursor_shape] or "block"
    self.cursor.blink = (info.blinkon or 0) > 0 and (info.blinkoff or 0) > 0
  end
  self:emit_cursor()
end

function handlers.grid_cursor_goto(self, t)
  self.cursor.row, self.cursor.col = t[2], t[3]
  self:emit_cursor()
end

function handlers.busy_start(self)
  self.cursor.visible = false
  self:update_cursor_visibility()
end

function handlers.busy_stop(self)
  self.cursor.visible = true
  self:update_cursor_visibility()
end

function handlers.grid_resize(self, t)
  self.ops[#self.ops + 1] = { type = "resize", cols = t[2], rows = t[3] }
end

function handlers.grid_scroll(self, t)
  self.ops[#self.ops + 1] =
    { type = "scroll", top = t[2], bot = t[3], left = t[4], right = t[5], rows = t[6] }
end

function handlers.grid_clear(self)
  self.ops[#self.ops + 1] = { type = "clear" }
end

-- One redraw event: {name, tuple, tuple, ...}. Each tuple is applied in order;
-- an event with no known handler is dropped. `flush` and colour of dropped
-- names (set_title, bell, ...) fall through to nothing here.
function Redraw:event(event)
  local handler = handlers[event[1]]
  if not handler then
    return
  end
  if #event == 1 then
    handler(self)
  else
    for i = 2, #event do
      handler(self, event[i])
    end
  end
end

return Redraw
