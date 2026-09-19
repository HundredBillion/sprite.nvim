local Session = require("sprite.session")

local base = {
  path = "/tmp/sprite.sock",
  key = "secret",
  pane = "9",
  pid = 123,
  marker = nil,
  uis = { {} },
  stdin = "tty",
}
local function facts(changes)
  local result = vim.deepcopy(base)
  for key, value in pairs(changes) do
    result[key] = value
  end
  return result
end

local cases = {
  { "terminal tty", {}, "terminal", "terminal" },
  {
    "grid marker before UI attachment",
    { marker = { pid = 123, surface = 77 }, uis = {} },
    "grid",
    77,
  },
  { "missing path", { path = false } },
  { "missing key", { key = false } },
  { "malformed pane", { pane = "9x" } },
  { "zero pane", { pane = "0" } },
  { "stale marker cannot become terminal", { marker = { pid = 122, surface = 77 } } },
  { "invalid grid id", { marker = { pid = 123, surface = 0 } } },
  { "no attached UI", { uis = {} } },
  { "nested NVIM", { nvim = "/tmp/parent" } },
  { "tmux", { tmux = "/tmp/tmux" } },
  { "screen", { sty = "123.pts" } },
  { "pipe stdin", { stdin = "pipe" } },
  { "inherited environment cannot select grid", { uis = {}, stdin = "pipe" } },
}
for _, case in ipairs(cases) do
  local context = Session.resolve(facts(case[2]))
  T.eq(context and context.presentation, case[3], case[1] .. " presentation")
  if case[3] then
    T.eq(context.return_target, case[4], case[1] .. " target")
  end
end

local command = Session.bootstrap("/tmp/a b/it's", 77)
T.ok(command:find('runtimepath:prepend("/tmp/a b/it\'s")', 1, true) ~= nil, "bootstrap quotes path")
T.ok(command:find("pid=vim.fn.getpid(),surface=77", 1, true) ~= nil, "bootstrap sets process PID")
T.eq(Session.bootstrap("/tmp/a", 0), nil, "invalid surface refused")

do
  local original = Session.current
  local attached = false
  Session.current = function()
    if attached then
      return { presentation = "terminal" }
    end
    return nil, { code = "unavailable", message = "UI unavailable" }
  end
  local result
  Session.await_ui(vim.uv.now() + 2000, function(err, context)
    result = { err = err, context = context }
  end)
  attached = true
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(1000, function()
    return result ~= nil
  end, 10)
  T.eq(
    result and result.context and result.context.presentation,
    "terminal",
    "UIEnter completes pending initialization"
  )
  Session.current = original
end

do
  local original = Session.current
  Session.current = function()
    return nil, { code = "unavailable", message = "UI unavailable" }
  end
  local result
  Session.await_ui(vim.uv.now() + 30, function(err)
    result = err
  end)
  vim.wait(1000, function()
    return result ~= nil
  end, 10)
  T.eq(result and result.code, "unavailable", "missing UI expires within caller deadline")
  Session.current = original
end

do
  local original = Session.current
  Session.current = function()
    return { presentation = "grid" }
  end
  local called = false
  local cancel = Session.await_ui(vim.uv.now() + 2000, function()
    called = true
  end)
  cancel()
  vim.wait(30)
  T.eq(called, false, "cancelling also suppresses a scheduled completion")
  Session.current = original
end
