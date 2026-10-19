package.loaded["sprite.tabs"] = nil
local tabs = require("sprite.tabs")
local a = vim.api.nvim_create_buf(true, false)
local b = vim.api.nvim_create_buf(true, false)
local moved, destination
local state = { active = a, items = { { buffer = a, label = "a" }, { buffer = b, label = "b" } } }
tabs.setup({
  snapshot = function()
    return state
  end,
  reorder = function(buffer, before)
    moved, destination = buffer, before
    state.items = { state.items[2], state.items[1] }
    return true
  end,
})
local first = tabs.snapshot()
T.eq(first.reorderable, true, "only providers with a reorder callback opt in")
T.ok(
  tabs.dispatch({ revision = first.revision, id = "b" .. b, action = "reorder", before = "b" .. a })
)
T.eq(moved, b)
T.eq(destination, a, "destination is resolved from stable tab identity")
local changed = tabs.snapshot()
T.eq(changed.items[1].id, "b" .. b)
T.eq(changed.active, "b" .. a, "reordering keeps the selected file")
T.eq(
  tabs.dispatch({ revision = first.revision, id = "b" .. b, action = "reorder", before = vim.NIL }),
  false,
  "stale drags are rejected"
)
T.eq(
  tabs.dispatch({
    revision = changed.revision,
    id = "b" .. b,
    action = "reorder",
    before = "missing",
  }),
  false
)
T.eq(
  tabs.dispatch({ revision = changed.revision, id = "b" .. b, action = "reorder" }),
  false,
  "missing destination is rejected"
)
T.ok(
  tabs.dispatch({ revision = changed.revision, id = "b" .. b, action = "reorder", before = vim.NIL })
)
T.eq(destination, nil, "null destination moves a tab to the end")
tabs.setup({
  snapshot = function()
    return state
  end,
})
local unsupported = tabs.snapshot()
T.eq(unsupported.reorderable, false)
T.eq(
  tabs.dispatch({
    revision = unsupported.revision,
    id = "b" .. a,
    action = "reorder",
    before = vim.NIL,
  }),
  false
)
vim.api.nvim_buf_delete(a, { force = true })
vim.api.nvim_buf_delete(b, { force = true })
