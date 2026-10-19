-- Keep selection restoration ahead of mapping resolution without trapping continuation keys.
local M = {}

function M.new(rpc)
  local queue, pending, waiting, barrier = {}, 0, nil, false
  local closed = false
  local pump
  local function deliver(entry)
    if closed or entry.delivered then
      return
    end
    entry.delivered = true
    if waiting == entry then
      waiting = nil
    end
    rpc:notify(entry.call.method, entry.call.args)
    pump()
  end
  pump = function()
    if closed or waiting or barrier or #queue == 0 then
      return
    end
    local entry = queue[1]
    if entry.barrier then
      -- A delayed restoration must retire before a newer browse can preserve a selection.
      if pending > 0 then
        return
      end
      table.remove(queue, 1)
      barrier = true
      rpc:request(entry.call.method, entry.call.args, function(err, result)
        if closed then
          return
        end
        barrier = false
        if entry.callback then
          entry.callback(err, result)
        end
        pump()
      end)
      return
    end
    table.remove(queue, 1)
    entry.started = true
    pending = pending + 1
    waiting = entry
    rpc:request(
      "nvim_exec_lua",
      { "return require('sprite.minimap').before_input(...)", { entry.event } },
      function()
        if closed then
          return
        end
        pending = pending - 1
        deliver(entry)
        pump()
      end
    )
    -- Neovim answers get_mode at the blocking boundary if normal Lua cannot run.
    -- The hook owns no key, so either reply can release the native input exactly once.
    rpc:request("nvim_get_mode", {}, function(_, mode)
      if type(mode) == "table" and mode.blocking then
        deliver(entry)
      end
    end)
  end
  local bridge = {}
  function bridge.input(call, event)
    if closed then
      return
    end
    local entry = { call = call, event = event }
    queue[#queue + 1] = entry
    pump()
    if not entry.started then
      -- Navigation may itself be waiting for a modal command to finish.
      -- Fast input retains native priority while blocked; a mode reply is not a key ack.
      rpc:request("nvim_get_mode", {}, function(_, mode)
        if closed or entry.started or type(mode) ~= "table" or not mode.blocking then
          return
        end
        for i, queued in ipairs(queue) do
          if queued == entry then
            table.remove(queue, i)
            deliver(entry)
            break
          end
        end
      end)
    end
  end
  function bridge.action(method, args, callback)
    if closed then
      return
    end
    queue[#queue + 1] =
      { barrier = true, call = { method = method, args = args }, callback = callback }
    pump()
  end
  function bridge.close()
    closed, queue = true, {}
  end
  return bridge
end

return M
