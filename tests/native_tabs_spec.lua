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
  local metrics = vim.fn.tempname()
  local fixture = vim.fn.tempname() .. ".lua"
  local events = vim.fn.tempname()
  local saved = vim.fn.tempname()
  vim.fn.writefile({
    "local calls = 0",
    "vim.api.nvim_create_autocmd({'TextChanged', 'TextChangedI', 'OptionSet'}, {callback=function(e)",
    "  if e.event ~= 'OptionSet' or e.match == 'modified' then",
    "    vim.fn.writefile({e.event}, " .. string.format("%q", events) .. ", 'a')",
    "  end",
    "end})",
    "require('sprite.tabs').setup({snapshot = function()",
    "  calls = calls + 1",
    "  vim.fn.writefile({tostring(calls)}, " .. string.format("%q", metrics) .. ")",
    "  local items = {}",
    "  for _, b in ipairs(vim.fn.getbufinfo({buflisted=1})) do",
    "    items[#items+1] = {buffer=b.bufnr, label=vim.fn.fnamemodify(b.name, ':t'), modified=vim.bo[b.bufnr].modified}",
    "  end",
    "  return {items=items, active=vim.api.nvim_get_current_buf()}",
    "end})",
  }, fixture)
  local function command(text)
    server.send({ type = "input", text = ":" .. text })
    server.send({ type = "input", key = "enter" })
    vim.wait(180, function()
      return false
    end, 10)
  end
  local function calls()
    return tonumber(vim.fn.readfile(metrics)[1])
  end
  command("luafile " .. fixture)
  local before = calls()
  server.send({ type = "input", text = "ix" })
  server.send({ type = "input", key = "escape" })
  T.ok(
    vim.wait(3000, function()
      return updates[#updates].items[1].modified
    end, 10),
    "first real edit marks native tab dirty"
  )
  vim.wait(180, function()
    return false
  end, 10)
  T.eq(calls() - before, 1, "first edit computes metadata once")
  local dirty_calls = calls()
  for _ = 1, 12 do
    server.send({ type = "input", text = "ax" })
    server.send({ type = "input", key = "escape" })
    vim.wait(100, function()
      return false
    end, 10)
  end
  T.eq(
    calls() - dirty_calls,
    0,
    "already-dirty typing does no provider work through real adapter redraws"
  )
  print(
    "  provider calls: first edit="
      .. (dirty_calls - before)
      .. ", 12 dirty edits="
      .. (calls() - dirty_calls)
  )
  local undo_calls = calls()
  command("earlier 1h")
  T.eq(calls() - undo_calls, 1, "undo transition computes metadata once")
  T.eq(updates[#updates].items[1].modified, false, "undo to initial text clears modified marker")
  local redo_calls = calls()
  command("later 1h")
  T.eq(calls() - redo_calls, 1, "redo transition computes metadata once")
  T.eq(updates[#updates].items[1].modified, true, "redo restores modified marker")
  command("file " .. saved)
  local save_calls = calls()
  command("write!")
  T.eq(calls() - save_calls, 1, "save transition computes metadata once")
  T.eq(updates[#updates].items[1].modified, false, "save clears modified marker")
  T.eq(
    updates[#updates].items[1].label,
    vim.fn.fnamemodify(saved, ":t"),
    "rename refreshes provider label"
  )
  local insert_calls = calls()
  server.send({ type = "input", text = "i" })
  for _ = 1, 12 do
    server.send({ type = "input", text = "z" })
    vim.wait(100, function()
      return false
    end, 10)
  end
  server.send({ type = "input", key = "escape" })
  vim.wait(180, function()
    return false
  end, 10)
  T.eq(calls() - insert_calls, 1, "insert-mode typing computes metadata only on first dirty edit")
  local counts = {}
  for _, event in ipairs(vim.fn.readfile(events)) do
    counts[event] = (counts[event] or 0) + 1
  end
  T.ok((counts.TextChanged or 0) > 0, "normal-mode changes fire real TextChanged")
  T.ok((counts.TextChangedI or 0) > 0, "insert-mode changes fire real TextChangedI")
  print("  real events: " .. vim.inspect(counts))
  local theme_calls = calls()
  command("colorscheme default")
  T.ok(calls() > theme_calls, "theme change refreshes provider")
  command("lua _G.background_tab = vim.api.nvim_create_buf(true, false)")
  T.eq(#updates[#updates].items, 2, "background buffer appears")
  local background_calls = calls()
  command(
    "noautocmd lua vim.api.nvim_buf_set_lines(_G.background_tab, 0, -1, false, {'background edit'})"
  )
  T.eq(updates[#updates].items[2].modified, true, "background edit updates native modified marker")
  T.eq(calls() - background_calls, 1, "background edit computes metadata once")
  command("lua vim.api.nvim_buf_delete(_G.background_tab, {force=true})")
  T.eq(#updates[#updates].items, 1, "background close removes native tab")
  vim.fn.delete(events)
  vim.fn.delete(metrics)
  vim.fn.delete(fixture)
  vim.fn.delete(saved)
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

local fallback_file = vim.fn.tempname()
local fallback_tabs = 0
local fallback = Fake.serve(sock .. ".old", {
  on_line = function(line)
    if vim.json.decode(line).type == "tabs" then
      fallback_tabs = fallback_tabs + 1
    end
  end,
})
local old_child = uv.spawn(vim.v.progpath, {
  args = { "-l", root .. "/lua/sprite/adapter.lua", "--clean" },
  env = {
    "SPRITE_SURFACE_SOCKET=" .. sock .. ".old",
    "SPRITE_SURFACE_KEY=testkey",
    "SPRITE_PANE=1",
    "PATH=" .. vim.env.PATH,
    "HOME=" .. vim.env.HOME,
    "VIMRUNTIME=" .. vim.env.VIMRUNTIME,
    "XDG_STATE_HOME=" .. sock .. ".old.state",
  },
  stdio = { nil, nil, 2 },
}, function() end)
vim.wait(500, function()
  return false
end, 10)
fallback.send({
  type = "input",
  text = ":lua vim.fn.writefile({tostring(vim.api.nvim_list_uis()[1].ext_tabline)}, "
    .. string.format("%q", fallback_file)
    .. ")",
})
fallback.send({ type = "input", key = "enter" })
T.ok(
  vim.wait(3000, function()
    return vim.fn.filereadable(fallback_file) == 1
  end, 10),
  "older host accepts editor input"
)
if vim.fn.filereadable(fallback_file) == 1 then
  T.eq(vim.fn.readfile(fallback_file)[1], "false", "older host keeps Neovim tabline")
end
T.eq(fallback_tabs, 0, "older host receives no native tab messages")
if old_child then
  old_child:kill("sigterm")
end
fallback.close()
vim.fn.delete(fallback_file)
