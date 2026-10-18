package.loaded["sprite.tabs"] = nil
local tabs = require("sprite.tabs")
local a = vim.api.nvim_create_buf(true, false)
local b = vim.api.nvim_create_buf(true, false)
local selected, closed
local state = {
  active = a,
  items = {
    { buffer = a, label = "a%文件.lua", modified = true, icon = "<svg/>" },
    { buffer = b, label = "b.lua" },
  },
}
tabs.setup({
  snapshot = function()
    return state
  end,
  select = function(buffer)
    selected = buffer
  end,
  close = function(buffer)
    closed = buffer
  end,
})
local first = tabs.snapshot()
T.eq(first.active, "b" .. a, "active buffer uses stable id")
T.eq(first.items[1].label, "a%文件.lua", "literal unicode and percent labels")
T.eq(first.items[1].icon, "<svg/>", "SVG travels intact")
T.eq(tabs.snapshot(), vim.NIL, "unchanged state is coalesced")
T.ok(tabs.dispatch({ revision = first.revision, id = "b" .. b, action = "select" }))
T.eq(selected, b, "select dispatches buffer identity")
state.active = b
local second = tabs.snapshot()
T.ok(second.revision > first.revision)
T.eq(
  tabs.dispatch({ revision = first.revision, id = "b" .. a, action = "close" }),
  false,
  "stale close ignored"
)
T.eq(closed, nil)
T.eq(tabs.dispatch({ revision = second.revision, id = "b999999", action = "close" }), false)
T.ok(tabs.dispatch({ revision = second.revision, id = "b" .. a, action = "close" }))
T.eq(closed, a)
state.items[1].label = string.rep("文", 600)
state.items[1].icon = string.rep("x", 65537)
local bounded = tabs.snapshot()
T.ok(#bounded.items[1].label <= 1024)
T.eq(#bounded.items[1].label % 3, 0, "UTF8 truncation preserves characters")
T.eq(bounded.items[1].icon, nil, "oversize icon omitted")
vim.api.nvim_buf_delete(a, { force = true })
vim.api.nvim_buf_delete(b, { force = true })
