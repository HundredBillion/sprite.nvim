local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local uv = vim.uv
local Fake = dofile(root .. "/tests/fake_sprite.lua")
local temp = vim.fn.tempname() .. " path with spaces"
vim.fn.mkdir(temp, "p")
local linked = temp .. "/repo it's here"
assert(uv.fs_symlink(root, linked))
local result = temp .. "/marker.json"
local nested = temp .. "/nested.json"
local init = temp .. "/init.lua"
local nested_cmd = 'lua local s=require("sprite").session; local c=s.current(); vim.fn.writefile({vim.json.encode({marker=vim.g.sprite_session,context=c})},'
  .. vim.json.encode(nested)
  .. ")"
local lines = {
  'local s = require("sprite").session',
  "local c = s.current()",
  "vim.fn.writefile({vim.json.encode({marker=vim.g.sprite_session,pid=vim.fn.getpid(),pane=c and c.pane,surface=c and c.return_target,presentation=c and c.presentation,uis=#vim.api.nvim_list_uis()})},"
    .. vim.json.encode(result)
    .. ")",
  'vim.fn.system({vim.v.progpath,"--headless","--clean","--cmd","lua vim.opt.runtimepath:prepend(" .. vim.json.encode('
    .. vim.json.encode(linked)
    .. ') .. ")","-c",'
    .. vim.json.encode(nested_cmd)
    .. ',"-c","qa!"})',
}
vim.fn.writefile(lines, init)

local sock = temp .. "/surface.sock"
local server = Fake.serve(sock, { surface = 357 })
local env = {
  "SPRITE_SURFACE_SOCKET=" .. sock,
  "SPRITE_SURFACE_KEY=testkey",
  "SPRITE_PANE=0",
  "PATH=" .. vim.fn.fnamemodify(vim.v.progpath, ":h") .. ":" .. (uv.os_getenv("PATH") or ""),
  "VIMRUNTIME=" .. vim.env.VIMRUNTIME,
  "HOME=" .. (uv.os_getenv("HOME") or "/tmp"),
  "XDG_STATE_HOME=" .. temp .. "/state",
}
local child = uv.spawn(vim.v.progpath, {
  args = { "-l", linked .. "/lua/sprite/adapter.lua", "-u", init },
  env = env,
  stdio = { nil, nil, 2 },
}, function() end)
local deadline = uv.now() + 10000
local timer = uv.new_timer()
timer:start(20, 20, function()
  if (uv.fs_stat(result) and uv.fs_stat(nested)) or uv.now() > deadline then
    timer:stop()
    uv.stop()
  end
end)
while timer:is_active() and uv.loop_alive() do
  uv.run()
end
if child then
  child:kill("sigterm")
  child:close()
end
server.close()
local function read_json(path)
  if not uv.fs_stat(path) then
    return nil
  end
  return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end
local seen = read_json(result)
T.ok(seen ~= nil, "actual require(sprite) ran during embedded init")
T.ok(server.first_open and server.first_open.owner_pid > 0, "adapter registers fill owner PID")
T.eq(server.first_open and server.first_open.pane, 0, "adapter opens Sprite pane zero")
if seen then
  T.eq(seen.marker.surface, 357, "adapter retains handshake Surface id")
  T.eq(seen.marker.pid, seen.pid, "bootstrap marker belongs to embedded process")
  T.eq(seen.surface, 357, "session resolves grid return target before UI attachment")
  T.eq(seen.pane, 0, "embedded session resolves Sprite pane zero")
end
local inner = read_json(nested)
T.ok(inner ~= nil, "nested Neovim launched from embedded init")
if inner then
  T.eq(inner.marker, nil, "nested Neovim has no process-local marker")
  T.eq(inner.context, nil, "nested Neovim does not select parent grid")
end

os.remove(result)
local command = require("sprite.session").bootstrap(linked, 357)
local unattached = uv.spawn(vim.v.progpath, {
  args = { "--headless", "--cmd", command, "-u", init, "-c", "qa!" },
  env = env,
  stdio = { nil, nil, 2 },
}, function() end)
local unattached_deadline = uv.now() + 5000
local poll = uv.new_timer()
poll:start(20, 20, function()
  if uv.fs_stat(result) or uv.now() > unattached_deadline then
    poll:stop()
    uv.stop()
  end
end)
while poll:is_active() and uv.loop_alive() do
  uv.run()
end
if unattached then
  unattached:kill("sigterm")
  unattached:close()
end
local early = read_json(result)
T.ok(early ~= nil, "init loads actual sprite module without attached UI")
if early then
  T.eq(early.uis, 0, "bootstrap marker is usable before UI attachment")
  T.eq(early.surface, 357, "grid session resolves before UI attachment")
end
vim.fn.delete(temp, "rf")
