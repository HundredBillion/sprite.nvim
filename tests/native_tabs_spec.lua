local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local Fake = dofile(root .. "/tests/fake_sprite.lua")
local uv = vim.uv
local sock = "/tmp/sprite-native-tabs-" .. uv.getpid() .. ".sock"
local updates = {}
local server = Fake.serve(sock, {
  features = { "grid-tabs-v1" },
  on_line = function(line)
    local message = vim.json.decode(line)
    if message.type == "tabs" then
      updates[#updates + 1] = message
    end
  end,
})
local child = uv.spawn(vim.v.progpath, {
  args = { "-l", root .. "/lua/sprite/adapter.lua", "--clean" },
  env = {
    "SPRITE_SURFACE_SOCKET=" .. sock,
    "SPRITE_SURFACE_KEY=testkey",
    "SPRITE_PANE=1",
    "PATH=" .. vim.env.PATH,
    "HOME=" .. vim.env.HOME,
    "VIMRUNTIME=" .. vim.env.VIMRUNTIME,
    "XDG_STATE_HOME=" .. sock .. ".state",
  },
  stdio = { nil, nil, 2 },
}, function() end)
T.ok(
  vim.wait(5000, function()
    return #updates > 0
  end, 10),
  "native host receives initial tabs"
)
if #updates > 0 then
  local initial = updates[#updates]
  T.eq(initial.items[1].label, "Untitled")
  server.send({ type = "input", text = ":enew | file native-tabs.lua" })
  server.send({ type = "input", key = "enter" })
  T.ok(
    vim.wait(3000, function()
      for _, update in ipairs(updates) do
        for _, item in ipairs(update.items) do
          if item.label == "native-tabs.lua" then
            return true
          end
        end
      end
    end, 10),
    "buffer rename reaches native tabs"
  )
  server.send({ type = "input", text = ":enew | file second.lua" })
  server.send({ type = "input", key = "enter" })
  T.ok(
    vim.wait(3000, function()
      return #updates[#updates].items == 2
    end, 10),
    "second buffer appears"
  )
  local two = updates[#updates]
  server.send({
    type = "tab_action",
    revision = two.revision,
    id = two.items[1].id,
    action = "select",
  })
  T.ok(
    vim.wait(3000, function()
      return updates[#updates].active == two.items[1].id
    end, 10),
    "host click selects buffer"
  )
  local selected = updates[#updates]
  server.send({
    type = "tab_action",
    revision = selected.revision,
    id = two.items[2].id,
    action = "close",
  })
  T.ok(
    vim.wait(3000, function()
      return #updates[#updates].items == 1
    end, 10),
    "host close removes clean buffer"
  )
  server.send({
    type = "input",
    text = ":lua require('sprite.tabs').setup({snapshot=function() error('provider failed') end})",
  })
  server.send({ type = "input", key = "enter" })
  T.ok(
    vim.wait(3000, function()
      return #updates[#updates].items == 0
    end, 10),
    "provider failure clears native bar"
  )
  T.ok(updates[#updates].revision > selected.revision, "fallback clear has newer revision")
end
T.eq(server.invalid, nil, "native tab messages pass wire validation")
if child then
  child:kill("sigterm")
end
server.close()
