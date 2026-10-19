local launch = dofile(vim.fn.getcwd() .. "/tests/adapter_session.lua")
local code = [[
vim.o.swapfile=false
vim.api.nvim_buf_set_lines(0,0,-1,false,{'abc'})
local bridge=require('sprite.markdown')
local queue,preview={},true
local function state()
 queue[#queue+1]={kind='state',active=vim.api.nvim_get_current_win(),windows={{window=vim.api.nvim_get_current_win(),buffer=vim.api.nvim_get_current_buf(),generation=vim.api.nvim_buf_get_changedtick(0),preview=preview,row=0,column=0,width=80,height=20}},colors={background='#1e1f22',foreground='#bcbec4',muted='#9da0a8',accent='#589df6',code='#2b2d30'}}
end
bridge.setup({next=function() return table.remove(queue,1) end,
 attached=function(value) if value then
  queue[#queue+1]={kind='document',buffer=vim.api.nvim_get_current_buf(),generation=vim.api.nvim_buf_get_changedtick(0),path='',text='abc'}
  state()
 end end,
 before_input=function(event) vim.g.markdown_input_seen=(vim.g.markdown_input_seen or 0)+1; return not preview or (event.type~='paste' and event.key~='x') end,
 dispatch=function(event) preview=not preview;state();return true end})
]]
for _, supported in ipairs({ true, false }) do
  local host, messages, close, editor = launch(
    "markdown-" .. tostring(supported),
    supported and { "grid-markdown-v1" } or {},
    code,
    nil,
    true
  )
  local function request(method, args)
    local done, value, problem = false
    editor:request(method, args or {}, function(err, result)
      done, value, problem = true, result, err
    end)
    assert(
      vim.wait(5000, function()
        return done
      end, 5),
      "editor RPC timed out"
    )
    assert(problem == nil or problem == vim.NIL, vim.inspect(problem))
    return value
  end
  local function latest()
    for i = #messages, 1, -1 do
      if messages[i].type == "markdown" and messages[i].kind == "state" then
        return messages[i]
      end
    end
  end
  if supported then
    T.ok(
      vim.wait(3000, function()
        return latest() ~= nil
      end, 5),
      "negotiated host receives Markdown state"
    )
    local state = latest()
    assert(state, "missing initial state")
    T.ok(state.windows[1].preview)
    local document
    for _, message in ipairs(messages) do
      if message.type == "markdown" and message.kind == "document" then
        document = message
      end
    end
    T.eq(document.text, "abc", "initial document arrives through real adapter")
    host.send({ type = "input", text = "x" })
    host.send({ type = "paste", text = "replacement" })
    T.ok(
      vim.wait(3000, function()
        return request("nvim_exec_lua", { "return vim.g.markdown_input_seen or 0", {} }) >= 2
      end, 5),
      "both preview inputs pass through the ordered gate"
    )
    T.eq(
      request("nvim_buf_get_lines", { 0, 0, -1, false }),
      { "abc" },
      "preview blocks edits and paste"
    )
    local target = state.windows[1]
    host.send({
      type = "markdown_action",
      revision = state.revision,
      window = target.window,
      buffer = target.buffer,
      generation = target.generation,
      action = "toggle",
    })
    T.ok(
      vim.wait(3000, function()
        local s = latest()
        return s and s.revision > state.revision and not s.windows[1].preview
      end, 5),
      "toolbar event switches to source"
    )
    host.send({ type = "input", text = "x" })
    T.ok(
      vim.wait(3000, function()
        return request("nvim_buf_get_lines", { 0, 0, -1, false })[1] == "bc"
      end, 5),
      "source input reaches original buffer"
    )
  else
    T.eq(
      request("nvim_exec_lua", { "return require('sprite.markdown').available()", {} }),
      false,
      "old host stays in source"
    )
    T.eq(latest(), nil, "no unsupported Markdown operation")
    host.send({ type = "input", text = "x" })
    T.ok(
      vim.wait(3000, function()
        return request("nvim_buf_get_lines", { 0, 0, -1, false })[1] == "bc"
      end, 5),
      "old host retains native input"
    )
  end
  close()
end
