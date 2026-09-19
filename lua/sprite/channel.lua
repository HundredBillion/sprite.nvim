local uv = vim.uv
local unpack = table.unpack or unpack
local LIMIT = 16 * 1024 * 1024
local Channel = {}

local function error_value(code, message)
  return { code = code, message = message or code }
end

local function safe_call(callback, ...)
  if not callback then
    return
  end
  local ok, err = pcall(callback, ...)
  if not ok then
    vim.notify("sprite channel callback: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function deliver(self, callback, ...)
  local args = { n = select("#", ...), ... }
  local generation = self.generation
  vim.schedule(function()
    if self.generation == generation and not self.closed then
      safe_call(callback, unpack(args, 1, args.n))
    end
  end)
end

local function teardown(callback, ...)
  local args = { n = select("#", ...), ... }
  vim.schedule(function()
    safe_call(callback, unpack(args, 1, args.n))
  end)
end

function Channel.decoder(on_value, max_bytes)
  local buffer = ""
  local cap = max_bytes or LIMIT
  local decoder = {}
  local function decode(line)
    if #line > cap then
      return nil, error_value("protocol", "message too large")
    end
    local ok, value = pcall(vim.json.decode, line)
    if not ok or type(value) ~= "table" then
      return nil, error_value("protocol", "invalid JSON message")
    end
    on_value(value)
    return true
  end
  function decoder:feed(bytes)
    buffer = buffer .. bytes
    while true do
      local newline = buffer:find("\n", 1, true)
      if not newline then
        break
      end
      local line = buffer:sub(1, newline - 1)
      buffer = buffer:sub(newline + 1)
      local ok, err = decode(line)
      if not ok then
        return nil, err
      end
    end
    if #buffer > cap then
      return nil, error_value("protocol", "message too large")
    end
    return true
  end
  function decoder:finish()
    if #buffer == 0 then
      return true
    end
    local line = buffer
    buffer = ""
    return decode(line)
  end
  return decoder
end

local function stop_timer(self)
  if self.timer and not self.timer:is_closing() then
    self.timer:stop()
    self.timer:close()
  end
  self.timer = nil
end

local function close(self, reason)
  if self.closed then
    return
  end
  self.closed = true
  self.generation = self.generation + 1
  stop_timer(self)
  if self.pipe and not self.pipe:is_closing() then
    self.pipe:read_stop()
    self.pipe:close()
  end
  local err = type(reason) == "table" and reason
    or error_value("closed", tostring(reason or "closed"))
  if not self.ready then
    self.ready = true
    teardown(self.callback, err)
  end
  if self.pending then
    teardown(self.pending.callback, err)
  end
  for _, item in ipairs(self.queue) do
    teardown(item.callback, err)
  end
  self.pending = nil
  self.queue = {}
  self.queued_bytes = 0
  teardown(self.on_close, err)
end

local function deadline(self, milliseconds, code)
  stop_timer(self)
  self.timer = uv.new_timer()
  self.timer:start(milliseconds, 0, function()
    close(self, error_value(code, code))
  end)
end

local function encoded(self, message, authenticated)
  local ok, json = pcall(vim.fn.json_encode, message)
  if not ok then
    return nil, error_value("protocol", "cannot encode message")
  end
  local line = (authenticated and self.key .. " " or "") .. json .. "\n"
  if #line > LIMIT then
    return nil, error_value("queue_full", "message too large")
  end
  return line
end

local function pump(self)
  if self.closed or not self.ready or self.pending or #self.queue == 0 then
    return
  end
  local item = table.remove(self.queue, 1)
  self.queued_bytes = self.queued_bytes - #item.line
  self.pending = item
  deadline(self, self.timeout_ms, "timeout")
  self.pipe:write(item.line, function(err)
    if err then
      close(self, error_value("unavailable", tostring(err)))
    end
  end)
end

local function matches(message, item)
  if message.type ~= item.expected then
    return false
  end
  if message.type == "applied" then
    local operation = ({
      assets = "assets",
      list_rows = "list_rows",
      list_state = "list_state",
      update = "update",
    })[item.message.type]
    if operation and message.operation ~= operation then
      return false
    end
    for _, field in ipairs({ "operation", "revision" }) do
      if item.message[field] ~= nil and message[field] ~= item.message[field] then
        return false
      end
    end
  end
  return true
end

local function receive(self, message)
  if self.closed then
    return
  end
  if type(message.type) ~= "string" then
    close(self, error_value("protocol", "message missing type"))
    return
  end
  if not self.ready then
    if message.type == "refused" then
      close(self, error_value("refused", message.reason or message.message))
    elseif message.type ~= self.expected_first then
      close(self, error_value("protocol", "unexpected first reply"))
    else
      self.ready = true
      self.first_reply = message
      stop_timer(self)
      -- A one-shot host may close before the scheduler runs this accepted verdict.
      teardown(self.callback, nil, self)
      pump(self)
    end
    return
  end
  if message.type == "refused" and self.pending then
    local item = self.pending
    self.pending = nil
    stop_timer(self)
    teardown(item.callback, error_value("refused", message.reason or message.message))
    pump(self)
  elseif self.pending and matches(message, self.pending) then
    local item = self.pending
    self.pending = nil
    stop_timer(self)
    teardown(item.callback, nil, message)
    pump(self)
  elseif
    message.type == "applied"
    or message.type == "focused"
    or message.type == self.expected_first
  then
    close(self, error_value("protocol", "unexpected reply"))
  else
    deliver(self, self.on_event, message)
  end
end

function Channel.connect(opts, callback)
  local self = setmetatable({
    pipe = uv.new_pipe(false),
    key = opts.key,
    callback = callback,
    on_event = opts.on_event,
    on_close = opts.on_close,
    expected_first = opts.expected_first
      or ({ capabilities = "capabilities", focus = "focused", token = "registered" })[opts.first.type]
      or "opened",
    timeout_ms = opts.timeout_ms or 2000,
    queue = {},
    queued_bytes = 0,
    generation = 0,
    closed = false,
    ready = false,
  }, { __index = Channel })
  self.decoder = Channel.decoder(function(value)
    receive(self, value)
  end)
  deadline(self, self.timeout_ms, "timeout")
  self.pipe:connect(opts.path, function(err)
    if self.closed then
      return
    end
    if err then
      close(self, error_value("unavailable", tostring(err)))
      return
    end
    vim.schedule(function()
      if self.closed then
        return
      end
      self.pipe:read_start(function(read_err, bytes)
        if self.closed then
          return
        end
        if read_err then
          close(self, error_value("unavailable", tostring(read_err)))
          return
        end
        if not bytes then
          local ok, decode_err = self.decoder:finish()
          if not ok then
            close(self, decode_err)
          else
            close(self, error_value("unavailable", "connection closed"))
          end
          return
        end
        local ok, decode_err = self.decoder:feed(bytes)
        if not ok then
          close(self, decode_err)
        end
      end)
      local line, encode_err = encoded(self, opts.first, true)
      if not line then
        close(self, encode_err)
        return
      end
      self.pipe:write(line, function(write_err)
        if write_err then
          close(self, error_value("unavailable", tostring(write_err)))
        end
      end)
    end)
  end)
  return function()
    close(self, error_value("closed", "cancelled"))
  end
end

function Channel:request(message, expected_type, callback)
  if self.closed then
    teardown(callback, error_value("closed", "closed"))
    return
  end
  if message.type == "list_state" then
    for _, item in ipairs({ self.queue[#self.queue] }) do
      if item.message.type == "list_state" and item.message.revision == message.revision then
        local patch = vim.tbl_extend("force", item.message, message)
        if patch.reveal ~= nil and patch.scroll ~= nil then
          patch.reveal = message.reveal
          patch.scroll = message.scroll
        end
        local merged, merge_err = encoded(self, patch)
        if not merged or self.queued_bytes - #item.line + #merged > LIMIT then
          teardown(callback, merge_err or error_value("queue_full", "request queue full"))
          return
        end
        self.queued_bytes = self.queued_bytes - #item.line + #merged
        item.line, item.message = merged, patch
        local previous = item.callback
        item.callback = function(err, reply)
          safe_call(previous, err, reply)
          safe_call(callback, err, reply)
        end
        return
      end
    end
  end
  local line, err = encoded(self, message)
  if not line then
    teardown(callback, err)
    return
  end
  if self.queued_bytes + #line > LIMIT then
    teardown(callback, error_value("queue_full", "request queue full"))
    return
  end
  self.queue[#self.queue + 1] =
    { message = message, expected = expected_type, callback = callback, line = line }
  self.queued_bytes = self.queued_bytes + #line
  pump(self)
end

function Channel:send(message)
  if self.closed then
    return nil, error_value("closed", "closed")
  end
  local line, err = encoded(self, message)
  if not line then
    return nil, err
  end
  self.pipe:write(line, function(write_err)
    if write_err then
      close(self, error_value("unavailable", tostring(write_err)))
    end
  end)
  return true
end

function Channel:close(reason)
  close(self, reason)
end

return Channel
