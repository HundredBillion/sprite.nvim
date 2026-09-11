local Input =
  dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/lua/sprite/input.lua")

-- Key name mapping, GPUI -> Neovim. Every pair is a case.
T.eq(Input.key("a"), "a", "a plain key is itself")
T.eq(Input.key("A"), "A", "an uppercase key is itself")
T.eq(Input.key("enter"), "<CR>", "enter")
T.eq(Input.key("escape"), "<Esc>", "escape")
T.eq(Input.key("tab"), "<Tab>", "tab")
T.eq(Input.key("backspace"), "<BS>", "backspace")
T.eq(Input.key("space"), "<Space>", "space")
T.eq(Input.key("up"), "<Up>", "up")
T.eq(Input.key("pageup"), "<PageUp>", "pageup")
T.eq(Input.key("home"), "<Home>", "home")
T.eq(Input.key("delete"), "<Del>", "delete")
T.eq(Input.key("f1"), "<F1>", "function key")
T.eq(Input.key("ctrl-a"), "<C-a>", "ctrl")
T.eq(Input.key("ctrl-shift-a"), "<C-S-a>", "ctrl-shift")
T.eq(Input.key("alt-x"), "<M-x>", "alt is M")
T.eq(Input.key("cmd-s"), "<D-s>", "cmd is D")
T.eq(Input.key("ctrl-enter"), "<C-CR>", "modifier plus named key")
T.eq(Input.key("<"), "<lt>", "a bare less-than is escaped")
T.eq(Input.key("é"), "é", "a single multibyte key types itself")

-- input with text uses the text; < becomes <lt>; key is ignored.
T.eq(
  Input.call({ type = "input", key = "shift-1", text = "!" }),
  { method = "nvim_input", args = { "!" } },
  "text is sent as-is"
)
T.eq(
  Input.call({ type = "input", text = "<" }),
  { method = "nvim_input", args = { "<lt>" } },
  "text < is escaped"
)
T.eq(
  Input.call({ type = "input", key = "escape" }),
  { method = "nvim_input", args = { "<Esc>" } },
  "no text uses the key name"
)
T.eq(
  Input.call({ type = "input", key = "wat-nonsense" }),
  nil,
  "an unmappable key with no text is dropped"
)

-- mouse -> nvim_input_mouse(button, action, modifiers, grid, row, col), grid 0.
T.eq(
  Input.call({
    type = "mouse",
    button = "left",
    action = "press",
    modifiers = "S",
    row = 3,
    col = 17,
  }),
  { method = "nvim_input_mouse", args = { "left", "press", "S", 0, 3, 17 } },
  "a mouse press maps straight through, grid 0"
)
T.eq(
  Input.call({ type = "mouse", button = "wheel", action = "down", modifiers = "", row = 1, col = 2 }),
  { method = "nvim_input_mouse", args = { "wheel", "down", "", 0, 1, 2 } },
  "a wheel event maps straight through"
)

-- paste -> nvim_paste(text, true, -1).
T.eq(
  Input.call({ type = "paste", text = "ls\n" }),
  { method = "nvim_paste", args = { "ls\n", true, -1 } },
  "paste is one edit with Neovim's own handling"
)

-- resize -> nvim_ui_try_resize; focus/blur -> nvim_ui_set_focus.
T.eq(
  Input.call({ type = "resize", cols = 100, rows = 40, width = 800, height = 640 }),
  { method = "nvim_ui_try_resize", args = { 100, 40 } },
  "resize"
)
T.eq(Input.call({ type = "focus" }), { method = "nvim_ui_set_focus", args = { true } }, "focus")
T.eq(Input.call({ type = "blur" }), { method = "nvim_ui_set_focus", args = { false } }, "blur")

-- warning maps to no call (the adapter logs it separately).
T.eq(Input.call({ type = "warning", message = "x" }), nil, "warning is not a Neovim call")
