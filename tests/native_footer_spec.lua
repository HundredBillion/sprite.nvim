local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local Fake = dofile(root .. "/tests/fake_sprite.lua")
local sock = vim.fn.tempname() .. ".sock"
local updates, screen = {}, {}
local function remember(message)
  if message.type == "batch" then
    for _, op in ipairs(message.ops) do
      remember(op)
    end
  elseif message.type == "rows" then
    for _, row in ipairs(message.rows) do
      local cells = screen[row.row] or {}
      screen[row.row] = cells
      local column = (row.col or 0) + 1
      for _, cell in ipairs(row.cells) do
        for _ = 1, cell[3] or 1 do
          cells[column] = cell[1]
          column = column + 1
        end
      end
    end
  end
end
local server = Fake.serve(sock, {
  features = { "grid-footer-v1" },
  on_line = function(line)
    local message = vim.json.decode(line)
    remember(message)
    if message.type == "footer" then
      updates[#updates + 1] = message
    end
  end,
})
local exit_code
local child = vim.uv.spawn(vim.v.progpath, {
  args = {
    "-l",
    root .. "/lua/sprite/adapter.lua",
    "--clean",
    "--cmd",
    "set laststatus=3 cmdheight=0 statusline=LEFT%=RIGHT",
  },
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
}, function(code)
  exit_code = code
end)
local function latest()
  return updates[#updates] or {}
end
T.ok(
  vim.wait(5000, function()
    return latest().cols == 80
  end, 10),
  "host receives statusline"
)
server.send({ type = "resize", width = 640, height = 384, cols = 80, rows = 24, footer_cols = 100 })
T.ok(
  vim.wait(3000, function()
    return latest().cols == 100
  end, 10),
  "minimap leaves footer at full width"
)
local text = ""
for _, cell in ipairs(latest().cells or {}) do
  text = text .. cell[1]:rep(cell[3] or 1)
end
T.eq(#text, 100)
T.ok(text:match("^LEFT +RIGHT$") ~= nil, "right-aligned content reaches minimap edge")
T.eq(
  table.concat(screen[latest().row]),
  latest().source,
  "source guard matches the real Neovim row"
)
server.send({ type = "input", text = ":echo HELLO" })
T.ok(
  vim.wait(3000, function()
    return table.concat(screen[23] or {}):find(":echo HELLO", 1, true) ~= nil
  end, 10),
  "command input replaces the statusline row with cmdheight=0"
)
T.ok(
  table.concat(screen[23]) ~= latest().source,
  "source guard lets command input cover the footer"
)
server.send({ type = "input", key = "escape" })
T.ok(
  vim.wait(3000, function()
    return table.concat(screen[23] or {}) == latest().source
  end, 10),
  "footer returns after the command is dismissed"
)
server.send({ type = "input", text = ":set laststatus=2" })
server.send({ type = "input", key = "enter" })
T.ok(
  vim.wait(3000, function()
    return latest().visible == false
  end, 10),
  "window statuslines remove footer"
)
server.send({ type = "input", text = ":qa!" })
server.send({ type = "input", key = "enter" })
T.ok(
  vim.wait(3000, function()
    return exit_code ~= nil
  end, 10),
  "adapter exits cleanly with a scheduled footer refresh"
)
T.eq(exit_code, 0, "native footer timer does not keep adapter alive after editor exit")
child:close()
server.close()
vim.fn.delete(sock .. ".state", "rf")
