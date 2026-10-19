local Markdown = require("sprite.markdown")
local calls, attached = {}, {}
local queued = {
  {
    kind = "document",
    buffer = 1,
    generation = 3,
    path = "/project/README.md",
    text = "# Hello\n",
  },
  {
    kind = "state",
    active = 1000,
    windows = {
      {
        window = 1000,
        buffer = 1,
        generation = 3,
        preview = true,
        row = 0,
        column = 0,
        width = 80,
        height = 20,
      },
    },
    colors = {
      background = "#1e1f22",
      foreground = "#bcbec4",
      muted = "#9da0a8",
      accent = "#589df6",
      code = "#2b2d30",
    },
  },
}
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
