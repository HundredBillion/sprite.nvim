local M = {}
local provider, channel
local revision = 0
local committed, staging
local hide, pending = false, false
local attachment = 0

function M.changed()
  if channel and not pending then
    pending = true
    local current = attachment
    vim.schedule(function()
      if current ~= attachment then
        return
      end
      pending = false
      pcall(vim.rpcnotify, channel, "sprite_minimap_changed")
    end)
  end
end

local function log(reason)
  if channel then
    pcall(vim.rpcnotify, channel, "sprite_minimap_error", tostring(reason))
    return
  end
  vim.schedule(function()
    vim.notify("Sprite minimap: " .. tostring(reason), vim.log.levels.WARN)
  end)
end

local function stop()
  if provider and provider.stop then
    local ok, err = pcall(provider.stop)
    if not ok then
      log(err)
    end
  end
  hide = hide or committed ~= nil or staging ~= nil
  committed, staging = nil, nil
end

local function failed(err)
  stop()
  provider = nil
  hide = true
  log(err)
  M.changed()
end

function M.setup(options)
  stop()
  provider = options
  M.changed()
end

function M.attach(id)
  if id == vim.NIL then
    id = nil
  end
  if channel then
    stop()
  end
  attachment = attachment + 1
  pending = false
  channel = id
  local group = vim.api.nvim_create_augroup("SpriteNativeMinimap", { clear = true })
  if channel then
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = group,
      callback = function()
        stop()
        channel = nil
        attachment = attachment + 1
        pending = false
      end,
    })
  end
  M.changed()
end

function M.pull()
  local op
  if hide then
    hide = false
    op = { type = "minimap", kind = "hide" }
  elseif provider then
    local ok, result = pcall(provider.next)
    if not ok then
      failed(result)
      return M.pull()
    end
    if result == nil or result == vim.NIL then
      return vim.NIL
    end
    op = vim.deepcopy(result)
  else
    return vim.NIL
  end
  revision = revision + 1
  op.type, op.revision = "minimap", revision
  if op.kind == "begin" then
    staging = { target = op.target, generation = op.generation, total = op.total }
  elseif op.kind == "commit" and staging then
    committed = staging
    staging = nil
    committed.revision = revision
  elseif op.kind == "hide" then
    committed, staging = nil, nil
  end
  return op
end

local function integer(value)
  return type(value) == "number"
    and value >= 1
    and value <= 9007199254740991
    and value == math.floor(value)
end

function M.dispatch(event)
  if
    not provider
    or not committed
    or staging
    or type(event) ~= "table"
    or event.type ~= "minimap_action"
    or event.target ~= committed.target
    or event.generation ~= committed.generation
    or not integer(event.revision)
    or event.revision < committed.revision
    or event.revision > revision
  then
    return false
  end
  local coordinate = ({ reveal = "line", scroll = "topline" })[event.action]
  if not coordinate or not integer(event[coordinate]) or event[coordinate] > committed.total then
    return false
  end
  local fields = {
    type = true,
    target = true,
    generation = true,
    revision = true,
    action = true,
    [coordinate] = true,
  }
  for key in pairs(event) do
    if not fields[key] then
      return false
    end
  end
  if provider.target then
    local ok, target = pcall(provider.target)
    if not ok then
      failed(target)
      return false
    end
    if
      not target
      or target.busy
      or target.target ~= event.target
      or target.generation ~= event.generation
    then
      return false
    end
  end
  local ok, result = pcall(provider.dispatch, event)
  if not ok then
    failed(result)
    return false
  end
  return result ~= false
end

local allowed = {
  nvim_input = true,
  nvim_input_mouse = true,
  nvim_paste = true,
}
function M.input(method, args, event)
  if not allowed[method] then
    return false
  end
  if provider and provider.before_input then
    local ok, err = pcall(provider.before_input, event)
    if not ok then
      failed(err)
    end
  end
  -- Restore the selection before queuing its native command, in the same RPC execution.
  return vim.api[method](unpack(args))
end

return M
