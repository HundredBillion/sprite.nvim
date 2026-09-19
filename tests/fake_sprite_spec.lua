local Fake = dofile("tests/fake_sprite.lua")
local state = {}
local function accepted(message)
  local ok, reason = Fake.validate(message, state)
  T.ok(ok, tostring(reason))
end
local function refused(message)
  local ok = Fake.validate(message, state)
  T.ok(not ok, "strict fake rejects invalid " .. message.type)
end

refused({
  type = "batch",
  ops = { { type = "rows", rows = { { row = 0, col = 0, cells = { { "x", 0, 0 } } } } } },
})
refused({ type = "assets", entries = {} })
accepted({ type = "assets", entries = vim.empty_dict() })
refused({ type = "list_rows", revision = 1, rows = {}, selected = nil })
refused({
  type = "list_rows",
  revision = 1,
  rows = {
    { id = "a", text = "a", indent = 0, guides = {} },
    { id = "a", text = "b", indent = 0, guides = {} },
  },
  selected = "a",
})
accepted({
  type = "list_rows",
  revision = 1,
  rows = { { id = "a", text = "a", indent = 0, guides = {} } },
  selected = "a",
})
refused({ type = "list_rows", revision = 1, rows = {}, selected = vim.NIL })
refused({ type = "list_state", revision = 2, selected = "a" })
refused({ type = "list_state", revision = 1, selected = "missing" })
refused({ type = "list_state", revision = 1, reveal = "a", scroll = { id = "a", offset = 0 } })
accepted({ type = "list_state", revision = 1, selected = "a" })

do
  local Channel = require("sprite.channel")
  local path = vim.fn.tempname() .. ".sock"
  local server = Fake.serve(path, { refuse_capabilities = true })
  local result
  Channel.connect({
    path = path,
    key = "secret",
    first = {
      type = "capabilities",
      version = 1,
      pane = 1,
      owner_pid = vim.uv.os_getpid(),
      return_target = "terminal",
    },
    timeout_ms = 100,
  }, function(err)
    result = err and err.code
  end)
  T.ok(
    vim.wait(1000, function()
      return result ~= nil
    end),
    "capability refusal received"
  )
  T.eq(result, "refused", "fake Sprite can refuse discovery")
  server.close()
end
