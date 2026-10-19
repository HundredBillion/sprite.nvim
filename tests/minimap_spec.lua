package.loaded["sprite.minimap"] = nil
local bridge = require("sprite.minimap")
T.eq(bridge.pull(), vim.NIL, "absent provider does no work")
local fixture =
  vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/minimap-v1.json"), "\n"))
local index, received, stopped = 0, 0, 0
bridge.setup({
  next = function()
    index = index + 1
    return fixture.valid[index]
  end,
  dispatch = function()
    received = received + 1
    return true
  end,
  before_input = function() end,
  stop = function()
    stopped = stopped + 1
  end,
})
T.eq(
  bridge.dispatch({
    type = "minimap_action",
    target = "old",
    generation = 1,
    revision = 1,
    action = "reveal",
    line = 1,
  }),
  false
)
T.eq(received, 0)
local messages = {}
for i = 1, 4 do
  messages[i] = bridge.pull()
end
for i, message in ipairs(messages) do
  T.eq(message.target, fixture.valid[i].target, "source identity survives transport")
  if i > 1 then
    T.ok(message.revision > messages[i - 1].revision, "bridge revisions increase")
  end
end
local commit = messages[3]
T.ok(bridge.dispatch({
  type = "minimap_action",
  target = commit.target,
  generation = commit.generation,
  revision = commit.revision,
  action = "reveal",
  line = 3,
}))
T.eq(received, 1)
T.eq(bridge.pull().kind, "hide")
T.eq(bridge.pull(), vim.NIL)
bridge.setup(nil)
T.eq(stopped, 1, "replacement stops provider")
local old_input = vim.api.nvim_input
local ordered = {}
vim.api.nvim_input = function(keys)
  ordered[#ordered + 1] = keys
  return #keys
end
bridge.setup({
  next = function()
    return nil
  end,
  stop = function() end,
  before_input = function(event)
    ordered[#ordered + 1] = event.key
    error("hook failure")
  end,
})
T.eq(bridge.input("nvim_input", { "x" }, { type = "input", key = "hook" }), 1)
T.eq(ordered, { "hook", "x" }, "callback failure still delivers original input exactly once")
T.eq(
  bridge.input("nvim_command", { "quit" }, {}),
  false,
  "input wrapper rejects executable methods"
)
T.eq(
  bridge.input("nvim_ui_try_resize", { 60, 18 }, { type = "resize" }),
  false,
  "RPC-only resize stays outside Lua input wrapper"
)
T.eq(
  bridge.input("nvim_ui_set_focus", { true }, { type = "focus" }),
  false,
  "RPC-only focus stays outside Lua input wrapper"
)
vim.api.nvim_input = old_input
T.eq(bridge.pull().kind, "hide", "provider failure hides only minimap")
bridge.attach(nil)
bridge.setup(nil)
local notify = vim.rpcnotify
local notifications = {}
vim.rpcnotify = function(id, name)
  notifications[#notifications + 1] = { id, name }
end
bridge.attach(123)
for _ = 1, 20 do
  bridge.changed()
end
vim.wait(50, function()
  return #notifications > 0
end)
T.eq(notifications, { { 123, "sprite_minimap_changed" } }, "changed notifications coalesce")
notifications = {}
bridge.changed()
bridge.attach(nil)
vim.wait(20, function()
  return false
end)
T.eq(notifications, {}, "detach cancels queued notification")
vim.rpcnotify = notify
local count, busy = 0, false
local position = 0
local provider = {
  next = function()
    position = position + 1
    return fixture.valid[position]
  end,
  dispatch = function()
    count = count + 1
  end,
  stop = function() end,
  target = function()
    return { target = fixture.valid[1].target, generation = 1, busy = busy }
  end,
}
bridge.setup(provider)
local start = bridge.pull()
bridge.pull()
local current = bridge.pull()
local state = bridge.pull()
T.ok(start.revision > commit.revision, "provider replacement does not reset revision")
local action = {
  type = "minimap_action",
  target = current.target,
  generation = current.generation,
  revision = current.revision,
  action = "scroll",
  topline = 1,
}
T.ok(bridge.dispatch(action), "commit revision remains valid through state progress")
for _, mutation in ipairs({
  { revision = current.revision - 1 },
  { revision = state.revision + 1 },
  { topline = 0 },
  { topline = 1.5 },
  { topline = 4 },
  { generation = 2 },
  { target = "old" },
  { unknown = true },
  { line = 1 },
  { action = "execute" },
}) do
  local invalid = vim.tbl_extend("force", action, mutation)
  T.eq(bridge.dispatch(invalid), false, "invalid action rejected before provider dispatch")
end
busy = true
T.eq(
  bridge.dispatch(action),
  false,
  "source extraction blocks stale actions before provider dispatch"
)
T.eq(count, 1)
bridge.setup(nil)
bridge.pull()

for _, host_ack in ipairs({ false, true }) do
  for _, provider_ack in ipairs({ false, true }) do
    local step = 0
    local seen
    bridge.setup({
      acknowledge_actions = provider_ack,
      next = function()
        step = step + 1
        return vim.deepcopy(fixture.valid[step])
      end,
      dispatch = function(event)
        seen = event
        return true
      end,
      stop = function() end,
    })
    bridge.attach(nil, host_ack)
    local begin = bridge.pull()
    if begin.kind == "hide" then
      begin = bridge.pull()
    end
    T.eq(
      begin.action_ack,
      host_ack and provider_ack or nil,
      "action acknowledgments require host and provider opt-in"
    )
    local commit
    repeat
      commit = bridge.pull()
    until commit.kind == "commit"
    local action = {
      type = "minimap_action",
      target = commit.target,
      generation = commit.generation,
      revision = commit.revision,
      action = "scroll",
      topline = 1,
      action_id = 17,
    }
    T.eq(bridge.dispatch(action), host_ack and provider_ack, "unnegotiated action id rejected")
    if host_ack and provider_ack then
      T.eq(seen.action_id, 17)
      action.action_id = 0
      T.eq(bridge.dispatch(action), false)
      action.action_id = 9007199254740992
      T.eq(bridge.dispatch(action), false)
    end
    bridge.setup(nil)
  end
end
