local Rows = require("sprite.rows")

-- The list `splices` describe, made from `old` and `new`.
local function applied(old, new, splices)
  local out, next_row = {}, 1
  for _, splice in ipairs(splices) do
    for i = next_row, splice.at do
      out[#out + 1] = old[i]
    end
    for i = splice.first, splice.last do
      out[#out + 1] = new[i]
    end
    next_row = splice.at + splice.delete + 1
  end
  for i = next_row, #old do
    out[#out + 1] = old[i]
  end
  return out
end

local function letters(text)
  local list = {}
  for letter in text:gmatch(".") do
    list[#list + 1] = letter
  end
  return list
end

-- Every change is found, and nothing else.
for _, case in ipairs({
  { "abcdef", "abcdef", 0 },
  { "abcdef", "abXdef", 1 },
  { "abcdef", "abdef", 1 },
  { "abcdef", "abcXdef", 1 },
  { "abcdef", "Xabcdef", 1 },
  { "abcdef", "abcdefX", 1 },
  { "", "abc", 1 },
  { "abc", "", 1 },
  { "", "", 0 },
  -- A row moved from one place to another is two changes, not all between.
  { "abcdefgh", "acdefgbh", 2 },
  { "abcdefgh", "aXcdefgY", 2 },
  { "aaaa", "aa", 1 },
  { "abab", "baba", nil },
}) do
  local old, new = letters(case[1]), letters(case[2])
  local splices = Rows.splices(old, new)
  T.eq(applied(old, new, splices), new, case[1] .. " becomes " .. case[2])
  if case[3] then
    T.eq(#splices, case[3], case[1] .. " to " .. case[2] .. " is " .. case[3] .. " changes")
  end
  local last_end = 0
  for _, splice in ipairs(splices) do
    T.ok(splice.at >= last_end, "changes are in order and do not overlap")
    last_end = splice.at + splice.delete
  end
end

-- The same holds for lists changed at random.
math.randomseed(20261117)
local wrong = 0
for _ = 1, 400 do
  local old, new = {}, {}
  for i = 1, math.random(0, 40) do
    old[i] = "row" .. math.random(1, 60)
  end
  for i = 1, #old do
    local roll = math.random(1, 10)
    if roll <= 7 then
      new[#new + 1] = old[i]
    elseif roll == 8 then
      new[#new + 1] = "new" .. math.random(1, 60)
    elseif roll == 9 then
      new[#new + 1] = old[i]
      new[#new + 1] = "new" .. math.random(1, 60)
    end
  end
  if not vim.deep_equal(applied(old, new, Rows.splices(old, new)), new) then
    wrong = wrong + 1
  end
end
T.eq(wrong, 0, "random changes are all described exactly")

-- The messages are the JSON the host reads.
local rows = {
  { id = "a", text = 'say "hi" ↑', indent = 0, guides = {} },
  {
    id = "b",
    text = "b",
    indent = 8,
    guides = { { offset = 8, id = "a" } },
    badge = { text = "M" },
  },
}
local lines = Rows.lines(rows)
T.eq(#lines, 2, "one line a row")
T.eq(lines.bytes, #lines[1] + #lines[2], "the lines' length is counted")
T.eq(
  vim.json.decode(Rows.whole(7, "a", lines)),
  { type = "list_rows", revision = 7, selected = "a", rows = rows },
  "the whole list decodes to its rows"
)
T.eq(
  vim.json.decode(Rows.whole(7, nil, {}), { luanil = { object = true } }),
  { type = "list_rows", revision = 7, rows = {} },
  "no selection is null, and no rows an empty list"
)
T.ok(Rows.whole(7, nil, {}):find('"selected":null', 1, true), "null is written out")
T.eq(
  Rows.lines({ { id = "a", bad = function() end } }),
  nil,
  "a row that cannot be encoded is reported"
)

-- With a memory, a row table seen before is not encoded again.
do
  local memory = Rows.memory()
  local kept = { id = "k", text = "kept", indent = 0, guides = {} }
  local first = Rows.lines({ kept }, memory)
  local encodes, encode = 0, vim.json.encode
  vim.json.encode = function(...)
    encodes = encodes + 1
    return encode(...)
  end
  local fresh = { id = "f", text = "fresh", indent = 0, guides = {} }
  local second = Rows.lines({ kept, fresh }, memory)
  vim.json.encode = encode
  T.eq(encodes, 1, "only the new row is encoded")
  T.eq(second[1], first[1], "the remembered row keeps its text")
  T.eq(vim.json.decode(second[2]), fresh, "the new row is encoded as itself")
  T.eq(#Rows.lines({ kept, fresh }), 2, "without a memory every row is encoded")
  -- A row the caller lets go of is forgotten.
  kept, fresh, first, second = nil, nil, nil, nil
  collectgarbage()
  collectgarbage()
  T.eq(next(memory), nil, "the memory does not keep rows alive")
end

-- A patch carries only the rows that changed, and is not sent when they are most of the list.
local many, changed = {}, {}
for i = 1, 200 do
  many[i] = { id = "r" .. i, text = "row " .. i, indent = 0, guides = {} }
  changed[i] = many[i]
end
changed[50] = { id = "r50", text = "renamed", indent = 0, guides = {} }
local old_lines, new_lines = Rows.lines(many), Rows.lines(changed)
local patch = Rows.patch(9, 8, "r50", Rows.splices(old_lines, new_lines), new_lines)
T.eq(vim.json.decode(patch), {
  type = "list_patch",
  revision = 9,
  base = 8,
  selected = "r50",
  splices = { { at = 49, delete = 1, rows = { changed[50] } } },
}, "one changed row is one splice of one row")
T.ok(#patch < 200, "and a few bytes, not the list")
local other = {}
for i = 1, 200 do
  other[i] = { id = "x" .. i, text = "other " .. i, indent = 0, guides = {} }
end
local other_lines = Rows.lines(other)
T.eq(
  Rows.patch(9, 8, nil, Rows.splices(old_lines, other_lines), other_lines),
  nil,
  "a list that changed everywhere is sent whole"
)

-- Through a dock: the caller hands over every row; what is sent depends on the host.
do
  local Host = dofile("tests/dock_host.lua")
  local host = Host.start()
  local sprite = require("sprite")
  local handle
  sprite.open({
    side = "left",
    width = 280,
    description = { version = 1, root = { kind = "virtual_list", row_height = 22 } },
  }, function(e, h)
    T.eq(e, nil, "the dock opens")
    handle = h or false
  end)
  assert(vim.wait(3000, function()
    return handle ~= nil
  end))
  T.ok(handle.features[Rows.FEATURE], "the host says it takes patches")
  local function send(revision, list, selected)
    local answer
    handle:rows(revision, list, selected, function(e)
      answer = e or true
    end)
    assert(
      vim.wait(3000, function()
        return answer
      end),
      "rows are answered"
    )
    return answer
  end
  local function ids()
    return vim.tbl_map(function(row)
      return row.id
    end, host.rows)
  end
  T.eq(send(1, many, "r1"), true, "the first list is accepted")
  T.eq(#host:messages("list_rows"), 1, "the first list is sent whole")
  T.eq(send(2, changed, "r50"), true, "a changed list is accepted")
  T.eq(#host:messages("list_rows"), 1, "and not sent whole again")
  local patches = host:messages("list_patch")
  T.eq(#patches, 1, "one patch")
  T.eq(patches[1].base, 1, "made against the first list")
  T.eq(#patches[1].splices, 1, "of one change")
  T.eq(host.rows[50].text, "renamed", "the host holds the changed row")
  T.eq(#host.rows, 200, "among all the others")

  -- A row moved to the top and one removed.
  local moved = vim.list_slice(changed, 1, 200)
  table.insert(moved, 1, table.remove(moved, 120))
  table.remove(moved, 80)
  T.eq(send(3, moved, vim.NIL), true, "a moved row is accepted")
  T.eq(#host:messages("list_patch"), 2, "as a patch")
  T.eq(
    ids(),
    vim.tbl_map(function(row)
      return row.id
    end, moved),
    "and the host's rows are the caller's, in order"
  )

  -- A host that refuses a patch is sent the whole list in its place.
  local again = vim.list_slice(moved, 1, #moved)
  again[10] = { id = "fresh", text = "fresh", indent = 0, guides = {} }
  host.refuse_once = "list_patch"
  T.eq(send(4, again, "fresh"), true, "the caller is not told of the refused patch")
  T.eq(host.refused, 1, "the patch was refused")
  T.eq(#host:messages("list_rows"), 2, "and the whole list followed")
  T.eq(host:messages("list_rows")[2].revision, 4, "under the same revision")
  T.eq(host.rows[10].id, "fresh", "so the host holds the new rows")

  -- An unchanged list is a patch with nothing in it.
  T.eq(send(5, again, "fresh"), true, "an unchanged list is accepted")
  T.eq(#host:messages("list_patch")[#host:messages("list_patch")].splices, 0, "as an empty patch")

  -- A caller that opened with reuse_rows and passes a row table again has
  -- its remembered text sent; a changed table in its place is sent as itself.
  local reusing
  sprite.open({
    side = "right",
    width = 280,
    description = { version = 1, root = { kind = "virtual_list", row_height = 22 } },
    reuse_rows = true,
  }, function(e, h)
    T.eq(e, nil, "a second dock opens")
    reusing = h or false
  end)
  assert(vim.wait(3000, function()
    return reusing ~= nil
  end))
  local function send_reusing(revision, list)
    local answer
    reusing:rows(revision, list, vim.NIL, function(e)
      answer = e or true
    end)
    assert(
      vim.wait(3000, function()
        return answer
      end),
      "rows are answered"
    )
    return answer
  end
  local stable = {}
  for i = 1, 50 do
    stable[i] = { id = "s" .. i, text = "stable " .. i, indent = 0, guides = {} }
  end
  T.eq(send_reusing(1, stable), true, "the first list is accepted")
  local next_list = vim.list_slice(stable, 1, 50)
  next_list[7] = { id = "s7", text = "changed", indent = 0, guides = {} }
  local before = #host:messages("list_patch")
  T.eq(send_reusing(2, next_list), true, "a list with one new table is accepted")
  local last = host:messages("list_patch")[before + 1]
  T.eq(last and #last.splices, 1, "and sent as one change")
  T.eq(last and last.splices[1].rows[1].text, "changed", "carrying the new table's row")
  reusing:close()

  -- State still follows the newest rows.
  local state_answer
  handle:state(5, { selected = "r1" }, function(e)
    state_answer = e or true
  end)
  assert(vim.wait(3000, function()
    return state_answer
  end))
  T.eq(state_answer, true, "a state change names the patched revision")
  handle:close()
  host:close()
end
