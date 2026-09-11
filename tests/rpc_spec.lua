local Rpc =
  dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/lua/sprite/rpc.lua")

-- A request is encoded as {0, id, method, args}; ids start at 1 and increment.
do
  local written = {}
  local c = Rpc.new(function(b)
    written[#written + 1] = b
  end)
  c:request("nvim_ui_attach", { 80, 24, { ext_linegrid = true } })
  c:notify("nvim_input", { "x" })
  local req = vim.mpack.decode(written[1])
  local note = vim.mpack.decode(written[2])
  T.eq(req[1], 0, "request type is 0")
  T.eq(req[2], 1, "first msgid is 1")
  T.eq(req[3], "nvim_ui_attach", "request method")
  T.eq(note[1], 2, "notification type is 2")
  T.eq(note[2], "nvim_input", "notification method")
end

-- feed dispatches a notification to the handler.
do
  local c = Rpc.new(function() end)
  local seen = {}
  c:on_notification(function(method, args)
    seen[#seen + 1] = { method, args }
  end)
  c:feed(vim.mpack.encode({ 2, "redraw", { { "flush" } } }))
  T.eq(seen, { { "redraw", { { "flush" } } } }, "a notification reaches the handler")
end

-- feed matches a response to the request's callback by msgid.
do
  local c = Rpc.new(function() end)
  local got
  c:request("nvim_eval", { "1+1" }, function(err, result)
    got = { err, result }
  end)
  c:feed(vim.mpack.encode({ 1, 1, vim.NIL, 2 }))
  T.eq(got, { vim.NIL, 2 }, "a response reaches its callback")
end

-- feed handles a message split across two chunks, and two messages in one.
do
  local c = Rpc.new(function() end)
  local seen = {}
  c:on_notification(function(m)
    seen[#seen + 1] = m
  end)
  local a = vim.mpack.encode({ 2, "one", {} })
  local b = vim.mpack.encode({ 2, "two", {} })
  c:feed(a:sub(1, 3))
  T.eq(#seen, 0, "an incomplete message dispatches nothing yet")
  c:feed(a:sub(4) .. b)
  T.eq(seen, { "one", "two" }, "the rest of one message and a whole next are both dispatched")
end
