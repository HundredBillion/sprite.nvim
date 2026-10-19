local Bridge = require("sprite.input_bridge")
local Rpc = require("sprite.rpc")
local function session()
  local messages = {}
  local rpc = Rpc.new(function(bytes)
    messages[#messages + 1] = vim.mpack.decode(bytes)
  end)
  local bridge = Bridge.new(rpc)
  local function reply(index, value, err)
    local message = assert(messages[index])
    rpc:feed(vim.mpack.encode({ 1, message[2], err or vim.NIL, value or vim.NIL }))
  end
  local function keys()
    local result = {}
    for _, message in ipairs(messages) do
      if message[1] == 2 then
        result[#result + 1] = { method = message[2], args = message[3] }
      end
    end
    return result
  end
  local function input(text)
    bridge.input({ method = "nvim_input", args = { text } }, { type = "input", key = text })
  end
  return bridge, input, reply, keys, messages
end
for _, order in ipairs({ "hook-first", "mode-first", "not-blocked", "hook-error" }) do
  local _, input, reply, keys = session()
  input("x")
  if order == "mode-first" then
    reply(2, { blocking = true })
    reply(1)
  elseif order == "not-blocked" then
    reply(2, { blocking = false })
    T.eq(keys(), {}, "nonblocking sample cannot bypass selection restoration")
    reply(1)
  else
    reply(1, nil, order == "hook-error" and { "failure" } or nil)
    reply(2, { blocking = true })
  end
  T.eq(
    keys(),
    { { method = "nvim_input", args = { "x" } } },
    order .. " delivers original key exactly once"
  )
end
local bridge, input, reply, keys, messages = session()
input("r")
reply(1)
input("x")
reply(2, { blocking = true })
T.eq(
  keys(),
  { { method = "nvim_input", args = { "r" } } },
  "late mode reply cannot release a newer input"
)
reply(5, { blocking = true })
bridge.action("nvim_exec_lua", { "browse", {} })
T.eq(#messages, 6, "new browse waits for outstanding restoration hook")
reply(4)
T.eq(messages[7][3], "nvim_exec_lua", "browse starts after old hook retires")
input("c")
reply(8, { blocking = false })
T.eq(#keys(), 2, "normal key waits behind unfinished browse")
reply(7)
reply(9)
T.eq(keys(), {
  { method = "nvim_input", args = { "r" } },
  { method = "nvim_input", args = { "x" } },
  { method = "nvim_input", args = { "c" } },
}, "normal key follows browse and its restoration")
reply(10, { blocking = true })
T.eq(#keys(), 3, "late mode sample cannot duplicate restored key")

local closed, send, respond, delivered = session()
send("x")
closed.close()
respond(2, { blocking = true })
respond(1)
send("y")
T.eq(delivered(), {}, "teardown invalidates pending and future input")

local _, error_input, error_reply, error_keys = session()
error_input("e")
local safe = pcall(error_reply, 2, vim.NIL, { "mode unavailable" })
T.ok(safe, "mode RPC error cannot crash input bridge")
error_reply(1)
T.eq(
  error_keys(),
  { { method = "nvim_input", args = { "e" } } },
  "hook acknowledgment still releases key after mode error"
)
