local uv = vim.uv
local Session = {}
local MAX_SAFE_INTEGER = 9007199254740991

local function positive_integer(value)
  local n = tonumber(value)
  return n and n > 0 and n <= MAX_SAFE_INTEGER and n == math.floor(n) and n or nil
end

local function pane_integer(value)
  local n = tonumber(value)
  return n and n >= 0 and n <= MAX_SAFE_INTEGER and n == math.floor(n) and n or nil
end

function Session.resolve(facts)
  local pane = pane_integer(facts.pane)
  if
    type(facts.path) ~= "string"
    or facts.path == ""
    or type(facts.key) ~= "string"
    or facts.key == ""
    or pane == nil
  then
    return nil, { code = "unavailable", message = "Surface credentials unavailable" }
  end
  local pid = positive_integer(facts.pid)
  if not pid then
    return nil, { code = "unavailable", message = "process ID unavailable" }
  end
  local target, presentation
  if facts.marker ~= nil then
    if type(facts.marker) ~= "table" or facts.marker.pid ~= pid then
      return nil, { code = "unavailable", message = "stale editor marker" }
    end
    target = positive_integer(facts.marker.surface)
    if not target then
      return nil, { code = "unavailable", message = "invalid editor marker" }
    end
    presentation = "grid"
  else
    if facts.nvim or facts.tmux or facts.sty or facts.stdin ~= "tty" then
      return nil, { code = "unavailable", message = "terminal ownership unavailable" }
    end
    if type(facts.uis) ~= "table" or #facts.uis == 0 then
      return nil, { code = "unavailable", message = "UI unavailable" }
    end
    target, presentation = "terminal", "terminal"
  end
  return {
    pane = pane,
    path = facts.path,
    key = facts.key,
    pid = pid,
    return_target = target,
    presentation = presentation,
  }
end

function Session.current()
  return Session.resolve({
    pane = uv.os_getenv("SPRITE_PANE"),
    path = uv.os_getenv("SPRITE_SURFACE_SOCKET"),
    key = uv.os_getenv("SPRITE_SURFACE_KEY"),
    pid = uv.os_getpid(),
    marker = vim.g.sprite_session,
    uis = vim.api.nvim_list_uis(),
    stdin = uv.guess_handle(0),
    nvim = uv.os_getenv("NVIM"),
    tmux = uv.os_getenv("TMUX"),
    sty = uv.os_getenv("STY"),
  })
end

function Session.bootstrap(repo, surface)
  local id = positive_integer(surface)
  if type(repo) ~= "string" or repo == "" or not id then
    return nil, { code = "protocol", message = "invalid editor bootstrap" }
  end
  return "lua vim.opt.runtimepath:prepend("
    .. vim.json.encode(repo)
    .. "); vim.g.sprite_session = {pid=vim.fn.getpid(),surface="
    .. string.format("%.0f", id)
    .. "}"
end

-- A cancellable UIEnter wait; callers pass their absolute initialization deadline.
function Session.await_ui(deadline, callback)
  local done = false
  local cancelled = false
  local timer, autocmd
  local function finish(err, context)
    if done then
      return
    end
    done = true
    if autocmd then
      vim.api.nvim_del_autocmd(autocmd)
    end
    if timer then
      timer:stop()
      timer:close()
    end
    vim.schedule(function()
      if not cancelled then
        callback(err, context)
      end
    end)
  end
  local function check()
    if uv.now() >= deadline then
      finish({ code = "unavailable", message = "UI unavailable" })
      return
    end
    local context, err = Session.current()
    if context then
      finish(nil, context)
    elseif err.message ~= "UI unavailable" then
      finish(err)
    end
  end
  check()
  if not done then
    local remaining = deadline - uv.now()
    if remaining <= 0 then
      finish({ code = "unavailable", message = "UI unavailable" })
    else
      autocmd = vim.api.nvim_create_autocmd("UIEnter", { callback = check })
      timer = uv.new_timer()
      timer:start(remaining, 0, function()
        vim.schedule(function()
          finish({ code = "unavailable", message = "UI unavailable" })
        end)
      end)
    end
  end
  return function()
    cancelled = true
    if done then
      return
    end
    done = true
    if autocmd then
      vim.api.nvim_del_autocmd(autocmd)
    end
    if timer then
      timer:stop()
      timer:close()
    end
  end
end

return Session
