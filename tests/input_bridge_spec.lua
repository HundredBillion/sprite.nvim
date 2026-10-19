local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local launch = dofile(root .. "/tests/adapter_session.lua")
for _, configuration in ipairs({
  { name = "native", features = { "grid-minimap-v1" } },
  { name = "baseline", features = {} },
}) do
  local host, messages, close, editor = launch(
    configuration.name,
    configuration.features,
    [[
vim.o.swapfile=false
vim.api.nvim_buf_set_lines(0,0,-1,false,{'abcdef'})
]],
    nil,
    true
  )

  local function request(method, args)
    local done, value, error_reply = false
    editor:request(method, args or {}, function(err, result)
      done, error_reply, value = true, err, result
    end)
    assert(
      vim.wait(10000, function()
        return done
      end, 10),
      method .. " responds"
    )
    assert(error_reply == nil or error_reply == vim.NIL, vim.inspect(error_reply))
    return value
  end
  local function mode(predicate)
    local pending, value = false
    return vim.wait(10000, function()
      if value and predicate(value) then
        return true
      end
      if not pending then
        pending = true
        editor:request("nvim_get_mode", {}, function(_, result)
          pending, value = false, result
        end)
      end
      return false
    end, 10)
  end
  local function key(text)
    host.send({ type = "input", text = text })
  end
  key("v")
  T.ok(
    mode(function(m)
      return m.mode == "v"
    end),
    "separate key enters Visual mode"
  )
  key("r")
  T.ok(
    mode(function(m)
      return m.blocking
    end),
    "Visual replace waits for a character"
  )
  key("x")
  local responsive = mode(function(m)
    return not m.blocking and m.mode == "n"
  end)
  T.ok(responsive, "replacement character reaches blocked editor through real adapter")
  if responsive then
    T.eq(request("nvim_get_current_line"), "xbcdef", "one replacement, no duplicate input")
  end
  if responsive and #configuration.features > 0 then
    request("nvim_exec_lua", {
      [[
local f=vim.json.decode(table.concat(vim.fn.readfile(...),'\n')).valid
local n=0
vim.g.input_order={}
local function record(label) local order=vim.g.input_order; order[#order+1]=label; vim.g.input_order=order end
vim.keymap.set('n','Q',function() record('command') end)
require('sprite.minimap').setup({next=function() n=n+1; if n<=4 then return f[n] end end,
 dispatch=function() record('browse'); vim.g.input_action=(vim.g.input_action or 0)+1 end,
 before_input=function() end,stop=function() end})
]],
      { root .. "/tests/fixtures/minimap-v1.json" },
    })
    assert(
      vim.wait(10000, function()
        for _, m in ipairs(messages) do
          if m.type == "minimap" and m.kind == "state" then
            return true
          end
        end
      end, 10),
      "provider publishes action target"
    )
    key("r")
    T.ok(
      mode(function(m)
        return m.blocking
      end),
      "second replace waits for continuation"
    )
    host.send({
      type = "minimap_action",
      target = "b7:w3:1",
      generation = 1,
      revision = 4,
      action = "reveal",
      line = 1,
    })
    key("zQ")
    local resumed = mode(function(m)
      return not m.blocking and m.mode == "n"
    end)
    T.ok(resumed, "minimap action cannot trap a following continuation key")
    if resumed then
      T.eq(
        request("nvim_get_current_line"),
        "zbcdef",
        "continuation across action applied exactly once"
      )
      T.eq(
        request("nvim_get_var", { "input_order" }),
        { "command", "browse" },
        "modal input retains direct native priority over deferred browse"
      )
      T.eq(
        request("nvim_get_var", { "input_action" }),
        1,
        "queued action runs once after modal command"
      )
    end
  end

  if responsive and #configuration.features == 0 then
    request("nvim_exec_lua", {
      [[
vim.g.input_order={}
vim.keymap.set('n','Q',function()
 local order=vim.g.input_order; order[#order+1]='command'; vim.g.input_order=order
end)
]],
      {},
    })
    key("r")
    T.ok(
      mode(function(m)
        return m.blocking
      end),
      "direct native baseline waits for replacement"
    )
    editor:notify(
      "nvim_exec_lua",
      { "local order=vim.g.input_order; order[#order+1]='browse'; vim.g.input_order=order", {} }
    )
    T.ok(request("nvim_get_mode").blocking, "deferred action is queued during native modal wait")
    key("zQ")
    local resumed = mode(function(m)
      return not m.blocking and m.mode == "n"
    end)
    T.ok(resumed, "direct native input completes ahead of deferred browse")
    if resumed then
      T.eq(
        request("nvim_get_var", { "input_order" }),
        { "command", "browse" },
        "bridge and native baseline agree on modal input priority"
      )
    end
  end

  if responsive then
    local function reset()
      request("nvim_exec_lua", {
        "vim.api.nvim_buf_set_lines(0,0,-1,false,{'abcdef ghij'}); vim.api.nvim_win_set_cursor(0,{1,0})",
        {},
      })
    end
    local function outcome(predicate)
      local pending, value = false
      return vim.wait(10000, function()
        if value and predicate(value) then
          return true
        end
        if not pending then
          pending = true
          editor:request("nvim_exec_lua", {
            "return {line=vim.api.nvim_get_current_line(),cursor=vim.api.nvim_win_get_cursor(0),mode=vim.fn.mode()}",
            {},
          }, function(_, result)
            pending, value = false, result
          end)
        end
        return false
      end, 10)
    end
    for _, case in ipairs({
      { name = "normal replacement", prefix = "r", finish = "X", line = "Xbcdef ghij" },
      { name = "find character", prefix = "f", finish = "d", line = "abcdef ghij", column = 3 },
      { name = "operator pending", prefix = "d", finish = "w", line = "ghij" },
      { name = "Escape cancellation", prefix = "r", escape = true, line = "abcdef ghij" },
    }) do
      reset()
      key(case.prefix)
      local waiting = mode(function(m)
        return case.prefix == "d" and m.mode == "no" or m.blocking
      end)
      T.ok(waiting, case.name .. " reaches its continuation boundary")
      if case.escape then
        host.send({ type = "input", key = "escape" })
      else
        key(case.finish)
      end
      local done = mode(function(m)
        return not m.blocking and m.mode == "n"
      end)
      T.ok(done, case.name .. " completes through adapter")
      if not done then
        break
      end
      T.ok(
        outcome(function(s)
          return s.line == case.line and (not case.column or s.cursor[2] == case.column)
        end),
        case.name .. " has exact native result"
      )
    end
    reset()
    local reader_started = false
    local observer_channel = request("nvim_get_api_info")[1]
    editor:on_notification(function(name)
      if name == "input_reader_started" then
        reader_started = true
      end
    end)
    request("nvim_set_var", { "input_test_channel", observer_channel })
    request("nvim_exec_lua", {
      [[
vim.keymap.set('n','Q',function()
  vim.rpcnotify(vim.g.input_test_channel,'input_reader_started')
  local first=vim.fn.getcharstr()
  local second=vim.fn.getcharstr()
  vim.api.nvim_set_current_line(first..second)
end)
vim.keymap.set('n','zx',function() vim.api.nvim_set_current_line('mapped') end)
]],
      {},
    })
    key("Q")
    T.ok(
      vim.wait(10000, function()
        return reader_started
      end, 10),
      "user mapping entered getcharstr reader"
    )
    key("A")
    key("B")
    local read = mode(function(m)
      return not m.blocking and m.mode == "n"
    end)
    T.ok(read, "multiple getchar continuations complete without waiting for old hooks")
    if read then
      T.ok(
        outcome(function(s)
          return s.line == "AB"
        end),
        "getchar receives both original characters exactly once"
      )
      reset()
      key("z")
      T.ok(
        mode(function(m)
          return m.blocking
        end),
        "mapping prefix waits for remaining key"
      )
      key("x")
      T.ok(
        mode(function(m)
          return not m.blocking and m.mode == "n"
        end),
        "mapping suffix reaches input reader"
      )
      T.ok(
        outcome(function(s)
          return s.line == "mapped"
        end),
        "split mapping executes once"
      )
      reset()
      key("v")
      key("r")
      key("x")
      T.ok(
        outcome(function(s)
          return s.line == "xbcdef ghij" and s.mode == "n"
        end),
        "burst of separate Surface events has same result as fragmented typing"
      )
      reset()
      key("i")
      T.ok(
        mode(function(m)
          return m.mode == "i"
        end),
        "insert mode starts before native paste"
      )
      host.send({ type = "paste", text = "PASTE" })
      T.ok(
        outcome(function(s)
          return s.line == "PASTEabcdef ghij"
        end),
        "native paste is applied once"
      )
      host.send({ type = "input", key = "escape" })
      T.ok(
        mode(function(m)
          return m.mode == "n"
        end),
        "Escape still leaves insert mode"
      )
    end
  end
  if responsive and #configuration.features > 0 then
    request("nvim_exec_lua", {
      [[
vim.api.nvim_buf_set_lines(0,0,-1,false,{'abc'})
vim.api.nvim_win_set_cursor(0,{1,0})
require('sprite.minimap').setup({next=function() end,stop=function() end,
 before_input=function() error('fixture hook failure') end})
]],
      {},
    })
    key("r")
    T.ok(
      mode(function(m)
        return m.blocking
      end),
      "provider failure still delivers replace prefix"
    )
    key("Z")
    local complete = mode(function(m)
      return not m.blocking and m.mode == "n"
    end)
    T.ok(complete, "provider failure cannot swallow replacement character")
    if complete then
      T.eq(
        request("nvim_get_current_line"),
        "Zbc",
        "provider failure still applies original native input once"
      )
    end
  end
  close()
end
