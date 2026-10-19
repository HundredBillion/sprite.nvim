local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local Fake = dofile(root .. "/tests/fake_sprite.lua")
local Rpc = dofile(root .. "/lua/sprite/rpc.lua")
local uv = vim.uv

return function(name, features, code, on_message, observe)
  local init = vim.fn.tempname() .. ".lua"
  local path = "/tmp/sprite-minimap-" .. uv.getpid() .. "-" .. name .. ".sock"
  local observer_path = path .. ".editor"
  if observe then
    code = "vim.fn.serverstart(" .. string.format("%q", observer_path) .. ")\n" .. code
  end
  vim.fn.writefile(vim.split(code, "\n", { plain = true }), init)
  local messages = {}
  local host = Fake.serve(path, {
    features = features,
    on_line = function(line)
      local message = vim.json.decode(line)
      messages[#messages + 1] = message
      if on_message then
        on_message(message)
      end
    end,
  })
  local process = uv.spawn(vim.v.progpath, {
    args = { "-l", root .. "/lua/sprite/adapter.lua", "--clean", "-u", init },
    env = {
      "SPRITE_SURFACE_SOCKET=" .. path,
      "SPRITE_SURFACE_KEY=testkey",
      "SPRITE_PANE=1",
      "PATH=" .. vim.env.PATH,
      "HOME=" .. vim.env.HOME,
      "VIMRUNTIME=" .. vim.env.VIMRUNTIME,
      "XDG_STATE_HOME=" .. path .. ".state",
    },
    stdio = { nil, nil, 2 },
  }, function() end)
  local pipe, control
  if observe then
    assert(
      vim.wait(10000, function()
        return uv.fs_stat(observer_path) ~= nil
      end, 10),
      "editor RPC socket opens"
    )
    pipe = uv.new_pipe(false)
    local connected = false
    control = Rpc.new(function(bytes)
      pipe:write(bytes)
    end)
    pipe:connect(observer_path, function(err)
      assert(not err, err)
      connected = true
      pipe:read_start(function(read_err, bytes)
        assert(not read_err, read_err)
        if bytes then
          control:feed(bytes)
        end
      end)
    end)
    assert(
      vim.wait(10000, function()
        return connected
      end, 10),
      "observer connects"
    )
  end
  local function close()
    if pipe then
      pipe:read_stop()
      pipe:close()
    end
    if process then
      process:kill("sigterm")
    end
    host.close()
    vim.fn.delete(init)
  end
  return host, messages, close, control
end
