local Fake = dofile("tests/fake_sprite.lua")
local fixture =
  vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/surface-list-v1.json"), "\n"))
local state = {}
local function accepted(message)
  local ok, reason = Fake.validate(message, state)
  T.ok(ok, tostring(reason))
end
local function refused(message)
  local ok = Fake.validate(message, state)
  T.ok(not ok, "strict fake rejects invalid " .. message.type)
end

accepted({ type = "batch", ops = {} })
accepted({ type = "batch", ops = { { type = "rows", rows = {} } } })
accepted({ type = "batch", ops = { { type = "rows", rows = { { row = 0, cells = {} } } } } })
refused({ type = "batch" })
refused({ type = "batch", ops = { { type = "unknown" } } })
refused({ type = "batch", ops = { { type = "batch", ops = {} } } })
refused({ type = "batch", ops = { { type = "rows" } } })
refused({ type = "batch", ops = { { type = "rows", rows = { { row = 0 } } } } })
refused({ type = "batch", ops = { { type = "rows", rows = { { row = 0, cells = { {} } } } } } })
refused({ type = "batch", ops = { { type = "cursor", col = 0 } } })
refused({ type = "batch", ops = { { type = "scroll", top = 0, bot = 1, left = 0, right = 1 } } })
refused({ type = "batch", ops = { { type = "highlights", define = {} } } })
accepted({ type = "batch", ops = { { type = "highlights", define = vim.empty_dict() } } })
refused({ type = "batch", ops = { { type = "highlights", define = { ["1.0"] = {} } } } })
refused({ type = "batch", ops = { { type = "defaults", fg = "red" } } })

refused({
  type = "batch",
  ops = { { type = "rows", rows = { { row = 0, col = 0, cells = { { "x", 0, 0 } } } } } },
})
refused({ type = "assets", entries = {} })
accepted({ type = "assets", entries = vim.empty_dict() })
refused({ type = "assets", entries = { bad = "not SVG" } })
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
accepted({ type = "update", description = fixture.description })
T.eq(state.row_height, 22, "fake tracks accepted list row height")
refused({ type = "list_state", revision = 1, scroll = { id = "a", offset = 22 } })
accepted({ type = "list_state", revision = 1, scroll = { id = "a", offset = 3 } })
refused({
  type = "list_rows",
  revision = 2,
  rows = { { id = "b", text = "b", indent = math.huge, guides = {} } },
  selected = "b",
})
refused({
  type = "list_rows",
  revision = 2,
  rows = { { id = "b", text = "b", indent = 16385, guides = {} } },
  selected = "b",
})
refused({
  type = "list_rows",
  revision = 2,
  rows = { { id = "b", text = "b", indent = 0, guides = { -1 } } },
  selected = "b",
})
refused({
  type = "list_rows",
  revision = 2,
  rows = { { id = "b", text = "b", indent = 0, guides = { 0 / 0 } } },
  selected = "b",
})
refused({
  type = "list_rows",
  revision = 2,
  rows = { { id = string.rep("x", 4097), text = "b", indent = 0, guides = {} } },
  selected = string.rep("x", 4097),
})
refused({
  type = "list_rows",
  revision = 2,
  rows = { { id = "b", text = "", indent = 0, guides = {} } },
  selected = "b",
})
refused({
  type = "list_rows",
  revision = 2,
  rows = { { id = "b", text = "b", indent = 0, guides = { 0 }, icon = string.rep("x", 4097) } },
  selected = "b",
})
refused({ type = "list_state", revision = 1, scroll = { id = "a" } })
refused({ type = "list_state", revision = 1, scroll = { id = "a", offset = "zero" } })
refused({ type = "list_state", revision = 1, scroll = { id = "a", offset = -1 } })
refused({ type = "list_state", revision = 1, scroll = { id = "a", offset = math.huge } })
refused({ type = "list_state", revision = 1, status = 5 })

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

do
  local path = vim.fn.tempname() .. ".sock"
  local server = Fake.serve(path)
  local client = vim.uv.new_pipe(false)
  local reply = ""
  client:connect(path, function()
    client:read_start(function(_, bytes)
      reply = reply .. (bytes or "")
    end)
    client:write("secret\n")
  end)
  T.ok(
    vim.wait(1000, function()
      return reply:find('"refused"', 1, true) ~= nil
    end),
    "malformed first line receives refusal"
  )
  T.ok(server.invalid ~= nil, "malformed first line is recorded")
  client:close()
  server.close()
end
