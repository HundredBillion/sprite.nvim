local Statusline = require("sprite.statusline")
local previous_buffer = vim.api.nvim_get_current_buf()
local fixture = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(fixture)
local saved =
  { laststatus = vim.o.laststatus, statusline = vim.o.statusline, cmdheight = vim.o.cmdheight }
vim.o.laststatus = 3
vim.o.cmdheight = 0
vim.o.statusline = "%#ErrorMsg# NORMAL %#StatusLine#%=%l:%c  "
local snapshot = Statusline.snapshot(120)
T.eq(snapshot.type, "footer")
T.eq(snapshot.cols, 120, "statusline uses the full surface width")
T.eq(snapshot.row, vim.o.lines - 1)
local text = ""
for _, cell in ipairs(snapshot.cells) do
  text = text .. cell[1]:rep(cell[3] or 1)
end
T.eq(vim.fn.strdisplaywidth(text), 120)
T.ok(text:match("^ NORMAL ") ~= nil)
T.ok(text:match("0:0  $") ~= nil, "right-hand information reaches the full-width edge")
T.ok(vim.tbl_count(snapshot.define) >= 2, "mode badge keeps its highlight")
vim.o.statusline = "%#Underlined#界 é%=%#StatusLine#Ready"
local unicode = Statusline.snapshot(120)
T.eq(#unicode.cells, 120, "wide and combining characters keep cell positions")
T.eq(vim.fn.strdisplaywidth(unicode.source), vim.o.columns)
T.eq(unicode.define["1"].underline, "single")
vim.o.cmdheight = 1
T.eq(Statusline.snapshot(120).row, vim.o.lines - 2, "statusline moves above command area")
vim.o.laststatus = 2
T.eq(
  Statusline.snapshot(120),
  { type = "footer", visible = false },
  "window-local statuslines stay in the grid"
)
for name, value in pairs(saved) do
  vim.o[name] = value
end
vim.api.nvim_set_current_buf(previous_buffer)
vim.api.nvim_buf_delete(fixture, { force = true })
