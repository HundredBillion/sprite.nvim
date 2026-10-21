local M = {}

local function color(value)
  return value and string.format("#%06x", value) or nil
end

function M.snapshot(columns)
  if vim.o.laststatus ~= 3 or vim.o.statusline == "" then
    return { type = "footer", visible = false }
  end
  columns = math.max(1, math.min(1024, columns))
  local evaluated = vim.api.nvim_eval_statusline(vim.o.statusline, {
    winid = vim.api.nvim_get_current_win(),
    maxwidth = columns,
    fillchar = vim.opt.fillchars:get().stl or " ",
    highlights = true,
  })
  local source = vim.api.nvim_eval_statusline(vim.o.statusline, {
    winid = vim.api.nvim_get_current_win(),
    maxwidth = vim.o.columns,
    fillchar = vim.opt.fillchars:get().stl or " ",
  })
  local source_text = source.str
    .. (vim.opt.fillchars:get().stl or " "):rep(vim.o.columns - source.width)
  local cells, define, groups = {}, {}, {}
  local highlights = evaluated.highlights
  for index, highlight in ipairs(highlights) do
    local attrs = {}
    for _, name in ipairs(highlight.groups or { highlight.group }) do
      attrs = vim.tbl_extend("force", attrs, vim.api.nvim_get_hl(0, { name = name, link = false }))
    end
    define[tostring(index)] = {
      fg = color(attrs.fg),
      bg = color(attrs.bg),
      sp = color(attrs.sp),
      bold = attrs.bold,
      italic = attrs.italic,
      reverse = attrs.reverse,
      strikethrough = attrs.strikethrough,
      underline = attrs.undercurl and "curly"
        or attrs.underdouble and "double"
        or attrs.underdotted and "dotted"
        or attrs.underdashed and "dashed"
        or attrs.underline and "single"
        or nil,
    }
    if next(define[tostring(index)]) == nil then
      define[tostring(index)] = vim.empty_dict()
    end
    groups[highlight.group or highlight.groups[#highlight.groups]] = index
    local stop = highlights[index + 1] and highlights[index + 1].start or #evaluated.str
    local text = evaluated.str:sub(highlight.start + 1, stop)
    for _, character in ipairs(vim.fn.split(text, "\\zs")) do
      local width = vim.fn.strdisplaywidth(character)
      if width == 0 and #cells > 0 then
        cells[#cells][1] = cells[#cells][1] .. character
      else
        cells[#cells + 1] = { character, index }
        if width == 2 then
          cells[#cells + 1] = { "", index }
        end
      end
    end
  end
  local base = vim.api.nvim_get_hl(0, { name = "StatusLine", link = false })
  local snapshot = {
    type = "footer",
    source = source_text,
    row = vim.o.lines - vim.o.cmdheight - 1,
    cols = columns,
    grid_cols = vim.o.columns,
    grid_rows = vim.o.lines,
    cells = cells,
    define = define,
    groups = groups,
    fg = color(base.fg),
    bg = color(base.bg),
    sp = color(base.sp),
  }
  if vim.g.sprite_follow_native then
    local follow = package.loaded.follow
    if follow and type(follow.native_snapshot) == "function" then
      snapshot.follow = follow.native_snapshot()
    end
  end
  return snapshot
end

return M
