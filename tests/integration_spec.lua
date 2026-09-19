local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local uv = vim.uv

local function adapter_env(sock)
  -- A minimal environment plus the Sprite credentials. XDG_STATE_HOME points
  -- the adapter's log at a per-socket temp dir so a test never writes to the
  -- developer's real ~/.local/state/sprite-nvim/adapter.log.
  return {
    "SPRITE_SURFACE_SOCKET=" .. sock,
    "SPRITE_SURFACE_KEY=testkey",
    "SPRITE_PANE=1",
    "PATH=" .. vim.fn.fnamemodify(vim.v.progpath, ":h") .. ":" .. (uv.os_getenv("PATH") or ""),
    "VIMRUNTIME=" .. vim.env.VIMRUNTIME,
    "HOME=" .. (uv.os_getenv("HOME") or "/tmp"),
    "XDG_STATE_HOME=" .. sock .. ".state",
  }
end

-- Rebuilds the little slice of screen a set of collected batch lines describe,
-- so a check can ask "what does row N say" without caring how many flushes or
-- grid_line events the answer arrived across.
local function build_rows(lines)
  local rows = {}
  for _, line in ipairs(lines) do
    local ok, decoded = pcall(vim.json.decode, line)
    if ok and type(decoded) == "table" and decoded.type == "batch" then
      for _, op in ipairs(decoded.ops or {}) do
        if op.type == "rows" then
          for _, r in ipairs(op.rows or {}) do
            local row = rows[r.row] or {}
            rows[r.row] = row
            local col = r.col
            for _, cell in ipairs(r.cells or {}) do
              local text = cell[1] or ""
              local rep = cell[3] or 1
              for _ = 1, rep do
                row[col] = text
                col = col + 1
              end
            end
          end
        end
      end
    end
  end
  return rows
end

local function row_text(rows, r)
  local row = rows[r]
  if not row then
    return ""
  end
  local maxcol = -1
  for c in pairs(row) do
    if c > maxcol then
      maxcol = c
    end
  end
  local out = {}
  for c = 0, maxcol do
    out[#out + 1] = row[c] or " "
  end
  return table.concat(out)
end

do
  local Fake = dofile(root .. "/tests/fake_sprite.lua")
  local sock = "/tmp/sprite-nvim-stopped-" .. uv.getpid() .. ".sock"
  local server = Fake.serve(sock)
  local code
  local child = uv.spawn(vim.v.progpath, {
    args = { "-l", root .. "/tests/adapter_stopped_loop_child.lua" },
    env = adapter_env(sock),
    stdio = { nil, nil, 2 },
  }, function(exit_code)
    code = exit_code
  end)
  T.ok(
    vim.wait(3000, function()
      return #server.lines > 0 or code ~= nil
    end, 10),
    "stopped-loop child reaches a verdict"
  )
  T.eq(code, nil, "stale libuv stop cannot make a live adapter exit")
  T.ok(#server.lines > 0, "adapter redraw arrives after prior libuv stop")
  T.eq(server.invalid, nil, "strict fake accepts stopped-loop adapter messages")
  if child then
    child:kill("sigterm")
  end
  server.close()
end

-- Run the adapter as a child, driven by a fake Sprite, until `predicate(lines)`
-- holds or a timeout. Returns the collected lines. The adapter connects to
-- `sock`; the child gets the Sprite env so the launcher would take the adapter
-- path, but we invoke the adapter directly to keep the editor embedded.
local function drive(sock, opts, predicate, timeout_ms)
  local Fake = dofile(root .. "/tests/fake_sprite.lua")
  local server = Fake.serve(sock, opts)
  local child = uv.spawn(vim.v.progpath, {
    args = { "-l", root .. "/lua/sprite/adapter.lua", "--clean" },
    env = adapter_env(sock),
    stdio = { nil, nil, 2 },
  }, function() end)

  local deadline = uv.now() + (timeout_ms or 15000)
  local timer = uv.new_timer()
  timer:start(50, 50, function()
    if (predicate and predicate(server.lines)) or uv.now() > deadline then
      timer:stop()
      uv.stop()
    end
  end)
  while timer:is_active() and uv.loop_alive() do
    uv.run()
  end
  if child then
    child:kill("sigterm")
  end
  T.eq(server.invalid, nil, "strict fake accepts adapter wire messages")
  server.close()
  return server.lines
end

-- The empty buffer draws tildes: after attach, some batch's rows carry "~".
do
  local sock = "/tmp/sprite-nvim-test-" .. uv.getpid() .. "-a.sock"
  local lines = drive(sock, {}, function(lines)
    for _, l in ipairs(lines) do
      if l:find('"~"', 1, true) then
        return true
      end
    end
    return false
  end)
  local saw_tilde = false
  for _, l in ipairs(lines) do
    if l:find('"~"', 1, true) then
      saw_tilde = true
    end
  end
  T.ok(saw_tilde, "the empty buffer's tildes reach Sprite as rows")

  local Fake = dofile(root .. "/tests/fake_sprite.lua")
  for _, line in ipairs(lines) do
    local valid, reason = Fake.validate(vim.json.decode(line))
    T.ok(valid, "fake Sprite accepts adapter batch: " .. tostring(reason))
  end

  -- Nothing the adapter sends may carry an empty-array highlight value
  -- ("...":[]) -- the real Sprite refuses it, which would kill the session on
  -- the first frame. Keep this check as a direct wire-level diagnostic.
  local bad = false
  for _, l in ipairs(lines) do
    if l:find('":[]', 1, true) then
      bad = true
    end
  end
  T.ok(not bad, "no batch carries an empty-array highlight Sprite would refuse")
end

-- Inbound round-trip: an "input" event sent through the fake Sprite after
-- attach reaches the embedded editor and the typed text comes back out in a
-- later rows batch. Proves the Surface-event -> nvim_input -> redraw path is
-- wired both ways, not just the outbound half the tilde check proves. `drive`
-- doesn't expose the server it builds internally, and this check needs to
-- reach into the live connection mid-session, so it drives directly.
do
  local sock = "/tmp/sprite-nvim-test-" .. uv.getpid() .. "-b.sock"
  local Fake = dofile(root .. "/tests/fake_sprite.lua")
  local sent = false
  local server
  server = Fake.serve(sock, {
    on_line = function()
      -- The first line after the handshake is the initial full redraw
      -- (already proven above to carry tildes): the editor is attached and
      -- ready for input. Enter insert mode and type "abc".
      if not sent then
        sent = true
        server.send({ type = "input", text = "iabc" })
      end
    end,
  })
  local child = uv.spawn(vim.v.progpath, {
    args = { "-l", root .. "/lua/sprite/adapter.lua", "--clean" },
    env = adapter_env(sock),
    stdio = { nil, nil, 2 },
  }, function() end)

  local deadline = uv.now() + 15000
  local timer = uv.new_timer()
  timer:start(50, 50, function()
    local rows = build_rows(server.lines)
    local done = false
    for r in pairs(rows) do
      if row_text(rows, r):find("abc", 1, true) then
        done = true
      end
    end
    if done or uv.now() > deadline then
      timer:stop()
      uv.stop()
    end
  end)
  while timer:is_active() and uv.loop_alive() do
    uv.run()
  end
  if child then
    child:kill("sigterm")
  end
  local rows = build_rows(server.lines)
  server.close()
  local saw_abc = false
  for r in pairs(rows) do
    if row_text(rows, r):find("abc", 1, true) then
      saw_abc = true
    end
  end
  T.ok(saw_abc, "input typed through the fake Sprite reaches Neovim and returns in a rows batch")
end

-- Socket-drop exit 129: once the session is live (attached and drawing),
-- losing Sprite must kill the editor and exit 129 -- the same thing a hung-up
-- terminal does today.
do
  local sock = "/tmp/sprite-nvim-test-" .. uv.getpid() .. "-c.sock"
  local Fake = dofile(root .. "/tests/fake_sprite.lua")
  local drew = false
  local server = Fake.serve(sock, {
    on_line = function(line)
      if not drew and line:find('"~"', 1, true) then
        drew = true
      end
    end,
  })
  local code
  local child = uv.spawn(vim.v.progpath, {
    args = { "-l", root .. "/lua/sprite/adapter.lua", "--clean" },
    env = adapter_env(sock),
    stdio = { nil, nil, 2 },
  }, function(c)
    code = c
    uv.stop()
  end)
  local deadline = uv.now() + 15000
  local closed = false
  local timer = uv.new_timer()
  timer:start(50, 50, function()
    if drew and not closed then
      closed = true
      server.close()
    end
    if uv.now() > deadline then
      timer:stop()
      uv.stop()
    end
  end)
  while timer:is_active() and uv.loop_alive() do
    uv.run()
  end
  if child then
    child:kill("sigterm")
  end
  T.eq(code, 129, "losing Sprite mid-session kills the editor and exits 129")
end

-- A refused open runs the real editor and the adapter exits with its code.
do
  local sock = "/tmp/sprite-nvim-test-" .. uv.getpid() .. "-d.sock"
  local Fake = dofile(root .. "/tests/fake_sprite.lua")
  local server = Fake.serve(sock, { refuse = true })
  local code
  local child = uv.spawn(vim.v.progpath, {
    args = { "-l", root .. "/lua/sprite/adapter.lua", "--clean", "--headless", "-c", "cquit 5" },
    env = adapter_env(sock),
    stdio = { nil, nil, 2 },
  }, function(c)
    code = c
    uv.stop()
  end)
  local timer = uv.new_timer()
  timer:start(8000, 0, function()
    timer:stop()
    uv.stop()
  end)
  while timer:is_active() and uv.loop_alive() do
    uv.run()
  end
  if child then
    child:kill("sigterm")
  end
  server.close()
  T.eq(code, 5, "a refused open falls open to the real editor and returns its code")
end

-- Fail-open stdin hygiene: give the adapter a real stdin pipe (not an ignored
-- fd) and write to it before the editor spawns. Task 6's review found that
-- fail_open must never drain fd 0 itself -- the real editor's stdio is
-- {0,1,2} and would race the adapter's own drain reader for the same
-- keystrokes. This proves a live pipe on fd 0 doesn't stop fail-open from
-- working, i.e. the drain path is not engaged before the handshake refuses.
--
-- What this does NOT prove: that the bytes we write are legible to the real
-- editor as keystrokes. `--headless -c 'cquit 5'` exits before reading stdin
-- at all, so the exit code can't distinguish "editor read our bytes" from
-- "editor never looked at stdin" -- both give the same code. Proving the
-- bytes truly reach the fallback editor's own input would need a genuine
-- interactive session (a pty, or a command that echoes stdin back out),
-- which is impractical to assert deterministically headless. What we can and
-- do assert: the adapter, handed a real writable stdin, still falls open
-- correctly and returns the expected code -- ruling out the class of bug
-- where a live fd 0 causes fail_open to hang or misbehave.
do
  local sock = "/tmp/sprite-nvim-test-" .. uv.getpid() .. "-e.sock"
  local Fake = dofile(root .. "/tests/fake_sprite.lua")
  local server = Fake.serve(sock, { refuse = true })
  local child_stdin = uv.new_pipe(false)
  local code
  local child = uv.spawn(vim.v.progpath, {
    args = { "-l", root .. "/lua/sprite/adapter.lua", "--clean", "--headless", "-c", "cquit 5" },
    env = adapter_env(sock),
    stdio = { child_stdin, nil, 2 },
  }, function(c)
    code = c
    uv.stop()
  end)
  if child then
    child_stdin:write("some keystrokes\n")
  end
  local timer = uv.new_timer()
  timer:start(8000, 0, function()
    timer:stop()
    uv.stop()
  end)
  while timer:is_active() and uv.loop_alive() do
    uv.run()
  end
  if child then
    child:kill("sigterm")
  end
  server.close()
  T.eq(
    code,
    5,
    "fail-open with a live stdin pipe (bytes written, not just a dangling fd) still runs the real editor and returns its code"
  )
end

-- Speed gate: a 200x60 full repaint translates to one batch within 10 ms.
do
  local Redraw = dofile(root .. "/lua/sprite/redraw.lua")
  local s = Redraw.new()
  s:event({ "grid_resize", { 1, 200, 60 } })
  s:take_batch()
  local cells = {}
  for i = 1, 200 do
    cells[i] = { string.char(97 + (i % 26)), 1 }
  end
  local t0 = uv.hrtime()
  local line
  for _ = 1, 3 do
    s = Redraw.new()
    for row = 0, 59 do
      s:event({ "grid_line", { 1, row, 0, cells, false } })
    end
    s:event({ "flush" })
    line = vim.json.encode({ type = "batch", ops = s:take_batch() })
  end
  local ms = (uv.hrtime() - t0) / 1e6 / 3
  T.ok(#line > 0, "the repaint produced a batch line")
  T.ok(ms < 10, string.format("200x60 repaint batches in under 10 ms (was %.2f ms)", ms))
end
