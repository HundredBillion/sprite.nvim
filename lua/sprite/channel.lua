local uv = vim.uv
local unpack = table.unpack or unpack
local LIMIT = 16 * 1024 * 1024
local CALLBACK_BYTES = 64
-- The socket's send buffer. A Unix socket's default holds a few kilobytes,
-- so a megabyte of rows left Neovim in over a hundred pieces, each waiting
-- for a turn of the event loop that was busy with other work.
local SEND_BUFFER = 4 * 1024 * 1024
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

local function complete(item, ...)
  for _, callback in ipairs(item.callbacks) do
    teardown(callback, ...)
  end
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
    complete(self.pending, err)
  end
  for _, item in ipairs(self.queue) do
    complete(item, err)
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

-- The first byte outside ASCII at or after `from`, or nil. A megabyte of rows
-- is searched on every frame, and a Lua pattern takes 10 ms to do it; with
-- LuaJIT's FFI the bytes are read eight at a time, in a fraction of one.
local function find_high(text, from)
  return text:find("[\128-\255]", from)
end
local has_ffi, ffi = pcall(require, "ffi")
local has_bit, bit = pcall(require, "bit")
if has_ffi and has_bit then
  local bytes_t, words_t = ffi.typeof("const uint8_t *"), ffi.typeof("const uint64_t *")
  -- The top bit of each of eight bytes. Built by arithmetic: a 64-bit
  -- literal would stop this file loading where Lua is not LuaJIT.
  local high = ffi.new("uint64_t", 0x80808080) * 0x100000000 + 0x80808080
  find_high = function(text, from)
    local length = #text
    local bytes = ffi.cast(bytes_t, text)
    local i = (from or 1) - 1
    local words = ffi.cast(words_t, bytes + i)
    local count = bit.rshift(length - i, 3)
    local word = 0
    while word < count and bit.band(words[word], high) == 0 do
      word = word + 1
    end
    i = i + word * 8
    while i < length do
      if bytes[i] >= 0x80 then
        return i + 1
      end
      i = i + 1
    end
  end
end

-- True when `text` is well-formed UTF-8. The host ends a connection that
-- sends anything else, so a request holding such text, a file name in an old
-- encoding for one, is refused here and the Surface stays open. Only the
-- bytes outside ASCII are looked at.
local function valid_utf8(text)
  -- A byte that continues a character.
  local function tail(byte)
    return byte and byte >= 0x80 and byte <= 0xBF
  end
  local at = find_high(text)
  while at do
    local lead = text:byte(at)
    local a, b, c = text:byte(at + 1, at + 3)
    local length
    if lead >= 0xC2 and lead <= 0xDF then
      length = tail(a) and 2
    elseif lead == 0xE0 then
      length = a and a >= 0xA0 and a <= 0xBF and tail(b) and 3
    elseif lead == 0xED then
      -- U+D800 to U+DFFF are halves of a UTF-16 pair, not characters.
      length = a and a >= 0x80 and a <= 0x9F and tail(b) and 3
    elseif lead >= 0xE1 and lead <= 0xEF then
      length = tail(a) and tail(b) and 3
    elseif lead == 0xF0 then
      length = a and a >= 0x90 and a <= 0xBF and tail(b) and tail(c) and 4
    elseif lead >= 0xF1 and lead <= 0xF3 then
      length = tail(a) and tail(b) and tail(c) and 4
    elseif lead == 0xF4 then
      length = a and a >= 0x80 and a <= 0x8F and tail(b) and tail(c) and 4
    end
    if not length then
      return false
    end
    at = find_high(text, at + length)
  end
  return true
end
Channel.valid_utf8 = valid_utf8

-- vim.json.encode is several times faster than vim.fn.json_encode, which
-- copies the message into Vim values first: a megabyte of rows took 8 ms
-- against 2. It also writes a string holding a NUL byte as a string.
-- `body`, when given, is the message already written as JSON.
local function encoded(self, message, authenticated, body)
  local ok, json = true, body
  if not body then
    ok, json = pcall(vim.json.encode, message)
  end
  if not ok or not valid_utf8(json) then
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
  self.queued_bytes = self.queued_bytes - #item.line - #item.callbacks * CALLBACK_BYTES
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
      list_patch = "list_patch",
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
    complete(item, error_value("refused", message.reason or message.message))
    pump(self)
  elseif self.pending and matches(message, self.pending) then
    local item = self.pending
    self.pending = nil
    stop_timer(self)
    complete(item, nil, message)
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
      -- The system may allow less than is asked for, or refuse; either is fine.
      pcall(self.pipe.send_buffer_size, self.pipe, SEND_BUFFER)
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

-- `body`, when given, is `message` already written as JSON: the caller has
-- encoded its parts and the channel sends them as they are. `message` still
-- says what answer to expect.
function Channel:request(message, expected_type, callback, body)
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
        local callback_bytes = callback and CALLBACK_BYTES or 0
        if not merged or self.queued_bytes - #item.line + #merged + callback_bytes > LIMIT then
          teardown(callback, merge_err or error_value("queue_full", "request queue full"))
          return
        end
        self.queued_bytes = self.queued_bytes - #item.line + #merged + callback_bytes
        item.line, item.message = merged, patch
        if callback then
          item.callbacks[#item.callbacks + 1] = callback
        end
        return
      end
    end
  end
  local line, err = encoded(self, message, false, body)
  if not line then
    teardown(callback, err)
    return
  end
  local callback_bytes = callback and CALLBACK_BYTES or 0
  if self.queued_bytes + #line + callback_bytes > LIMIT then
    teardown(callback, error_value("queue_full", "request queue full"))
    return
  end
  self.queue[#self.queue + 1] = {
    message = message,
    expected = expected_type,
    callbacks = callback and { callback } or {},
    line = line,
  }
  self.queued_bytes = self.queued_bytes + #line + callback_bytes
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
