local Redraw = dofile(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/lua/sprite/redraw.lua"
)

-- grid_line -> a rows op with the same cells; hl carries across, repeat kept.
do
  local s = Redraw.new()
  -- {grid, row, col_start, cells, wrap}; cells: {text}, {text,hl}, {text,hl,repeat}
  s:event({ "grid_line", { 1, 2, 0, { { "a", 5 }, { "b" }, { " ", 0, 3 } }, false } })
  s:event({ "flush" })
  T.eq(s:take_batch(), {
    {
      type = "rows",
      rows = { { row = 2, col = 0, cells = { { "a", 5 }, { "b" }, { " ", 0, 3 } } } },
    },
  }, "grid_line becomes rows with cells verbatim")
end

-- hl_attr_define -> highlights.define with colours as #rrggbb and underline kind.
do
  local s = Redraw.new()
  s:event({
    "hl_attr_define",
    { 7, { foreground = 0xcba6f7, bold = true, undercurl = true, special = 0xf38ba8 }, {}, {} },
  })
  s:event({ "flush" })
  T.eq(s:take_batch(), {
    {
      type = "highlights",
      define = { ["7"] = { fg = "#cba6f7", bold = true, sp = "#f38ba8", underline = "curly" } },
    },
  }, "hl_attr_define maps colours and undercurl")
end

-- hl_group_set -> highlights.groups.
do
  local s = Redraw.new()
  s:event({ "hl_group_set", { "Comment", 7 } })
  s:event({ "flush" })
  T.eq(
    s:take_batch(),
    { { type = "highlights", groups = { Comment = 7 } } },
    "hl_group_set maps a group name to an id"
  )
end

-- default_colors_set -> defaults, -1 dropped.
do
  local s = Redraw.new()
  s:event({ "default_colors_set", { 0xcdd6f4, 0x1e1e2e, -1, 0, 0 } })
  s:event({ "flush" })
  T.eq(
    s:take_batch(),
    { { type = "defaults", fg = "#cdd6f4", bg = "#1e1e2e" } },
    "default_colors_set maps fg/bg, drops -1 sp"
  )
end

-- cursor: goto sets row/col; mode_change sets shape+blink from mode_info;
-- every cursor op carries the current row and col.
do
  local s = Redraw.new()
  s:event({
    "mode_info_set",
    {
      true,
      {
        { name = "normal", cursor_shape = "block", blinkon = 0, blinkoff = 0 },
        { name = "insert", cursor_shape = "vertical", blinkon = 400, blinkoff = 250 },
      },
    },
  })
  s:event({ "grid_cursor_goto", { 1, 4, 9 } })
  s:event({ "mode_change", { "insert", 1 } })
  s:event({ "flush" })
  T.eq(s:take_batch(), {
    { type = "cursor", row = 4, col = 9, shape = "block", visible = true, blink = false },
    { type = "cursor", row = 4, col = 9, shape = "bar", visible = true, blink = true },
  }, "cursor tracks position and mode-driven shape/blink")
end

-- busy_start/stop toggle visibility, still carrying row/col.
do
  local s = Redraw.new()
  s:event({ "grid_cursor_goto", { 1, 1, 1 } })
  s:event({ "busy_start" })
  s:event({ "flush" })
  T.eq(
    s:take_batch(),
    { { type = "cursor", row = 1, col = 1, shape = "block", visible = false, blink = false } },
    "busy_start hides the cursor"
  )
end

-- grid_scroll/clear/resize map to their namesakes; grid 1 fields passed through.
do
  local s = Redraw.new()
  s:event({ "grid_resize", { 1, 80, 24 } })
  s:event({ "grid_scroll", { 1, 0, 24, 0, 80, 3, 0 } })
  s:event({ "grid_clear", { 1 } })
  s:event({ "flush" })
  T.eq(s:take_batch(), {
    { type = "resize", cols = 80, rows = 24 },
    { type = "scroll", top = 0, bot = 24, left = 0, right = 80, rows = 3 },
    { type = "clear" },
  }, "scroll/clear/resize map across")
end

-- Unknown and dropped events produce nothing; an empty batch is nil.
do
  local s = Redraw.new()
  s:event({ "set_title", { "x" } })
  s:event({ "win_viewport", { 1, 2, 0, 10, 0, 5 } })
  s:event({ "mouse_on" })
  s:event({ "flush" })
  T.eq(s:take_batch(), nil, "dropped events yield no ops")
end
