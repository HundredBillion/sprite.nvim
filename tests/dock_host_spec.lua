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

-- A dock under the editor: sized by its height, and only on a host that has one.
local function open_bottom(options)
  local done, failure, dock = false
  sprite.open(
    vim.tbl_extend(
      "force",
      { side = "bottom", height = 240, description = { version = 1, root = { kind = "box" } } },
      options or {}
    ),
    function(e, h)
      failure, dock, done = e, h, true
    end
  )
  assert(
    vim.wait(3000, function()
      return done
    end),
    "bottom dock request completes"
  )
  return failure, dock
end
local opened_before = #host:messages("open")
local unsupported = open_bottom()
T.eq(
  unsupported and unsupported.code,
  "unsupported",
  "a host without a bottom dock is not asked for one"
)
T.eq(#host:messages("open"), opened_before, "and nothing is opened at a side instead")
host.features = { "dock-bottom-v1" }
local bottom_problem, bottom = open_bottom()
T.eq(bottom_problem, nil, "a bottom dock opens on a host that has one")
local sent = host:messages("open")
T.eq(sent[#sent].side, "bottom", "the dock is asked for at the bottom")
T.eq(sent[#sent].size, 240, "its size is its height")
assert(bottom):close()
T.eq((open_bottom({ height = 8 })).code, "protocol", "a bottom dock needs a sensible height")
T.eq((open_bottom({ height = false, width = 300 })).code, "protocol", "and is not sized by a width")
host.features = nil
host:close()

local invalid_host = Host.start()
local refused = false
require("sprite.channel").connect({
  path = vim.env.SPRITE_SURFACE_SOCKET,
  key = vim.env.SPRITE_SURFACE_KEY,
  timeout_ms = 2000,
  first = { type = "list_rows", revision = 1, rows = "invalid", selected = vim.NIL },
}, function(problem)
  refused = problem and problem.code == "refused"
end)
assert(
  vim.wait(3000, function()
    return refused
  end),
  "invalid traffic is refused"
)
T.eq(
  pcall(function()
    invalid_host:messages("list_rows")
  end),
  false,
  "async failure fails row assertion"
)
T.eq(#invalid_host.requests, 0, "invalid traffic cannot satisfy delivery checks")
T.eq(
  pcall(function()
    invalid_host:close()
  end),
  false,
  "async failure fails test after cleanup"
)
