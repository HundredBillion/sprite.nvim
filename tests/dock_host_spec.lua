local Host = dofile("tests/dock_host.lua")
local host = Host.start()
local sprite = require("sprite")
local context = assert(sprite.session.current())
T.eq(context.pane, host.pane, "real session preserves complete pane address")
local description = { version = 1, root = { kind = "virtual_list", row_height = 22 } }
local function open()
  local done, problem, handle = false
  sprite.open({ side = "right", width = 280, description = description }, function(e, h)
    problem, handle, done = e, h, true
  end)
  assert(
    vim.wait(3000, function()
      return done
    end),
    "dock request completes"
  )
  return problem, handle
end
for _ = 1, 2 do
  local problem, handle = open()
  T.eq(problem, nil, "native dock opens with addressed pane")
  assert(handle, vim.inspect(problem))
  local focused = false
  handle:focus_editor(function(e)
    T.eq(e, nil, "focus returns to editor")
    focused = true
  end)
  assert(
    vim.wait(3000, function()
      return focused
    end),
    "focus completes"
  )
  handle:close()
end
T.eq(#host:messages("open"), 2, "native dock reopens")
T.eq(host:messages("focus")[1].target, 77, "Surface target remains numeric")
host.refuse = true
local problem = open()
T.eq(problem and problem.code, "refused", "host refusal reaches caller")
host.refuse = false
vim.env.SPRITE_PANE = "other-window:0"
problem = open()
T.eq(problem and problem.code, "refused", "another window cannot own this dock")
vim.env.SPRITE_PANE = host.pane
local restored, handle = open()
T.eq(restored, nil, "native discovery recovers after refusal")
assert(handle):close()
host:close()
