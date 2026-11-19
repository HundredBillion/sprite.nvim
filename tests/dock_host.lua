-- Exercise consumers through real sockets and session discovery, without a graphical host.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local Fake = dofile(root .. "/tests/fake_sprite.lua")
local fixture = vim.json.decode(
  table.concat(vim.fn.readfile(root .. "/tests/fixtures/surface-list-v1.json"), "\n")
)
local uv = vim.uv
local M = {}

function M.start()
  local path = vim.fn.tempname()
  local host = { pane = "f00d:0", requests = {}, clients = {}, errors = {}, refuse = false }
  local previous = { marker = vim.g.sprite_session }
  local environment =
    { SPRITE_PANE = host.pane, SPRITE_SURFACE_SOCKET = path, SPRITE_SURFACE_KEY = "dock-test" }
  for name, value in pairs(environment) do
    previous[name] = vim.env[name]
    vim.env[name] = value
  end
  vim.g.sprite_session = { pid = uv.os_getpid(), surface = 77 }
  local listener = uv.new_pipe(false)
  assert(listener:bind(path))
  local surface = 100
  assert(listener:listen(32, function()
    local client = uv.new_pipe(false)
    listener:accept(client)
    host.clients[#host.clients + 1] = client
    local buffer, first, state = "", true, {}
    client:read_start(function(err, bytes)
      if err or not bytes then
        return
      end
      buffer = buffer .. bytes
      while true do
        local newline = buffer:find("\n", 1, true)
        if not newline then
          break
        end
        local line = buffer:sub(1, newline - 1)
        buffer = buffer:sub(newline + 1)
        if first then
          local key
          key, line = line:match("^([^ ]+) (.+)$")
          if key ~= environment.SPRITE_SURFACE_KEY then
            host.errors[#host.errors + 1] = "first request must authenticate"
            return
          end
          first = false
        end
        local decoded, message = pcall(vim.json.decode, line)
        if not decoded then
          host.errors[#host.errors + 1] = "invalid JSON: " .. tostring(message)
          return
        end
        local valid, reason, response
        if host.refuse_once == message.type then
          -- Refuse one request without applying it, as a host that had lost its rows would.
          host.refuse_once = nil
          host.refused = (host.refused or 0) + 1
          response = { type = "refused", reason = "test refuses " .. message.type }
          valid = false
        else
          valid, reason = Fake.validate(message, state)
        end
        host.rows = state.rows
        if response then
          -- Already answered above.
        elseif not valid then
          host.errors[#host.errors + 1] = reason
          response = { type = "refused", reason = reason }
        elseif
          (message.type == "capabilities" or message.type == "open" or message.type == "focus")
          and message.pane ~= host.pane
        then
          response = { type = "refused", reason = "pane belongs to another window" }
        elseif message.type == "capabilities" then
          response = host.refuse and { type = "refused", reason = "test refusal" }
            or fixture.capabilities.reply
          -- A test may say what this host cannot do.
          if response.type == "capabilities" and host.lacks then
            response = vim.deepcopy(response)
            response.features = vim.tbl_filter(function(feature)
              return not vim.tbl_contains(host.lacks, feature)
            end, response.features)
          end
        elseif message.type == "token" then
          response = { type = "registered" }
        elseif message.type == "open" then
          surface = surface + 1
          response = { type = "opened", surface = surface }
        elseif message.type == "focus" then
          response = { type = "focused" }
        elseif message.type ~= "close" then
          response = { type = "applied", operation = message.type, revision = message.revision }
        end
        if valid and (not response or response.type ~= "refused") then
          host.requests[#host.requests + 1] = message
        end
        if response then
          client:write(vim.json.encode(response) .. "\n")
        end
      end
    end)
  end))
  function host:messages(kind)
    assert(#self.errors == 0, table.concat(self.errors, "\n"))
    return vim.tbl_filter(function(message)
      return message.type == kind
    end, self.requests)
  end
  function host:close()
    for _, client in ipairs(self.clients) do
      if not client:is_closing() then
        client:close()
      end
    end
    listener:close()
    os.remove(path)
    for name in pairs(environment) do
      vim.env[name] = previous[name]
    end
    vim.g.sprite_session = previous.marker
    assert(#self.errors == 0, table.concat(self.errors, "\n"))
  end
  return host
end

return M
