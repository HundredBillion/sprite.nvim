local Markdown = require("sprite.markdown")
local calls, attached = {}, {}
local fixture = vim.json.decode(
  table.concat(vim.fn.readfile(vim.fn.getcwd() .. "/tests/fixtures/native-markdown-v1.json"), "\n")
)
local queued = { vim.deepcopy(fixture.document), vim.deepcopy(fixture.state) }
Markdown.setup({
  next = function()
    return table.remove(queued, 1)
  end,
  dispatch = function(event)
    calls[#calls + 1] = event
    return true
  end,
  attached = function(value)
    attached[#attached + 1] = value
  end,
  before_input = function(event)
    return event.type ~= "paste"
  end,
})
T.eq(Markdown.pull(), vim.NIL, "unsupported sessions do not pull a provider")
Markdown.attach(99999)
T.ok(Markdown.available(), "negotiated host enables provider")
local document = Markdown.pull()
T.eq(document.type, "markdown")
T.eq(document.revision, 1)
local state = Markdown.pull()
T.eq(state.revision, 2)
T.eq(Markdown.pull(), vim.NIL, "no update when provider is idle")
T.ok(not Markdown.before_input({ type = "paste", text = "edit" }), "provider consumes paste")
T.ok(Markdown.before_input({ type = "input", key = ":" }), "provider permits command input")
local action = {
  type = "markdown_action",
  revision = state.revision,
  window = 1000,
  buffer = 1,
  generation = 3,
  action = "toggle",
}
T.ok(Markdown.dispatch(action), "matching live state dispatches")
for key, value in pairs({
  revision = 1,
  window = 1001,
  buffer = 2,
  generation = 4,
  action = "erase",
}) do
  local stale = vim.tbl_extend("force", action, { [key] = value })
  T.ok(not Markdown.dispatch(stale), "reject stale " .. key)
end
T.eq(#calls, 1)
queued[1] =
  { kind = "document", buffer = 1, generation = 4, path = "/project/README.md", text = "# Changed" }
T.eq(Markdown.pull().revision, 3)
T.ok(Markdown.dispatch(action), "a document op does not change state revision")
Markdown.attach(nil)
T.ok(not Markdown.available())
T.ok(Markdown.before_input({ type = "paste" }), "detached preview leaves source input usable")
T.eq(attached, { true, false })
T.ok(not Markdown.dispatch(action))
Markdown.setup(nil)
Markdown.attach(99999)
Markdown.setup({
  next = function()
    return nil
  end,
  before_input = function()
    error("preview hook failure")
  end,
})
T.ok(Markdown.before_input({ type = "paste" }), "failed input hook leaves source usable")
T.ok(not Markdown.available(), "failed provider disables presentation")
local recovered
Markdown.setup({
  next = function()
    return nil
  end,
  attached = function(value)
    recovered = value
  end,
})
T.ok(
  Markdown.available() and recovered,
  "registering a replacement recovers the negotiated channel"
)
Markdown.attach(nil)
Markdown.setup(nil)
local marker = vim.fn.tempname()
local init = vim.fn.tempname() .. ".lua"
vim.fn.writefile({
  "vim.opt.rtp:prepend(" .. string.format("%q", vim.fn.getcwd()) .. ")",
  'local md=require("sprite.markdown")',
  'md.setup({next=function() end,stop=function() vim.fn.writefile({"stopped"},'
    .. string.format("%q", marker)
    .. ") end})",
  "md.attach(99999)",
}, init)
local result = vim
  .system({ vim.v.progpath, "--headless", "-u", init, "+qa!" }, { text = true })
  :wait(3000)
T.eq(result.code, 0, "exit fixture closes normally")
T.eq(vim.fn.filereadable(marker), 1, "VimLeavePre stops the registered provider")
vim.fn.delete(init)
vim.fn.delete(marker)
