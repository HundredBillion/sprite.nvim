local Session = require("sprite.session")

local base = {
  path = "/tmp/sprite.sock",
  key = "secret",
  pane = "9",
  pid = 123,
  marker = nil,
  uis = { {} },
  ui_owner_pid = 456,
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
  { "pane zero terminal", { pane = "0" }, "terminal", "terminal" },
  { "pane zero grid", { pane = "0", marker = { pid = 123, surface = 77 }, uis = {} }, "grid", 77 },
  { "negative pane", { pane = "-1" } },
  { "stale marker cannot become terminal", { marker = { pid = 122, surface = 77 } } },
  { "invalid grid id", { marker = { pid = 123, surface = 0 } } },
  { "no attached UI", { uis = {} } },
  { "terminal UI has no owner metadata", { ui_owner_pid = false } },
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
    T.eq(context and context.return_target, case[4], case[1] .. " target")
  end
end

do
  local terminal = Session.resolve(facts({}))
  T.eq(terminal and terminal.pid, 456, "terminal uses attached UI owner PID")
  local grid = Session.resolve(facts({ marker = { pid = 123, surface = 77 }, ui_owner_pid = 456 }))
  T.eq(grid and grid.pid, 123, "grid retains editor process PID")
end

do
  local ui = { { chan = 1, stdin_tty = true, stdout_tty = true } }
  local function channel(id)
    T.eq(id, 1, "attached terminal UI channel queried")
    return { client = { type = "ui", name = "nvim-tui", attributes = { pid = 456 } } }
  end
  T.eq(Session.terminal_ui_owner(ui, channel), 456, "terminal UI metadata identifies owner")
  T.eq(
    Session.terminal_ui_owner({ { chan = 1, stdin_tty = false, stdout_tty = false } }, channel),
    nil,
    "nonterminal UI cannot own dock"
  )
  T.eq(
    Session.terminal_ui_owner(ui, function()
      return { client = { type = "remote", attributes = { pid = 456 } } }
    end),
    nil,
    "non-UI client cannot own dock"
  )
  T.eq(
    Session.terminal_ui_owner(ui, function()
      return { client = { type = "ui", attributes = {} } }
    end),
    nil,
    "missing UI PID fails closed"
  )
end

local command = Session.bootstrap("/tmp/a b/it's", 77)
T.ok(command:find('runtimepath:prepend("/tmp/a b/it\'s")', 1, true) ~= nil, "bootstrap quotes path")
T.ok(command:find("pid=vim.fn.getpid(),surface=77", 1, true) ~= nil, "bootstrap sets process PID")
T.eq(Session.bootstrap("/tmp/a", 0), nil, "invalid surface refused")

do
  local largest = 9007199254740991
  local bootstrap = Session.bootstrap("/tmp/a", largest)
  local previous = vim.g.sprite_session
  assert(loadstring(bootstrap:sub(5)))()
  T.eq(vim.g.sprite_session.surface, largest, "bootstrap preserves largest safe Surface id")
  vim.g.sprite_session = previous
end

do
  local original = Session.current
  Session.current = function()
    return { presentation = "grid" }
  end
  local result
  Session.await_ui(vim.uv.now() - 1, function(err, context)
    result = { err = err, context = context }
  end)
  vim.wait(1000, function()
    return result ~= nil
  end, 10)
  T.eq(
    result and result.err and result.err.code,
    "unavailable",
    "already attached UI cannot pass expired deadline"
  )
  T.eq(result and result.context, nil, "expired deadline provides no context")
  Session.current = original
end

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
  Session.await_ui(vim.uv.now() + 20, function(err, context)
    result = { err = err, context = context }
  end)
  vim.uv.sleep(25)
  vim.uv.update_time()
  attached = true
  vim.api.nvim_exec_autocmds("UIEnter", {})
  vim.wait(1000, function()
    return result ~= nil
  end, 10)
  T.eq(
    result and result.err and result.err.code,
    "unavailable",
    "UIEnter after deadline is unavailable"
  )
  T.eq(result and result.context, nil, "late UIEnter provides no context")
  Session.current = original
end

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
