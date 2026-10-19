local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local Fake = dofile(root .. "/tests/fake_sprite.lua")
local uv = vim.uv
local fixture = vim.fn.tempname() .. ".lua"
vim.fn.writefile({
  "local n=0; require('sprite.minimap').setup({next=function() n=n+1; local f=vim.json.decode(table.concat(vim.fn.readfile('"
    .. root
    .. "/tests/fixtures/minimap-v1.json'),'\\n')); return f.valid[n] end, dispatch=function() return true end, before_input=function() end, stop=function() end})",
}, fixture)
local updates = {}
local sock = "/tmp/sprite-minimap-" .. uv.getpid() .. ".sock"
local server = Fake.serve(sock, {
  features = { "grid-minimap-v1", "grid-tabs-v1" },
  on_line = function(line)
    local m = vim.json.decode(line)
    if m.type == "minimap" then
      updates[#updates + 1] = m
    end
  end,
})
local child = uv.spawn(vim.v.progpath, {
  args = { "-l", root .. "/lua/sprite/adapter.lua", "--clean", "-u", fixture },
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
    return #updates >= 5
  end, 10),
  "negotiated adapter drains minimap fixture"
)
T.eq(server.invalid, nil, "minimap messages accepted by fake host")
if child then
  child:kill("sigterm")
end
server.close()
vim.fn.delete(fixture)

local function launch(name, features, code, on_message)
  local init = vim.fn.tempname() .. ".lua"
  local path = "/tmp/sprite-minimap-" .. uv.getpid() .. "-" .. name .. ".sock"
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
  local function close()
    if process then
      process:kill("sigterm")
    end
    host.close()
    vim.fn.delete(init)
  end
  return host, messages, close
end
local function command(host, text)
  host.send({ type = "input", text = ":" .. text })
  host.send({ type = "input", key = "enter" })
end
local function wait_file(path)
  return vim.wait(5000, function()
    return vim.fn.filereadable(path) == 1
  end, 10)
end
local function has(messages, kind)
  for _, m in ipairs(messages) do
    if m.type == "minimap" and m.kind == kind then
      return true
    end
  end
end
local metrics = vim.fn.tempname()
local burst, burst_messages, close_burst
local sent = false
burst, burst_messages, close_burst = launch(
  "burst",
  { "grid-minimap-v1", "grid-tabs-v1" },
  [[
local step, offset = 0, 0
require('sprite.minimap').setup({next=function()
  step=step+1
  if step==1 then return {kind='begin',target='burst',generation=1,base=vim.NIL,start=1,delete=0,insert=100000,total=100000,palette={'#ffffff'},background='#000000'} end
  if offset<100000 then
    local lines={}; for i=1,math.min(256,100000-offset) do lines[i]={text='source',spans={}} end
    local result={kind='lines',target='burst',generation=1,offset=offset,lines=lines}; offset=offset+#lines; return result
  end
  if step==393 then return {kind='commit',target='burst',generation=1} end
end,dispatch=function() end,before_input=function() end,stop=function() end})
]],
  function(m)
    if m.type == "minimap" and m.kind == "begin" and not sent then
      sent = true
      burst.send({ type = "input", text = "iORDER" })
      burst.send({ type = "paste", text = "-PASTE" })
      burst.send({ type = "input", key = "escape" })
    end
  end
)
T.ok(
  vim.wait(10000, function()
    return has(burst_messages, "commit")
  end, 10),
  "100k source drain yields until commit"
)
command(
  burst,
  "lua vim.fn.writefile({vim.api.nvim_get_current_line()}, " .. string.format("%q", metrics) .. ")"
)
T.ok(wait_file(metrics), "typing remains responsive during chunk drain")
if vim.fn.filereadable(metrics) == 1 then
  T.eq(vim.fn.readfile(metrics), { "ORDER-PASTE" }, "typed text and one paste arrive in order")
end
local chunks = 0
for _, m in ipairs(burst_messages) do
  if m.type == "minimap" and m.kind == "lines" then
    chunks = chunks + 1
  end
end
T.eq(chunks, 391, "100000 source rows travel as bounded chunks")
T.eq(burst.invalid, nil)
close_burst()
vim.fn.delete(metrics)

local dormant = vim.fn.tempname()
for _, features in ipairs({ {}, { "grid-minimap-v1" } }) do
  local present = #features == 0
  local host, messages, close = launch(
    present and "old" or "absent",
    features,
    present
        and ("require('sprite.minimap').setup({next=function() vim.fn.writefile({'started'}, " .. string.format(
          "%q",
          dormant
        ) .. "); return nil end,stop=function() end})")
      or ""
  )
  T.ok(
    vim.wait(3000, function()
      return #messages > 0
    end, 10),
    "editor draws without negotiated provider"
  )
  vim.wait(100, function()
    return false
  end, 10)
  T.eq(has(messages, "begin"), nil, "old host or absent provider sends no source")
  T.eq(vim.fn.filereadable(dormant), 0, "old host starts no provider work")
  close()
end

local vsvim = vim.env.VSVIM_SOURCE or vim.fn.fnamemodify(root, ":h") .. "/VSVim"
if vim.fn.filereadable(vsvim .. "/lua/vsvim/minimap.lua") == 1 then
  local observed = vim.fn.tempname()
  local code = string.format(
    [[
vim.opt.rtp:prepend(%q)
vim.o.swapfile=false
vim.o.mouse="a"
require('vsvim.editing').setup()
vim.keymap.set('x','Q','ygg0v3ld')
_G.clip={{'replacement'},'v'}
vim.g.clipboard={name='fixture',cache_enabled=0,copy={['+']=function(lines,kind) _G.clip={lines,kind} end,['*']=function() end},paste={['+']=function() return _G.clip end,['*']=function() return _G.clip end}}
local rows={'word first line'}; for i=2,1000 do rows[i]='row '..i..' word' end
vim.api.nvim_buf_set_lines(0,0,-1,false,rows)
require('vsvim.minimap').setup()
local function observe()
  vim.fn.writefile({vim.json.encode({mode=vim.fn.mode(),line=vim.api.nvim_get_current_line(),first=vim.api.nvim_buf_get_lines(0,0,1,false)[1],top=vim.fn.line('w0'),reg=vim.fn.getreg('"'),clip=_G.clip[1],maps={vim.fn.maparg('y','x'),vim.fn.maparg('d','x'),vim.fn.maparg('c','x')}})}, %q)
  vim.defer_fn(observe,20)
end
vim.defer_fn(observe,20)
]],
    vsvim,
    observed
  )
  local real, messages, close = launch("real", { "grid-minimap-v1", "grid-tabs-v1" }, code)
  local function snapshot()
    if vim.fn.filereadable(observed) == 0 then
      return {}
    end
    local ok, value = pcall(vim.json.decode, table.concat(vim.fn.readfile(observed), "\n"))
    return ok and value or {}
  end
  local function await(predicate, label)
    T.ok(
      vim.wait(5000, function()
        return predicate(snapshot())
      end, 10),
      label
    )
  end
  local function latest_state()
    for i = #messages, 1, -1 do
      local m = messages[i]
      if m.type == "minimap" and m.kind == "state" then
        return m
      end
    end
  end
  T.ok(
    vim.wait(5000, function()
      return latest_state() ~= nil
    end, 10),
    "real provider commits initial source through adapter"
  )
  local function select(text)
    real.send({ type = "input", text = text })
    await(function(s)
      return s.mode == "v"
    end, "native Visual selection enters through adapter")
    T.ok(
      vim.wait(3000, function()
        local s = latest_state()
        return s and s.selection ~= vim.NIL
      end, 10),
      "selection overlay reaches host"
    )
  end
  local function browse()
    local state = latest_state()
    if not state then
      return
    end
    local before = #messages
    real.send({
      type = "minimap_action",
      target = state.target,
      generation = state.generation,
      revision = state.revision,
      action = "scroll",
      topline = 500,
    })
    await(function(s)
      return s.top and s.top >= 490 and s.mode == "n"
    end, "minimap action browses without consuming selection")
    T.ok(
      vim.wait(3000, function()
        local s = latest_state()
        return s and s.viewport[1] >= 490
      end, 10),
      "viewport-only update reaches host"
    )
    local source = 0
    for i = before + 1, #messages do
      local m = messages[i]
      if m.type == "minimap" and (m.kind == "begin" or m.kind == "lines") then
        source = source + 1
      end
    end
    T.eq(source, 0, "scrolling sends no source chunks")
  end
  select("gg0v3l")
  browse()
  real.send({ type = "mouse", button = "wheel", action = "down", modifiers = "", row = 1, col = 1 })
  await(function(s)
    return s.top and s.top > 500 and s.mode == "n"
  end, "editor wheel scrolls browsed viewport while retaining saved selection")
  real.send({ type = "input", key = "cmd-c" })
  await(function(s)
    return s.clip and s.clip[1] == "word" and s.mode == "v"
  end, "Cmd-C copies original selection through real adapter")
  browse()
  real.send({ type = "mouse", button = "left", action = "press", modifiers = "", row = 1, col = 1 })
  T.ok(
    vim.wait(3000, function()
      local s = latest_state()
      return s and s.selection == vim.NIL
    end, 10),
    "actual editor left click clears saved selection"
  )
  real.send({ type = "input", text = "yy" })
  await(function(s)
    return s.reg and s.reg:match("^row ") ~= nil
  end, "native yank after editor click stays at clicked row")
  select("gg0v3l")
  browse()
  real.send({ type = "input", key = "cmd-x" })
  await(function(s)
    return s.first == " first line" and s.mode == "n"
  end, "Cmd-X cuts original selection once")
  T.ok(
    vim.wait(5000, function()
      local s = latest_state()
      return s and s.generation > 1
    end, 10),
    "cut commits updated source"
  )
  select("gg0v5l")
  browse()
  real.send({ type = "input", key = "cmd-v" })
  await(function(s)
    return s.first == "word line"
  end, "Cmd-V replaces preserved selection through existing clipboard mapping")
  real.send({ type = "input", key = "escape" })
  T.ok(
    vim.wait(5000, function()
      local s = latest_state()
      return s and s.generation > 2
    end, 10),
    "clipboard paste commits updated source"
  )
  select("gg0v3l")
  browse()
  real.send({ type = "paste", text = "PASTE" })
  await(function(s)
    return s.first == "PASTE line"
  end, "native paste replaces preserved original selection once")
  real.send({ type = "input", key = "escape" })
  T.ok(
    vim.wait(5000, function()
      local s = latest_state()
      return s and s.generation > 3
    end, 10),
    "paste commits updated source"
  )
  select("gg0v4l")
  browse()
  real.send({ type = "input", key = "escape" })
  await(function(s)
    return s.mode == "n" and s.top >= 490
  end, "normalized Escape clears without jumping back")
  select("gg0v4l")
  browse()
  real.send({ type = "input", text = "ygg0v4ld" })
  await(function(s)
    return s.reg == "PASTE" and s.first == " line"
  end, "batched native operators consume restored then new selection")
  T.ok(
    vim.wait(5000, function()
      local s = latest_state()
      return s and s.generation > 4
    end, 10),
    "batched operators commit updated source"
  )
  select("gg0v3l")
  browse()
  real.send({ type = "input", text = "Q" })
  await(function(s)
    return s.reg == " lin" and s.first == "e"
  end, "single Visual mapping runs restored and subsequent native operators")
  T.eq(snapshot().maps, { "", "", "" }, "default Visual y/d/c remain unmapped")
  T.eq(real.invalid, nil)
  close()
  vim.fn.delete(observed)
else
  print("  actual VSVim provider checks skipped; set VSVIM_SOURCE to its checkout")
end

local stopped_file = vim.fn.tempname()
local restart_code = string.format(
  [[
local n,generation=0,1
local f=vim.json.decode(table.concat(vim.fn.readfile(%q),'\n'))
require('sprite.minimap').setup({next=function()
  n=n+1; local op=vim.deepcopy(f.valid[n]); if op and op.target then op.target='restart:'..generation;op.generation=generation end; if n==2 and generation==1 then vim.wait(100,function() return false end,10) end; return op
end,dispatch=function() return true end,before_input=function() end,stop=function()
  n=0; generation=generation+1; vim.fn.writefile({tostring(generation)},%q,'a')
end})
]],
  root .. "/tests/fixtures/minimap-v1.json",
  stopped_file
)
local restart, messages, close_restart
local refused = false
restart, messages, close_restart = launch(
  "restart",
  { "grid-minimap-v1", "grid-tabs-v1" },
  restart_code,
  function(m)
    if m.type == "minimap" and m.kind == "begin" and not refused then
      refused = true
      vim.defer_fn(function()
        restart.send({ type = "refused", reason = "malformed: invalid minimap operation" })
      end, 10)
    end
  end
)
T.ok(
  vim.wait(5000, function()
    for _, m in ipairs(messages) do
      if m.type == "minimap" and m.kind == "hide" then
        return true
      end
    end
  end, 10),
  "minimap refusal hides and disables the failed source transaction"
)
T.ok(wait_file(stopped_file), "restart stops source jobs")
local watermark, seen_hide, stale_after_hide = 0, false, false
for _, m in ipairs(messages) do
  if m.type == "minimap" then
    T.ok(m.revision > watermark, "revisions remain connection-global through restart")
    watermark = m.revision
    if m.kind == "hide" then
      seen_hide = true
    elseif seen_hide then
      stale_after_hide = true
    end
  end
end
T.ok(seen_hide, "refusal clears staged source with hide")
T.eq(stale_after_hide, false, "no source response follows refusal hide")
local stops = #vim.fn.readfile(stopped_file)
local minimap_count = 0
for _, m in ipairs(messages) do
  if m.type == "minimap" then
    minimap_count = minimap_count + 1
  end
end
for _ = 1, 3 do
  restart.send({ type = "refused", reason = "malformed: invalid minimap operation" })
end
vim.wait(200, function()
  return false
end, 10)
local after_count = 0
for _, m in ipairs(messages) do
  if m.type == "minimap" then
    after_count = after_count + 1
  end
end
T.eq(
  after_count,
  minimap_count,
  "repeated protocol refusals do not restart or pull the same source"
)
T.eq(#vim.fn.readfile(stopped_file), stops, "repeated refusals leave the provider stopped")
restart.send({ type = "refused", reason = "invalid cursor" })
command(restart, "file tabs-still-live.lua")
T.ok(
  vim.wait(3000, function()
    for _, m in ipairs(messages) do
      if m.type == "tabs" and m.items[1] and m.items[1].label == "tabs-still-live.lua" then
        return true
      end
    end
  end, 10),
  "minimap refusal leaves native tabs and editor alive"
)
T.eq(#vim.fn.readfile(stopped_file), stops, "unrelated refusal does not restart minimap")
restart.send({ type = "closed" })
close_restart()
vim.fn.delete(stopped_file)

local failed_input = vim.fn.tempname()
local failure_code = string.format(
  [[
local n=0;local f=vim.json.decode(table.concat(vim.fn.readfile(%q),'\n'))
require('sprite.minimap').setup({next=function() n=n+1; return n<=4 and f.valid[n] or nil end,
 dispatch=function() end,stop=function() end,before_input=function(e) if e.type=='paste' then error('fixture paste hook failed') end end})
]],
  root .. "/tests/fixtures/minimap-v1.json"
)
local failure, failure_messages, close_failure =
  launch("failure", { "grid-minimap-v1", "grid-tabs-v1" }, failure_code)
T.ok(
  vim.wait(3000, function()
    return has(failure_messages, "state")
  end, 10),
  "failure fixture commits source"
)
failure.send({ type = "input", text = "i" })
failure.send({ type = "paste", text = "ONCE" })
failure.send({ type = "input", key = "escape" })
command(
  failure,
  "lua vim.fn.writefile({vim.api.nvim_get_current_line()}, "
    .. string.format("%q", failed_input)
    .. ")"
)
T.ok(wait_file(failed_input), "editor accepts input after provider hook exception")
if vim.fn.filereadable(failed_input) == 1 then
  T.eq(
    vim.fn.readfile(failed_input),
    { "ONCE" },
    "hook exception neither drops nor duplicates paste"
  )
end
T.ok(
  vim.wait(3000, function()
    return has(failure_messages, "hide")
  end, 10),
  "provider callback exception hides minimap"
)
T.eq(failure.invalid, nil)
close_failure()
vim.fn.delete(failed_input)

local quit_stops = vim.fn.tempname()
local quit, quit_messages, close_quit = launch(
  "quit",
  { "grid-minimap-v1" },
  string.format(
    [[
require('sprite.minimap').setup({next=function() return nil end,stop=function() vim.fn.writefile({'stopped'},%q) end})
]],
    quit_stops
  )
)
T.ok(
  vim.wait(3000, function()
    return #quit_messages > 0
  end, 10),
  "quit fixture editor starts"
)
command(quit, "qa!")
T.ok(wait_file(quit_stops), "normal editor exit stops provider")
close_quit()
vim.fn.delete(quit_stops)

local pulling, actions, settled = vim.fn.tempname(), vim.fn.tempname(), vim.fn.tempname()
local watermark_host, watermark_messages, close_watermark = launch(
  "forwarded-watermark",
  { "grid-minimap-v1" },
  string.format(
    [[
local n=0
local fixture=vim.json.decode(table.concat(vim.fn.readfile(%q),'\n'))
require('sprite.minimap').setup({next=function()
  n=n+1
  if n<=4 then return fixture.valid[n] end
  if n==5 then
    vim.fn.writefile({'pulling'},%q)
    vim.uv.sleep(300)
    return fixture.valid[4]
  end
end,dispatch=function(event) vim.fn.writefile({tostring(event.revision)},%q,'a'); return true end,
 before_input=function() end,stop=function() end})
]],
    root .. "/tests/fixtures/minimap-v1.json",
    pulling,
    actions
  )
)
T.ok(wait_file(pulling), "state pull is outstanding before future pointer action")
T.ok(
  vim.wait(3000, function()
    return has(watermark_messages, "state")
  end, 10),
  "captured state reaches fake host before pending-pull assertion"
)
local captured
for _, message in ipairs(watermark_messages) do
  if message.type == "minimap" and message.kind == "state" then
    captured = message
  end
end
T.ok(captured ~= nil, "pointer captures an actually forwarded state")
if captured then
  local action = {
    type = "minimap_action",
    target = captured.target,
    generation = captured.generation,
    revision = captured.revision + 1,
    action = "scroll",
    topline = 2,
  }
  watermark_host.send(action)
  action.revision = captured.revision
  watermark_host.send(action)
  T.ok(
    vim.wait(3000, function()
      for _, message in ipairs(watermark_messages) do
        if message.type == "minimap" and message.revision > captured.revision then
          return true
        end
      end
    end, 10),
    "delayed state response is eventually forwarded"
  )
  watermark_host.send(action)
  command(
    watermark_host,
    "lua vim.fn.writefile({'settled'}, " .. string.format("%q", settled) .. ")"
  )
  T.ok(wait_file(settled), "ordered RPC stream drains pointer actions")
  T.eq(
    vim.fn.filereadable(actions) == 1 and vim.fn.readfile(actions) or {},
    { tostring(captured.revision), tostring(captured.revision) },
    "future action never dispatches; captured drag revision remains valid across state progress"
  )
end
T.eq(watermark_host.invalid, nil)
close_watermark()
for _, path in ipairs({ pulling, actions, settled }) do
  vim.fn.delete(path)
end

local ui_observed = vim.fn.tempname()
local ui_host, ui_messages, close_ui = launch(
  "ui-rpc-events",
  { "grid-minimap-v1" },
  string.format(
    [[
local focus,hooks={},{}
vim.api.nvim_create_autocmd({'FocusGained','FocusLost'},{callback=function(e) focus[#focus+1]=e.event end})
require('sprite.minimap').setup({next=function() return nil end,stop=function() end,before_input=function(e) hooks[#hooks+1]=e.type end})
local function observe()
  local ui=vim.api.nvim_list_uis()[1]
  if ui then vim.fn.writefile({vim.json.encode({width=ui.width,height=ui.height,first=vim.api.nvim_buf_get_lines(0,0,1,false)[1],focus=focus,hooks=hooks})},%q) end
  vim.defer_fn(observe,20)
end
vim.defer_fn(observe,20)
]],
    ui_observed
  )
)
T.ok(wait_file(ui_observed), "negotiated minimap UI observer starts")
local function observed_ui()
  if vim.fn.filereadable(ui_observed) == 0 then
    return {}
  end
  local ok, result = pcall(vim.json.decode, table.concat(vim.fn.readfile(ui_observed), "\n"))
  return ok and result or {}
end
ui_host.send({ type = "input", text = "iORDER" })
ui_host.send({ type = "resize", cols = 60, rows = 18, width = 480, height = 288 })
ui_host.send({ type = "input", text = "-RESIZED" })
ui_host.send({ type = "blur" })
ui_host.send({ type = "focus" })
ui_host.send({ type = "paste", text = "-PASTE" })
ui_host.send({ type = "input", key = "escape" })
T.ok(
  vim.wait(3000, function()
    return observed_ui().first == "ORDER-RESIZED-PASTE"
  end, 10),
  "editing input stays ordered around UI resize and focus RPCs"
)
T.ok(
  vim.wait(3000, function()
    local ui = observed_ui()
    return ui.width == 60 and ui.height == 18
  end, 10),
  "negotiated minimap resize reaches actual attached Neovim UI"
)
T.ok(
  vim.wait(3000, function()
    local events = observed_ui().focus or {}
    return #events >= 2 and events[#events - 1] == "FocusLost" and events[#events] == "FocusGained"
  end, 10),
  "negotiated minimap blur and focus reach actual editor autocmds"
)
T.eq(
  observed_ui().hooks,
  { "input", "input", "paste", "input" },
  "only editing input enters synchronous minimap hook"
)
T.eq(ui_host.invalid, nil)
close_ui()
vim.fn.delete(ui_observed)

-- Exercise companion capability propagation through the actual adapter process.
do
  local code = string.format(
    [[
local f=vim.json.decode(table.concat(vim.fn.readfile(%q),'\n'))
local index,ack=0,nil
require('sprite.minimap').setup({acknowledge_actions=true,next=function()
 if ack then local value=vim.deepcopy(f.valid[4]);value.action_id=ack;ack=nil;return value end
 index=index+1;if index<=4 then return vim.deepcopy(f.valid[index]) end
end,dispatch=function(event) ack=event.action_id;require('sprite.minimap').changed();return true end,stop=function() end})
]],
    root .. "/tests/fixtures/minimap-v1.json"
  )
  local host, messages, close =
    launch("action-ack", { "grid-minimap-v1", "grid-minimap-ack-v1" }, code)
  T.ok(
    vim.wait(5000, function()
      for _, m in ipairs(messages) do
        if m.kind == "state" then
          return true
        end
      end
    end, 10),
    "ack-capable actual adapter initializes"
  )
  local commit
  local begin
  for _, m in ipairs(messages) do
    if m.kind == "commit" then
      commit = m
    elseif m.kind == "begin" then
      begin = m
    end
  end
  T.eq(begin and begin.action_ack, true, "adapter forwards companion capability to bridge")
  if commit then
    host.send({
      type = "minimap_action",
      revision = commit.revision,
      target = commit.target,
      generation = commit.generation,
      action = "scroll",
      topline = 1,
      action_id = 41,
    })
    T.ok(
      vim.wait(5000, function()
        for _, m in ipairs(messages) do
          if m.kind == "state" and m.action_id == 41 then
            return true
          end
        end
      end, 10),
      "processed action id crosses actual adapter both directions"
    )
  end
  close()
end
