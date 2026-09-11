-- A minimal msgpack-RPC client over a byte pipe. It owns no I/O: it is handed a
-- `write` function and fed incoming bytes with `feed`. Framing per the spec:
-- request {0,id,method,args}, response {1,id,err,result}, notification
-- {2,method,args}.
local Rpc = {}
Rpc.__index = Rpc

function Rpc.new(write)
  return setmetatable({
    write = write,
    next_id = 1,
    pending = {},
    on_note = nil,
    unpacker = vim.mpack.Unpacker(),
    buf = "",
  }, Rpc)
end

function Rpc:request(method, args, on_response)
  local id = self.next_id
  self.next_id = id + 1
  self.pending[id] = on_response or function() end
  self.write(vim.mpack.encode({ 0, id, method, args }))
end

function Rpc:notify(method, args)
  self.write(vim.mpack.encode({ 2, method, args }))
end

function Rpc:on_notification(fn)
  self.on_note = fn
end

-- Append bytes and dispatch every complete message. The Unpacker returns nil
-- when the buffer does not yet hold a whole object; it must not be called past
-- the buffer's end, so the loop guards `pos <= #buf`. Even on a nil (partial)
-- result, `newpos` must still be adopted before the buffer is truncated: the
-- Unpacker keeps its own internal buffer of whatever it has already seen, so
-- the tail kept here must be only the bytes it has NOT yet consumed.
function Rpc:feed(bytes)
  self.buf = self.buf .. bytes
  local pos = 1
  while pos <= #self.buf do
    local obj, newpos = self.unpacker(self.buf, pos)
    pos = newpos
    if obj == nil then
      break
    end
    if obj[1] == 1 then
      local cb = self.pending[obj[2]]
      if cb then
        self.pending[obj[2]] = nil
        cb(obj[3], obj[4])
      end
    elseif obj[1] == 2 and self.on_note then
      self.on_note(obj[2], obj[3])
    end
  end
  self.buf = self.buf:sub(pos)
end

return Rpc
