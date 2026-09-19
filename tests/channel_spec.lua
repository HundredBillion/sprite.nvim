local Channel = require("sprite.channel")
local uv = vim.uv
local values = {}
local decoder = Channel.decoder(function(v)
  values[#values + 1] = v
end)
T.ok(decoder:feed('{"type":"op'), "split prefix")
T.ok(decoder:feed('ened","surface":7}\n{"type":"focus"}\n'), "merged frames")
T.eq(values, { { type = "opened", surface = 7 }, { type = "focus" } }, "split and merged frames")
T.eq(decoder:finish(), true, "empty EOF")

local final = Channel.decoder(function(v)
  values[#values + 1] = v
end)
T.ok(final:feed('{"type":"focused"}'), "unterminated frame buffered")
T.eq(final:finish(), true, "unterminated frame decoded")
T.eq(values[#values], { type = "focused" }, "final frame")
local bad = Channel.decoder(function() end)
T.ok(bad:feed("{broken}\n") == nil, "bad JSON rejected")
local bounded = Channel.decoder(function() end, 8)
T.ok(bounded:feed("123456789") == nil, "oversize frame rejected")

do
  local Fake = dofile("tests/fake_sprite.lua")
  local path = vim.fn.tempname() .. ".sock"
  local server = Fake.serve(path, { ack_delay_ms = 100 })
  local results = {}
  Channel.connect({
    path = path,
    key = "secret",
    first = {
      type = "open",
      version = 1,
      pane = 1,
      owner_pid = uv.os_getpid(),
      position = "fill",
      focus = true,
      description = vim.empty_dict(),
    },
    timeout_ms = 30,
  }, function(err, ch)
    T.eq(err, nil, "delayed fake accepts open")
    if not ch then
      return
    end
    ch:request({ type = "assets", entries = vim.empty_dict() }, "applied", function(e)
      results[#results + 1] = e and e.code or "ok"
    end)
    ch:request({ type = "assets", entries = vim.empty_dict() }, "applied", function(e)
      results[#results + 1] = e and e.code or "ok"
    end)
  end)
  T.ok(
    vim.wait(1000, function()
      return #results == 2
    end),
    "pending request reaches timeout"
  )
  T.eq(results, { "timeout", "timeout" }, "first timeout closes queued request")
  vim.wait(150)
  T.eq(#results, 2, "late acknowledgement cannot finish another request")
  server.close()
end

local function scenario(reply, expected, opts)
  opts = opts or {}
  local path = "/tmp/sprite-channel-" .. uv.os_getpid() .. "-" .. tostring(uv.hrtime()) .. ".sock"
  local server = uv.new_pipe(false)
  assert(server:bind(path))
  local peer
  server:listen(1, function()
    peer = uv.new_pipe(false)
    server:accept(peer)
    peer:read_start(function(_, chunk)
      if chunk and chunk:find("\n", 1, true) and reply then
        local answer = reply
        reply = nil
        if type(answer) == "table" then
          peer:write(answer[1], function()
            peer:write(answer[2])
          end)
        else
          peer:write(answer)
        end
        if opts.eof then
          peer:shutdown(function()
            peer:close()
          end)
        end
      end
    end)
    if opts.immediate_eof then
      peer:close()
    end
  end)
  local observed, fast
  local connection_opts = {
    path = path,
    key = "secret",
    first = opts.first or { type = "open" },
    timeout_ms = opts.timeout_ms or 100,
  }
  local function on_ready(err, ch)
    observed = err and err.code or (ch and "ready")
    fast = vim.in_fast_event()
    if ch then
      ch:close("done")
    end
  end
  local cancel = Channel.connect(connection_opts, on_ready)
  T.ok(
    vim.wait(1000, function()
      return observed ~= nil
    end),
    "callback arrives"
  )
  T.eq(observed, expected, "first verdict " .. expected)
  T.eq(fast, false, "callback scheduled")
  cancel()
  if peer and not peer:is_closing() then
    peer:close()
  end
  server:close()
  uv.fs_unlink(path)
end

for _, mode in ipairs({ "malformed", "eof" }) do
  local path = "/tmp/sprite-channel-accepted-" .. mode .. "-" .. uv.os_getpid() .. ".sock"
  local server = uv.new_pipe(false)
  assert(server:bind(path))
  local peer, writes = nil, 0
  server:listen(1, function()
    peer = uv.new_pipe(false)
    server:accept(peer)
    peer:read_start(function(_, bytes)
      if not bytes then
        return
      end
      for _ in bytes:gmatch("[^\n]+") do
        writes = writes + 1
        if writes == 1 then
          peer:write('{"type":"opened","surface":7}\n')
        end
        if writes == 2 then
          if mode == "malformed" then
            peer:write('{"type":"applied","operation":"assets"}\n{bad}\n')
          else
            peer:write('{"type":"applied","operation":"assets"}\n', function()
              peer:shutdown(function()
                peer:close()
              end)
            end)
          end
        end
      end
    end)
  end)
  local acknowledgements, closes = {}, 0
  Channel.connect({
    path = path,
    key = "secret",
    first = { type = "open" },
    on_close = function()
      closes = closes + 1
    end,
  }, function(err, ch)
    T.eq(err, nil, "accepted reply channel ready")
    ch:request({ type = "assets", operation = "assets" }, "applied", function(request_err, reply)
      acknowledgements[#acknowledgements + 1] = request_err and request_err.code or reply.type
      T.eq(vim.in_fast_event(), false, "accepted reply scheduled")
    end)
  end)
  T.ok(
    vim.wait(1000, function()
      return closes == 1
    end),
    mode .. " after reply closes channel"
  )
  T.ok(
    vim.wait(1000, function()
      return #acknowledgements == 1
    end),
    mode .. " accepted reply completes after close"
  )
  T.eq(acknowledgements, { "applied" }, mode .. " accepted reply retained through close")
  if peer and not peer:is_closing() then
    peer:close()
  end
  server:close()
  uv.fs_unlink(path)
end

for _, mode in ipairs({ "timeout", "closed" }) do
  local path = "/tmp/sprite-channel-" .. mode .. "-" .. uv.os_getpid() .. ".sock"
  local server = uv.new_pipe(false)
  assert(server:bind(path))
  local peer, count = nil, 0
  server:listen(1, function()
    peer = uv.new_pipe(false)
    server:accept(peer)
    peer:read_start(function(_, bytes)
      if not bytes then
        return
      end
      for _ in bytes:gmatch("[^\n]+") do
        count = count + 1
        if count == 1 then
          peer:write('{"type":"opened","surface":7}\n')
        end
      end
    end)
  end)
  local channel, result, queued_result, calls, closes = nil, nil, nil, 0, 0
  Channel.connect({
    path = path,
    key = "secret",
    first = { type = "open" },
    timeout_ms = 30,
    on_close = function()
      closes = closes + 1
      T.eq(vim.in_fast_event(), false, mode .. " close scheduled")
    end,
  }, function(err, ch)
    T.eq(err, nil, mode .. " channel ready")
    channel = ch
    ch:request({ type = "assets", operation = "assets" }, "applied", function(request_err)
      calls = calls + 1
      result = request_err and request_err.code
      T.eq(vim.in_fast_event(), false, mode .. " completion scheduled")
    end)
    ch:request({ type = "update", operation = "update" }, "applied", function(request_err)
      calls = calls + 1
      queued_result = request_err and request_err.code
    end)
  end)
  T.ok(
    vim.wait(1000, function()
      return count == 2
    end),
    mode .. " request sent"
  )
  if mode == "closed" then
    channel:close("requested")
  end
  T.ok(
    vim.wait(1000, function()
      return result ~= nil
    end),
    mode .. " pending completed"
  )
  T.eq(result, mode, mode .. " error code")
  T.ok(
    vim.wait(1000, function()
      return queued_result ~= nil
    end),
    mode .. " queued completed"
  )
  T.eq(queued_result, mode, mode .. " queued error code")
  peer:write('{"type":"applied","operation":"assets"}\n')
  vim.wait(30)
  T.eq(calls, 2, mode .. " completions exactly once")
  T.eq(closes, 1, mode .. " close exactly once")
  if peer and not peer:is_closing() then
    peer:close()
  end
  server:close()
  uv.fs_unlink(path)
end

scenario({ '{"type":"op', 'ened","surface":7}\n{"type":"input","text":"x"}\n' }, "ready")
scenario(
  '{"type":"capabilities","version":1}\n',
  "ready",
  { first = { type = "capabilities" }, eof = true }
)
scenario('{"type":"focused"}', "ready", { first = { type = "focus" }, eof = true })
scenario('{"type":"registered"}\n', "ready", { first = { type = "token" }, eof = true })
scenario('{"type":"refused","reason":"no"}\n', "refused")
scenario("{}\n", "protocol")
scenario("{bad}\n", "protocol")
scenario(nil, "unavailable", { immediate_eof = true })
scenario(nil, "timeout", { timeout_ms = 10 })

do
  local path = "/tmp/sprite-channel-request-" .. uv.os_getpid() .. ".sock"
  local server = uv.new_pipe(false)
  assert(server:bind(path))
  local peer, lines, callbacks = nil, {}, {}
  server:listen(1, function()
    peer = uv.new_pipe(false)
    server:accept(peer)
    peer:read_start(function(_, bytes)
      if not bytes then
        return
      end
      for line in bytes:gmatch("[^\n]+") do
        lines[#lines + 1] = line
        if #lines == 1 then
          peer:write('{"type":"opened","surface":7}\n')
        end
      end
    end)
  end)
  local channel
  Channel.connect(
    { path = path, key = "secret", first = { type = "open" }, timeout_ms = 100 },
    function(err, ch)
      T.eq(err, nil, "request channel ready")
      channel = ch
      ch:request({ type = "assets", operation = "assets" }, "applied", function(e)
        callbacks[#callbacks + 1] = e and e.code or "ok"
      end)
      ch:request({ type = "update", operation = "update" }, "applied", function(e)
        callbacks[#callbacks + 1] = e and e.code or "ok"
      end)
    end
  )
  T.ok(
    vim.wait(1000, function()
      return #lines == 2
    end),
    "first request written"
  )
  T.eq(#lines, 2, "second request held")
  peer:write('{"type":"input","text":"x"}\n{"type":"applied","operation":"assets"}\n')
  T.ok(
    vim.wait(1000, function()
      return #lines == 3
    end),
    "second request follows first acknowledgement"
  )
  peer:write('{"type":"applied","operation":"wrong"}\n')
  T.ok(
    vim.wait(1000, function()
      return #callbacks == 2
    end),
    "pending callbacks drained"
  )
  T.eq(callbacks, { "ok", "protocol" }, "mismatched reply closes pending request")
  channel:close("done")
  if peer and not peer:is_closing() then
    peer:close()
  end
  server:close()
  uv.fs_unlink(path)
end
