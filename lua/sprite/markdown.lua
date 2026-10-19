local M = {}
local provider, channel, state
local enabled, pending, hide = false, false, false
local revision, attachment = 0, 0

function M.changed()
  if not channel or pending then
    return
  end
  pending = true
  local epoch = attachment
  vim.schedule(function()
    if epoch ~= attachment then
      return
    end
    pending = false
    pcall(vim.rpcnotify, channel, "sprite_markdown_changed")
  end)
end

local function failure(reason)
  enabled, state, hide = false, nil, true
  if provider and provider.attached then
    pcall(provider.attached, false)
  end
  if provider and provider.stop then
    pcall(provider.stop)
  end
  provider = nil
  vim.schedule(function()
    vim.notify("Markdown preview: " .. tostring(reason), vim.log.levels.WARN)
  end)
  M.changed()
end

function M.available()
  return enabled
end

function M.setup(options)
  if provider and provider.stop then
    pcall(provider.stop)
  end
  hide = hide or state ~= nil
  state, provider = nil, options
  enabled = channel ~= nil
  if provider and provider.attached and channel then
    local ok, err = pcall(provider.attached, enabled)
    if not ok then
      failure(err)
    end
  end
  M.changed()
end

function M.attach(id)
  if id == vim.NIL then
    id = nil
  end
  local was_attached = channel ~= nil
  attachment = attachment + 1
  pending, channel, enabled = false, id, id ~= nil
  state = nil
  if was_attached then
    hide = true
  end
  if provider and provider.attached then
    local ok, err = pcall(provider.attached, enabled)
    if not ok then
      failure(err)
    end
  end
  if not enabled and provider and provider.stop then
    pcall(provider.stop)
  end
  M.changed()
end

function M.pull()
  local op
  if hide then
    hide = false
    op = { kind = "hide" }
  elseif channel and enabled and provider then
    local ok, result = pcall(provider.next)
    if not ok then
      failure(result)
      return M.pull()
    end
    if result == nil or result == vim.NIL then
      return vim.NIL
    end
    if
      type(result) ~= "table" or not ({ document = true, state = true, hide = true })[result.kind]
    then
      failure("invalid provider operation")
      return M.pull()
    end
    op = vim.deepcopy(result)
  else
    return vim.NIL
  end
  revision = revision + 1
  op.type, op.revision = "markdown", revision
  if op.kind == "state" then
    state = vim.deepcopy(op)
  elseif op.kind == "hide" then
    state = nil
  end
  return op
end

function M.dispatch(event)
  if
    not enabled
    or not provider
    or not state
    or type(event) ~= "table"
    or event.type ~= "markdown_action"
    or event.revision ~= state.revision
    or (event.action ~= "toggle" and event.action ~= "open" and event.action ~= "focus")
  then
    return false
  end
  local allowed =
    { type = true, revision = true, window = true, buffer = true, generation = true, action = true }
  if event.action == "open" then
    if type(event.destination) ~= "string" or #event.destination > 4096 then
      return false
    end
    allowed.destination = true
  end
  for key in pairs(event) do
    if not allowed[key] then
      return false
    end
  end
  for _, target in ipairs(state.windows or {}) do
    if
      target.window == event.window
      and target.buffer == event.buffer
      and target.generation == event.generation
    then
      if event.action == "toggle" and state.active ~= event.window then
        return false
      end
      local ok, result = pcall(provider.dispatch, event)
      if not ok then
        failure(result)
        return false
      end
      M.changed()
      return result == true
    end
  end
  return false
end

function M.before_input(event)
  if not enabled or not provider or not provider.before_input then
    return true
  end
  local ok, result = pcall(provider.before_input, event)
  if not ok then
    failure(result)
    return true
  end
  return result ~= false
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("SpriteNativeMarkdown", { clear = true }),
  callback = function()
    M.attach(nil)
  end,
})

return M
