local M = {}
local provider = {}
local channel, revision, previous = nil, 0, nil
local targets = {}
local last_buffer
local dirty, pending = true, false
local modified = {}

local function changed()
  dirty = true
  if channel and not pending then
    pending = true
    vim.schedule(function()
      pending = false
      vim.rpcnotify(channel, "sprite_tabs_changed")
    end)
  end
end

local function modified_changed(buffer)
  if vim.api.nvim_buf_is_valid(buffer) then
    local value = vim.bo[buffer].modified
    if modified[buffer] ~= value then
      modified[buffer] = value
      changed()
    end
  end
end

function M.setup(options)
  provider = options or {}
  changed()
end

local function default_snapshot()
  local items = {}
  local current = vim.api.nvim_get_current_buf()
  if vim.bo[current].buftype == "" then
    last_buffer = current
  end
  for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    if vim.bo[info.bufnr].buftype == "" then
      items[#items + 1] = {
        buffer = info.bufnr,
        label = info.name == "" and "Untitled" or vim.fn.fnamemodify(info.name, ":t"),
        modified = vim.bo[info.bufnr].modified,
      }
    end
  end
  return { items = items, active = last_buffer, height = 35 }
end

local function bounded_label(value)
  local label = tostring(value or "Untitled"):gsub("[%z\r\n\t]", " ")
  while #label > 1024 do
    label = vim.fn.strcharpart(label, 0, vim.fn.strchars(label) - 1)
  end
  return label ~= "" and label or "Untitled"
end

function M.snapshot()
  if channel then
    local current = vim.api.nvim_get_current_buf()
    modified_changed(current)
    for _, buffer in pairs(targets) do
      if buffer ~= current then
        modified_changed(buffer)
      end
    end
    if not dirty then
      return vim.NIL
    end
  end
  dirty = false
  local state = (provider.snapshot or default_snapshot)()
  local items, mapping = {}, {}
  local icon_bytes = 0
  local active
  local first = 1
  for i, item in ipairs(state.items) do
    if item.buffer == state.active then
      first = math.max(1, i - 255)
      break
    end
  end
  for i = first, math.min(#state.items, first + 255) do
    local item = state.items[i]
    local b = item.buffer
    if type(b) == "number" and vim.api.nvim_buf_is_valid(b) then
      local id = "b" .. b
      if not mapping[id] then
        local tab = { id = id, label = bounded_label(item.label), modified = item.modified == true }
        if
          type(item.icon) == "string"
          and #item.icon <= 65536
          and icon_bytes + #item.icon <= 1024 * 1024
        then
          icon_bytes = icon_bytes + #item.icon
          tab.icon = item.icon
        end
        items[#items + 1] = tab
        mapping[id] = b
        modified[b] = vim.bo[b].modified
        if b == state.active then
          active = id
        end
      end
    end
  end
  local result = {
    type = "tabs",
    height = math.max(24, math.min(64, state.height or 35)),
    items = items,
    active = active or vim.NIL,
    colors = state.colors,
  }
  if vim.deep_equal(previous, result) then
    return vim.NIL
  end
  previous = vim.deepcopy(result)
  revision = revision + 1
  targets = mapping
  result.revision = revision
  return result
end

function M.dispatch(event)
  if type(event) ~= "table" or event.revision ~= revision then
    return false
  end
  local b = targets[event.id]
  if not b or not vim.api.nvim_buf_is_valid(b) then
    return false
  end
  if event.action == "select" then
    if provider.select then
      provider.select(b)
    else
      vim.api.nvim_set_current_buf(b)
    end
  elseif event.action == "close" then
    if provider.close then
      provider.close(b)
    elseif not vim.bo[b].modified then
      vim.api.nvim_buf_delete(b, {})
    else
      vim.ui.select(
        { "Discard changes", "Cancel" },
        { prompt = "Close modified file?" },
        function(choice)
          if choice == "Discard changes" and vim.api.nvim_buf_is_valid(b) then
            vim.api.nvim_buf_delete(b, { force = true })
          end
        end
      )
    end
  else
    return false
  end
  changed()
  return true
end

function M.attach(id)
  channel = id
  local group = vim.api.nvim_create_augroup("SpriteNativeTabs", { clear = true })
  vim.api.nvim_create_autocmd({
    "BufAdd",
    "BufDelete",
    "BufEnter",
    "BufFilePost",
    "FileType",
    "BufWritePost",
    "ColorScheme",
    "TabEnter",
    "TabClosed",
  }, {
    group = group,
    callback = function(event)
      if event.event == "BufDelete" then
        modified[event.buf] = nil
      end
      changed()
    end,
  })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = group,
    callback = function(event)
      modified_changed(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = "modified",
    callback = function(event)
      modified_changed(event.buf)
    end,
  })
  vim.api.nvim_create_autocmd("OptionSet", {
    group = group,
    pattern = { "buflisted", "buftype" },
    callback = changed,
  })
  changed()
end

return M
