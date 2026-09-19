local uv = vim.uv
local unpack = table.unpack or unpack
local Channel = require("sprite.channel")
local Session = require("sprite.session")
local M = { session = Session }
local REQUIRED = { "owned-dock-v1", "virtual-list-v1", "svg-assets-v1", "dock-resize-v1" }
local handles, pending, resumes, active = {}, {}, {}, {}
local exiting = false

local function err(code, message)
  return { code = code, message = message or code }
end

local function callback(fn, ...)
  if not fn then
    return
  end
  local args = { n = select("#", ...), ... }
  vim.schedule(function()
    local ok, failure = pcall(fn, unpack(args, 1, args.n))
    if not ok then
      vim.notify("sprite callback: " .. tostring(failure), vim.log.levels.ERROR)
    end
  end)
end

local function remaining(deadline)
  return math.max(1, deadline - uv.now())
end

local function exchange(context, first, deadline, done, on_close, on_event)
  if uv.now() >= deadline then
    callback(done, err("timeout"))
    return function() end
  end
  local cancel
  cancel = Channel.connect({
    path = context.path,
    key = context.key,
    first = first,
    timeout_ms = remaining(deadline),
    on_close = on_close,
    on_event = on_event,
  }, function(e, ch)
    active[cancel] = nil
    done(e, ch)
  end)
  active[cancel] = true
  return function()
    active[cancel] = nil
    cancel()
  end
end

local function capabilities(context, deadline, done)
  local cancel
  cancel = exchange(
    context,
    {
      type = "capabilities",
      version = 1,
      pane = context.pane,
      owner_pid = context.pid,
      return_target = context.return_target,
    },
    deadline,
    function(e, ch)
      if e then
        done(e)
        return
      end
      local reply = ch.first_reply
      ch:close()
      if reply.version ~= 1 or type(reply.features) ~= "table" or reply.eligible ~= true then
        done(err("unsupported", "native dock unavailable"))
        return
      end
      local features = {}
      for _, feature in ipairs(reply.features) do
        features[feature] = true
      end
      for _, feature in ipairs(REQUIRED) do
        if not features[feature] then
          done(err("unsupported", "native dock unavailable"))
          return
        end
      end
      done(nil, { features = features, limits = reply.limits })
    end
  )
  return cancel
end

function M.available(done)
  local deadline = uv.now() + 2000
  local cancel_wait, cancel_exchange
  local cancelled = false
  local function cancel()
    if cancelled then
      return
    end
    cancelled = true
    pending[cancel] = nil
    if cancel_wait then
      cancel_wait()
    end
    if cancel_exchange then
      cancel_exchange()
    end
  end
  pending[cancel] = cancel
  cancel_wait = Session.await_ui(deadline, function(e, context)
    if cancelled then
      return
    end
    if e then
      pending[cancel] = nil
      callback(done, e)
      return
    end
    cancel_exchange = capabilities(context, deadline, function(discovery_err, result)
      if not cancelled then
        pending[cancel] = nil
        callback(done, discovery_err, result)
      end
    end)
  end)
  return cancel
end

function M.register_tokens(tokens, done)
  if type(tokens) ~= "table" or not vim.islist(tokens) then
    callback(done, err("protocol", "tokens must be an array"))
    return
  end
  local context, context_err = Session.current()
  if not context then
    callback(done, context_err)
    return
  end
  local index = 0
  local function next_token()
    index = index + 1
    local token = tokens[index]
    if not token then
      callback(done, nil)
      return
    end
    if
      type(token) ~= "table"
      or type(token.name) ~= "string"
      or type(token.default) ~= "string"
      or type(token.description) ~= "string"
    then
      callback(done, err("protocol", "invalid token"))
      return
    end
    exchange(
      context,
      {
        type = "token",
        name = token.name,
        default = token.default,
        description = token.description,
      },
      uv.now() + 2000,
      function(e, ch)
        if ch then
          ch:close()
        end
        if e then
          callback(done, e)
        else
          next_token()
        end
      end
    )
  end
  next_token()
end

local Handle = {}
Handle.__index = Handle
local owned = setmetatable({}, { __mode = "k" })

local function end_handle(self, kind, failure)
  if self.closed then
    return
  end
  self.closed = true
  handles[self] = nil
  if owned[self] and owned[self].channel then
    owned[self].channel:close(failure or err("closed"))
  end
  callback(self.on_close, { kind = kind, error = failure })
end

local function mutation(self, message, done)
  if self.closed then
    callback(done, err("closed"))
    return
  end
  vim.schedule(function()
    if self.closed then
      callback(done, err("closed"))
      return
    end
    owned[self].channel:request(message, "applied", function(e)
      if not e and message.type == "list_rows" then
        owned[self].revision = message.revision
      end
      callback(done, e)
    end)
  end)
end

function Handle:assets(entries, done)
  if self.closed then
    callback(done, err("closed"))
    return
  end
  if type(entries) ~= "table" or vim.islist(entries) and #entries > 0 then
    callback(done, err("protocol", "assets must be an object"))
    return
  end
  mutation(self, { type = "assets", entries = next(entries) and entries or vim.empty_dict() }, done)
end

function Handle:update(description, done)
  mutation(self, { type = "update", description = description }, done)
end

function Handle:rows(revision, rows, selected, done)
  mutation(self, {
    type = "list_rows",
    revision = revision,
    rows = rows or {},
    selected = selected == nil and vim.NIL or selected,
  }, done)
end

function Handle:state(revision, patch, done)
  if self.closed then
    callback(done, err("closed"))
    return
  end
  if type(patch) ~= "table" then
    callback(done, err("protocol", "state must be an object"))
    return
  end
  if patch.type ~= nil or patch.revision ~= nil then
    callback(done, err("protocol", "state patch cannot replace request fields"))
    return
  end
  local message = vim.tbl_extend("force", { type = "list_state", revision = revision }, patch or {})
  mutation(self, message, done)
end

local function focus(self, target, done)
  if self.closed then
    callback(done, err("closed"))
    return
  end
  exchange(
    owned[self].context,
    { type = "focus", pane = owned[self].context.pane, target = target },
    uv.now() + 2000,
    function(e, ch)
      if ch then
        ch:close()
      end
      callback(done, e)
    end
  )
end

function Handle:focus(done)
  focus(self, owned[self].surface, done)
end

function Handle:focus_editor(done)
  focus(self, owned[self].context.return_target, done)
end

function Handle:close()
  end_handle(self, "requested")
end

function M.open(opts, done)
  if
    type(opts) ~= "table"
    or (opts.side ~= "left" and opts.side ~= "right")
    or type(opts.width) ~= "number"
    or opts.width < 64
    or opts.width > 4096
    or opts.width ~= math.floor(opts.width)
    or type(opts.description) ~= "table"
  then
    callback(done, err("protocol", "invalid dock options"))
    return
  end
  local deadline = uv.now() + 2000
  local cancelled, cancel_wait, cancel_discovery, cancel_open = false
  local function finish(e, handle)
    if cancelled then
      return
    end
    pending[finish] = nil
    callback(done, e, handle)
  end
  pending[finish] = function()
    cancelled = true
    if cancel_wait then
      cancel_wait()
    end
    if cancel_discovery then
      cancel_discovery()
    end
    if cancel_open then
      cancel_open()
    end
    callback(done, err("closed"))
  end
  cancel_wait = Session.await_ui(deadline, function(e, context)
    if cancelled then
      return
    end
    if e then
      finish(e)
      return
    end
    cancel_discovery = capabilities(context, deadline, function(discovery_err)
      if cancelled then
        return
      end
      if discovery_err then
        finish(discovery_err)
        return
      end
      local handle = setmetatable({ on_event = opts.on_event, on_close = opts.on_close }, Handle)
      owned[handle] = { context = context }
      cancel_open = exchange(
        context,
        {
          type = "open",
          version = 1,
          pane = context.pane,
          position = "dock",
          side = opts.side,
          size = opts.width,
          focus = false,
          description = opts.description,
          owner_pid = context.pid,
          return_target = context.return_target,
          resizable = true,
        },
        deadline,
        function(open_err, ch)
          if cancelled then
            if ch then
              ch:close()
            end
            return
          end
          if open_err then
            finish(open_err)
            return
          end
          local surface = ch.first_reply.surface
          if
            type(surface) ~= "number"
            or surface < 1
            or surface > 9007199254740991
            or surface ~= math.floor(surface)
          then
            ch:close()
            finish(err("protocol", "invalid Surface id"))
            return
          end
          owned[handle].surface, owned[handle].channel = surface, ch
          handles[handle] = true
          finish(nil, handle)
        end,
        function(close_err)
          if not handle.closed and owned[handle].channel then
            end_handle(handle, "failure", close_err)
          end
        end,
        function(event)
          if handle.closed then
            return
          end
          if event.type == "list_scroll" and event.revision ~= owned[handle].revision then
            return
          end
          callback(handle.on_event, event)
        end
      )
    end)
  end)
end

function M.on_resume(fn)
  resumes[fn] = true
  return function()
    resumes[fn] = nil
  end
end

vim.api.nvim_create_autocmd("VimSuspend", {
  callback = function()
    for handle in pairs(handles) do
      if owned[handle].context.presentation == "terminal" then
        if handle.on_event then
          local ok, failure = pcall(handle.on_event, { type = "suspend" })
          if not ok then
            vim.notify("sprite callback: " .. tostring(failure), vim.log.levels.ERROR)
          end
        end
        end_handle(handle, "suspend")
      end
    end
  end,
})
vim.api.nvim_create_autocmd("VimResume", {
  callback = function()
    for fn in pairs(resumes) do
      callback(fn)
    end
  end,
})
vim.api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    if exiting then
      return
    end
    exiting = true
    local cancellations = {}
    for _, cancel in pairs(pending) do
      cancellations[#cancellations + 1] = cancel
    end
    for _, cancel in ipairs(cancellations) do
      cancel()
    end
    for cancel in pairs(active) do
      cancel()
    end
    for handle in pairs(handles) do
      end_handle(handle, "exit")
    end
  end,
})

return M
