-- How a list's rows reach the host: all of them, or only the rows that
-- changed since the last list sent.
--
-- A long list is about a megabyte, and a program that restyles one row of it
-- still hands over every row. Each row is encoded on its own, so two lists
-- can be compared row by row, and a host that takes `list_patch` is sent the
-- rows that differ.
local M = {}

-- The host feature that takes `list_patch`.
M.FEATURE = "virtual-list-patch-v1"

-- A patch this large beside the whole list is not worth sending: the whole
-- list is simpler for the host and nearly as small.
local WORTHWHILE = 0.5
-- Lists longer than this are not compared line by line in their changed part.
local MAX_COMPARED = 50000

local diff = vim.text.diff

-- A place to remember each row table's JSON text, for a caller that passes
-- the same table again for a row that has not changed. A row the caller no
-- longer holds is forgotten with it.
function M.memory()
  return setmetatable({}, { __mode = "k" })
end

-- Each row as its JSON text, with their length in all as `bytes`, or nil
-- when a row cannot be encoded. With `memory`, a row table seen before is
-- not encoded again: encoding is most of what an unchanged list costs.
function M.lines(rows, memory)
  local lines, bytes = {}, 0
  for i = 1, #rows do
    local row = rows[i]
    local json = memory and memory[row]
    if not json then
      local ok
      ok, json = pcall(vim.json.encode, row)
      if not ok then
        return nil
      end
      if memory and type(row) == "table" then
        memory[row] = json
      end
    end
    lines[i] = json
    bytes = bytes + #json
  end
  lines.bytes = bytes
  return lines
end

local function selected_json(selected)
  if selected == nil or selected == vim.NIL then
    return "null"
  end
  return vim.json.encode(selected)
end

-- The `list_rows` message for `lines`.
function M.whole(revision, selected, lines)
  return ('{"type":"list_rows","revision":%d,"selected":%s,"rows":[%s]}'):format(
    revision,
    selected_json(selected),
    table.concat(lines, ",")
  )
end

-- The runs of `new` that differ from `old`, each as { at, delete, first,
-- last }: `delete` rows from index `at` of `old`, counted from zero, give
-- way to rows `first` to `last` of `new` (none when last < first). They are
-- in order and do not overlap.
function M.splices(old, new)
  -- Strings are compared by identity, so the unchanged ends cost nothing.
  local head = 0
  local shorter = math.min(#old, #new)
  while head < shorter and old[head + 1] == new[head + 1] do
    head = head + 1
  end
  local tail = 0
  while tail < shorter - head and old[#old - tail] == new[#new - tail] do
    tail = tail + 1
  end
  local removed, added = #old - head - tail, #new - head - tail
  if removed == 0 and added == 0 then
    return {}
  end
  if removed == 0 or added == 0 or math.max(removed, added) > MAX_COMPARED then
    return { { at = head, delete = removed, first = head + 1, last = head + added } }
  end
  -- The part between the unchanged ends is compared line by line: a row moved
  -- from one group to another is two small changes, not everything between.
  local changes = diff(
    table.concat(old, "\n", head + 1, #old - tail) .. "\n",
    table.concat(new, "\n", head + 1, #new - tail) .. "\n",
    { result_type = "indices" }
  )
  local splices = {}
  for _, change in ipairs(changes) do
    local old_start, old_count, new_start, new_count = unpack(change)
    -- A change that removes nothing names the line it follows.
    local at = head + (old_count > 0 and old_start - 1 or old_start)
    local first = head + (new_count > 0 and new_start or new_start + 1)
    splices[#splices + 1] =
      { at = at, delete = old_count, first = first, last = first + new_count - 1 }
  end
  return splices
end

-- The `list_patch` message that turns the rows of revision `base` into
-- `lines`, or nil when sending the whole list is as good.
function M.patch(revision, base, selected, splices, lines)
  local parts, bytes = {}, 0
  for i, splice in ipairs(splices) do
    local rows = table.concat(lines, ",", splice.first, splice.last)
    bytes = bytes + #rows
    parts[i] = ('{"at":%d,"delete":%d,"rows":[%s]}'):format(splice.at, splice.delete, rows)
  end
  if bytes > lines.bytes * WORTHWHILE then
    return nil
  end
  return ('{"type":"list_patch","revision":%d,"base":%d,"selected":%s,"splices":[%s]}'):format(
    revision,
    base,
    selected_json(selected),
    table.concat(parts, ",")
  )
end

return M
