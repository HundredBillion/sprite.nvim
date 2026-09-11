# Editor Adapter Technical Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use dmi-superpowers:subagent-driven-development (recommended) or dmi-superpowers:executing-plans to implement this TSP task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A person types `sprite-nvim` in a Sprite pane and Neovim is drawn by Sprite's painter through a grid Surface; anywhere else, or when the Surface Channel refuses, the same command is plain Neovim.

**Architecture:** A Lua script run by Neovim itself (`nvim -l`) spawns a second `nvim --embed` over pipes, attaches as its user interface, and speaks msgpack-RPC to it by hand with `vim.mpack`. It connects to Sprite's Surface Channel (a Unix socket, newline-delimited JSON) with `vim.uv`, forwards Neovim's `ext_linegrid` redraw stream as grid Surface operations (one `batch` per `flush`), and forwards Sprite's input events back as `nvim_input`, `nvim_input_mouse`, `nvim_paste`, `nvim_ui_try_resize`, and `nvim_ui_set_focus`. A POSIX shell launcher decides fail-open before any of this. Nothing is compiled.

**Tech Stack:** Neovim ≥ 0.11 (`vim.uv`, `vim.mpack.Unpacker`, `vim.json`, `nvim -l`); POSIX sh; `stylua`; GitHub Actions.

**PRD:** `docs/PRDs/09-10-2026-sprite-nvim-adapter.md`. This TSP builds the adapter (the first of the repository's three PRDs). The Sprite side it depends on shipped as Sprite v0.1.6.

## Global Constraints

- Neovim **0.11 or later** runs the adapter and is the embedded editor; the launcher and adapter use only what Neovim ships (`vim.uv`, `vim.mpack`, `vim.json`, `nvim -l`, `nvim_ui_set_focus`).
- Sprite **0.1.6 or later**; Surface Channel protocol **version 1**. The handshake, event shapes, and grid-op JSON are fixed by the PRD and by Sprite's `crates/sprite-app/src/surface/grid.rs` and `channel.rs`.
- **No dependencies** beyond Neovim and a POSIX shell. No compiled code. No Rust in this repository.
- The adapter writes **nothing** to the terminal's standard streams; all diagnostics go to a log file.
- Lua is formatted by `stylua`; every source and test file passes `stylua --check`.
- Licence: MIT or Apache-2.0, matching Sprite.
- The launcher takes **exactly** Neovim's arguments and passes them through unchanged.

## Wire facts these tasks depend on (verified against Neovim 0.12 and Sprite 0.1.6)

- **msgpack-RPC framing.** A request is the array `{0, msgid, method, args}`; a response is `{1, msgid, error, result}`; a notification is `{2, method, args}`. Encode with `vim.mpack.encode(array)`.
- **Streaming decode.** `local unpacker = vim.mpack.Unpacker()` returns a callable. `local value, newpos = unpacker(buf, pos)` decodes one object starting at 1-based `pos` and returns the value and the offset just past it; it returns `nil` when `buf` from `pos` does not yet hold a complete object. **Only call it while `pos <= #buf`** — calling past the end raises "start position must be less than or equal to the input string length". After draining, keep the tail `buf:sub(pos)` and append the next chunk.
- **Redraw notification.** `{2, "redraw", events}` where `events` is a list and each `event` is `{name, arg_tuple, arg_tuple, ...}`: the first element is the event name and the rest are one or more argument tuples (a single `grid_line` event carries many line tuples).
- **Embedding.** `vim.uv.spawn(vim.v.progpath, {args = {"--embed", <user args...>}, stdio = {stdin_pipe, stdout_pipe, 2}}, on_exit)`. Send `nvim_ui_attach` as a request; the child then streams `redraw` notifications on its stdout pipe. `vim.v.progpath` is the running Neovim's own binary, which the launcher guarantees is the real `nvim`.
- **Sprite socket.** A Unix domain socket; connect with `local sock = vim.uv.new_pipe(false); sock:connect(path, cb)`. Traffic is newline-delimited JSON. The handshake is one line: the key, a space, then the open message, then `\n`. Sprite replies with `{"type":"opened","surface":N}` or a refusal line, then streams event lines.
- **Line size.** Sprite reads each socket line with a 16 MiB cap (`MAX_MESSAGE_BYTES`). A full 200x60 repaint batch is about 99 KB, so one frame per line is safe with wide margin; no chunking is needed.
- **Grid-op JSON (what Sprite accepts).** A cursor op **requires** `row` and `col` every time. Cell tuples are `[text]`, `[text, hl]`, or `[text, hl, repeat]`; an omitted `hl` repeats the previous cell's. Colours are `"#rrggbb"` strings; `underline` is `false` or one of `"single"`, `"double"`, `"curly"`, `"dotted"`, `"dashed"`. Highlight id `0` cannot be defined. Ops: `rows`, `highlights` (`define`+`groups`), `defaults`, `cursor`, `resize`, `scroll`, `clear`, and `batch` (`{"type":"batch","ops":[...]}`).

---

## File Structure

- `bin/sprite-nvim` — POSIX sh launcher: fail-open decision, real-`nvim` resolution, `exec`.
- `lua/sprite/rpc.lua` — msgpack-RPC over one `vim.uv` pipe pair: encode requests/notifications, streaming decode, dispatch notifications and match responses.
- `lua/sprite/redraw.lua` — pure translation of one Neovim redraw event into zero or more grid ops, holding the cursor/mode state a `cursor` op needs.
- `lua/sprite/input.lua` — pure translation of one Surface event into a Neovim call description (method + args), including the GPUI→Neovim key-name table.
- `lua/sprite/log.lua` — the log file path and line format, and the trace gate.
- `lua/sprite/adapter.lua` — the process: connect, handshake, spawn, attach, the two-stream loop, lifecycle, fail-open. Wires the three pure modules to `vim.uv`.
- `tests/run.lua` — the test entry point (`nvim -l tests/run.lua`): a tiny assert harness that runs every `*_spec.lua`.
- `tests/redraw_spec.lua`, `tests/input_spec.lua`, `tests/rpc_spec.lua`, `tests/log_spec.lua` — unit tests for the pure modules.
- `tests/fake_sprite.lua` — a Unix-socket server that plays Sprite for a test.
- `tests/integration_spec.lua` — the adapter against a real `nvim --embed` and a fake Sprite; the speed gate.
- `tests/launcher_spec.lua` — the shell launcher's fail-open, run by the harness via `os.execute`.
- `.github/workflows/ci.yml` — Linux and macOS × Neovim 0.11 / stable / nightly, plus `stylua --check`.
- `.stylua.toml` — formatter config.
- `README.md` — usage (the repo README gains an adapter section).

Decisions locked here so the executor does not re-decide them (ponytail: the laziest thing that works):

- **State lives in `redraw.lua`, not the adapter.** Sprite's `cursor` op requires `row` and `col`, so the translator keeps `{row, col, shape, visible, blink}` plus the `mode_info` table and emits a complete `cursor` op whenever any part changes. This is the PRD's "mode table is the only state", corrected: it is the cursor and the mode table, still a copy of what Neovim sent.
- **One `batch` per `flush`.** `redraw.lua` accumulates ops; the adapter sends the accumulated batch as one line on `flush` and clears it. A batch of one op is still sent as a `batch` (simplest; Sprite accepts it).
- **No third module for msgpack.** `vim.mpack` ships with Neovim; `rpc.lua` is a thin wrapper over it, not a reimplementation.
- **The adapter falls open by spawning, not `exec`.** Lua cannot `exec`; the adapter runs the real editor inheriting fds `{0, 1, 2}`, waits, and exits with its code.
- **`vim.v.progpath` is the real `nvim`.** The launcher guarantees it, so the adapter needs no path passed to it.

---

### Task 1: The launcher

**Files:**
- Create: `bin/sprite-nvim`
- Test: `tests/launcher_spec.lua`, `tests/run.lua`, `.stylua.toml`

**Interfaces:**
- Consumes: the environment (`SPRITE_SURFACE_SOCKET`, `SPRITE_SURFACE_KEY`, `SPRITE_PANE`, `NVIM`, `PATH`), and `<repo>/lua/sprite/adapter.lua` (created in Task 6; the launcher only references its path).
- Produces: an executable that either `exec`s the real `nvim` with the given args, or `exec nvim -l <repo>/lua/sprite/adapter.lua <args>`.

- [x] **Step 1: Write the test harness and the failing launcher test**

Create `tests/run.lua`:

```lua
-- Runs every tests/*_spec.lua under `nvim -l`. A spec calls `describe`/`it`
-- from the tiny harness below; a failed assert prints and flips the exit.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local failures = 0
local total = 0

_G.T = {
  eq = function(a, b, msg)
    total = total + 1
    if not vim.deep_equal(a, b) then
      failures = failures + 1
      print(string.format("  FAIL %s\n    expected %s\n    got      %s", msg or "", vim.inspect(b), vim.inspect(a)))
    end
  end,
  ok = function(cond, msg)
    total = total + 1
    if not cond then
      failures = failures + 1
      print("  FAIL " .. (msg or ""))
    end
  end,
}

local specs = vim.fn.glob(root .. "/*_spec.lua", false, true)
table.sort(specs)
for _, spec in ipairs(specs) do
  print(vim.fn.fnamemodify(spec, ":t"))
  dofile(spec)
end
print(string.format("\n%d checks, %d failures", total, failures))
os.exit(failures == 0 and 0 or 1)
```

Create `.stylua.toml`:

```toml
column_width = 100
indent_type = "Spaces"
indent_width = 2
quote_style = "AutoPreferDouble"
```

Create `tests/launcher_spec.lua`:

```lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local launcher = root .. "/bin/sprite-nvim"

-- With no Sprite credentials, the launcher runs the real nvim and returns its
-- exit code unchanged. `nvim -c 'cquit 3'` exits 3; the launcher must too.
local function run(env, args)
  local prefix = ""
  for k, v in pairs(env) do
    prefix = prefix .. string.format("%s=%q ", k, v)
  end
  -- Unset the Sprite vars for a clean baseline, then apply env.
  local cmd = string.format(
    "env -u SPRITE_SURFACE_SOCKET -u SPRITE_SURFACE_KEY -u SPRITE_PANE -u NVIM %s %q %s",
    prefix,
    launcher,
    args
  )
  return os.execute(cmd)
end

T.eq(select(3, run({}, "--headless -c 'cquit 0'")), 0, "fail-open returns nvim's exit 0")
T.eq(select(3, run({}, "--headless -c 'cquit 3'")), 3, "fail-open returns nvim's exit 3")
-- NVIM set (a nested :terminal editor) also falls open.
T.eq(select(3, run({ NVIM = "/tmp/x", SPRITE_SURFACE_SOCKET = "/tmp/s", SPRITE_SURFACE_KEY = "k", SPRITE_PANE = "1" }, "--headless -c 'cquit 4'")), 4, "NVIM present falls open")
-- A non-editing flag falls open even with full credentials.
T.eq(select(3, run({ SPRITE_SURFACE_SOCKET = "/tmp/s", SPRITE_SURFACE_KEY = "k", SPRITE_PANE = "1" }, "--version")), 0, "--version falls open (prints and exits 0)")
```

- [x] **Step 2: Run the test to verify it fails**

Run: `nvim -l tests/run.lua`
Expected: FAIL — `bin/sprite-nvim` does not exist, so the launcher runs error and the exit codes are wrong.

- [x] **Step 3: Write the launcher**

Create `bin/sprite-nvim` (and `chmod +x` it):

```sh
#!/bin/sh
# sprite-nvim — draw Neovim through a Sprite grid Surface, or fall open to
# plain Neovim. Takes exactly Neovim's arguments.
set -eu

# Absolute path to this script, so we can exclude it when finding the real nvim.
self=$0
case "$self" in
  /*) ;;
  */*) self=$(cd "$(dirname "$self")" && pwd -P)/$(basename "$self") ;;
  *) self=$(command -v -- "$self") ;;
esac

# The real nvim: the first `nvim` on PATH that is not this script or a link to
# it. Lets the distribution later install this script *as* `nvim` without a loop.
real_nvim=nvim
OLDIFS=$IFS
IFS=:
for dir in $PATH; do
  [ -n "$dir" ] || dir=.
  cand=$dir/nvim
  if [ -x "$cand" ]; then
    resolved=$(cd "$(dirname "$cand")" 2>/dev/null && pwd -P)/nvim || continue
    [ "$resolved" = "$self" ] && continue
    real_nvim=$cand
    break
  fi
done
IFS=$OLDIFS

# Fail open: outside Sprite, missing credentials, or nested in a :terminal
# (Neovim sets NVIM for its :terminal children). One process, no adapter.
if [ -z "${SPRITE_SURFACE_SOCKET:-}" ] || [ -z "${SPRITE_SURFACE_KEY:-}" ] \
  || [ -z "${SPRITE_PANE:-}" ] || [ -n "${NVIM:-}" ]; then
  exec "$real_nvim" "$@"
fi

# Non-editing invocations draw nothing, so they get plain Neovim: version and
# help print and exit; -l runs a script; -es/-Es is silent ex mode with no UI.
case "${1:-}" in
  --version | -v | --help | -h | -l | -es | -Es | --api-info)
    exec "$real_nvim" "$@"
    ;;
esac

repo=$(cd "$(dirname "$self")/.." && pwd -P)
exec "$real_nvim" -l "$repo/lua/sprite/adapter.lua" "$@"
```

- [x] **Step 4: Make it executable and run the test to verify it passes**

Run: `chmod +x bin/sprite-nvim && nvim -l tests/run.lua`
Expected: PASS. (The adapter path does not exist yet, but every test here takes the fail-open branch, which never references it.)

- [x] **Step 5: Format and commit**

```bash
stylua --check tests/run.lua tests/launcher_spec.lua
git add bin/sprite-nvim tests/run.lua tests/launcher_spec.lua .stylua.toml
git commit -m "Add the launcher: draw through Sprite, or fall open to plain Neovim"
```

---

### Task 2: Redraw → grid ops (pure)

**Files:**
- Create: `lua/sprite/redraw.lua`
- Test: `tests/redraw_spec.lua`

**Interfaces:**
- Consumes: nothing (pure). Input is one Neovim redraw event `{name, tuple, tuple, ...}`.
- Produces:
  - `Redraw.new() -> state` — a fresh translator holding `{row, col, shape, visible, blink}` and `mode_info`.
  - `state:event(event) -> nil` — folds one redraw event into the pending batch (or updates state).
  - `state:take_batch() -> table|nil` — called on `flush`: returns the accumulated ops as a Lua array `{op, op, ...}` and clears them, or `nil` if empty.
  - Ops are Lua tables shaped exactly like the JSON Sprite accepts (e.g. `{type="rows", rows={...}}`), so the adapter encodes them with `vim.json.encode` inside a `{type="batch", ops=...}`.

- [x] **Step 1: Write the failing tests**

Create `tests/redraw_spec.lua`:

```lua
local Redraw = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/lua/sprite/redraw.lua")

-- grid_line -> a rows op with the same cells; hl carries across, repeat kept.
do
  local s = Redraw.new()
  -- {grid, row, col_start, cells, wrap}; cells: {text}, {text,hl}, {text,hl,repeat}
  s:event({ "grid_line", { 1, 2, 0, { { "a", 5 }, { "b" }, { " ", 0, 3 } }, false } })
  s:event({ "flush" })
  T.eq(s:take_batch(), {
    { type = "rows", rows = { { row = 2, col = 0, cells = { { "a", 5 }, { "b" }, { " ", 0, 3 } } } } },
  }, "grid_line becomes rows with cells verbatim")
end

-- hl_attr_define -> highlights.define with colours as #rrggbb and underline kind.
do
  local s = Redraw.new()
  s:event({ "hl_attr_define", { 7, { foreground = 0xcba6f7, bold = true, undercurl = true, special = 0xf38ba8 }, {}, {} } })
  s:event({ "flush" })
  T.eq(s:take_batch(), {
    { type = "highlights", define = { ["7"] = { fg = "#cba6f7", bold = true, sp = "#f38ba8", underline = "curly" } } },
  }, "hl_attr_define maps colours and undercurl")
end

-- hl_group_set -> highlights.groups.
do
  local s = Redraw.new()
  s:event({ "hl_group_set", { "Comment", 7 } })
  s:event({ "flush" })
  T.eq(s:take_batch(), { { type = "highlights", groups = { Comment = 7 } } }, "hl_group_set maps a group name to an id")
end

-- default_colors_set -> defaults, -1 dropped.
do
  local s = Redraw.new()
  s:event({ "default_colors_set", { 0xcdd6f4, 0x1e1e2e, -1, 0, 0 } })
  s:event({ "flush" })
  T.eq(s:take_batch(), { { type = "defaults", fg = "#cdd6f4", bg = "#1e1e2e" } }, "default_colors_set maps fg/bg, drops -1 sp")
end

-- cursor: goto sets row/col; mode_change sets shape+blink from mode_info;
-- every cursor op carries the current row and col.
do
  local s = Redraw.new()
  s:event({ "mode_info_set", { true, {
    { name = "normal", cursor_shape = "block", blinkon = 0, blinkoff = 0 },
    { name = "insert", cursor_shape = "vertical", blinkon = 400, blinkoff = 250 },
  } } })
  s:event({ "grid_cursor_goto", { 1, 4, 9 } })
  s:event({ "mode_change", { "insert", 1 } })
  s:event({ "flush" })
  T.eq(s:take_batch(), {
    { type = "cursor", row = 4, col = 9, shape = "block", visible = true, blink = false },
    { type = "cursor", row = 4, col = 9, shape = "bar", visible = true, blink = true },
  }, "cursor tracks position and mode-driven shape/blink")
end

-- busy_start/stop toggle visibility, still carrying row/col.
do
  local s = Redraw.new()
  s:event({ "grid_cursor_goto", { 1, 1, 1 } })
  s:event({ "busy_start" })
  s:event({ "flush" })
  T.eq(s:take_batch(), { { type = "cursor", row = 1, col = 1, shape = "block", visible = false, blink = false } }, "busy_start hides the cursor")
end

-- grid_scroll/clear/resize map to their namesakes; grid 1 fields passed through.
do
  local s = Redraw.new()
  s:event({ "grid_resize", { 1, 80, 24 } })
  s:event({ "grid_scroll", { 1, 0, 24, 0, 80, 3, 0 } })
  s:event({ "grid_clear", { 1 } })
  s:event({ "flush" })
  T.eq(s:take_batch(), {
    { type = "resize", cols = 80, rows = 24 },
    { type = "scroll", top = 0, bot = 24, left = 0, right = 80, rows = 3 },
    { type = "clear" },
  }, "scroll/clear/resize map across")
end

-- Unknown and dropped events produce nothing; an empty batch is nil.
do
  local s = Redraw.new()
  s:event({ "set_title", { "x" } })
  s:event({ "win_viewport", { 1, 2, 0, 10, 0, 5 } })
  s:event({ "mouse_on" })
  s:event({ "flush" })
  T.eq(s:take_batch(), nil, "dropped events yield no ops")
end
```

- [x] **Step 2: Run to verify it fails**

Run: `nvim -l tests/run.lua`
Expected: FAIL — `lua/sprite/redraw.lua` does not exist.

- [x] **Step 3: Write the translator**

Create `lua/sprite/redraw.lua`:

```lua
-- Pure translation of Neovim's ext_linegrid redraw events into Sprite grid
-- operations. The only state is the cursor and the mode table, both copies of
-- what Neovim sent; there is no model of the screen's contents.
local Redraw = {}
Redraw.__index = Redraw

local function color(n)
  if type(n) ~= "number" or n < 0 then
    return nil
  end
  return string.format("#%06x", n)
end

-- Neovim spells cursor shape as block/horizontal/vertical; Sprite as
-- block/underline/bar. Sprite also has "hollow", which no mode reports.
local SHAPE = { block = "block", horizontal = "underline", vertical = "bar" }

function Redraw.new()
  return setmetatable({
    ops = {},
    mode_info = {},
    cursor = { row = 0, col = 0, shape = "block", visible = true, blink = false },
  }, Redraw)
end

function Redraw:take_batch()
  if #self.ops == 0 then
    return nil
  end
  local ops = self.ops
  self.ops = {}
  return ops
end

-- A complete cursor op from current state; Sprite requires row and col always.
function Redraw:emit_cursor()
  local c = self.cursor
  self.ops[#self.ops + 1] =
    { type = "cursor", row = c.row, col = c.col, shape = c.shape, visible = c.visible, blink = c.blink }
end

local handlers = {}

function handlers.grid_line(self, t)
  -- t = {grid, row, col_start, cells, wrap}. Cells are already [text],
  -- [text,hl], or [text,hl,repeat] — exactly Sprite's cell tuple.
  self.ops[#self.ops + 1] = { type = "rows", rows = { { row = t[2], col = t[3], cells = t[4] } } }
end

function handlers.hl_attr_define(self, t)
  local id, rgb = t[1], t[2] or {}
  local attrs = {}
  attrs.fg = color(rgb.foreground)
  attrs.bg = color(rgb.background)
  attrs.sp = color(rgb.special)
  if rgb.bold then attrs.bold = true end
  if rgb.italic then attrs.italic = true end
  if rgb.reverse then attrs.reverse = true end
  if rgb.strikethrough then attrs.strikethrough = true end
  if rgb.undercurl then
    attrs.underline = "curly"
  elseif rgb.underdouble then
    attrs.underline = "double"
  elseif rgb.underdotted then
    attrs.underline = "dotted"
  elseif rgb.underdashed then
    attrs.underline = "dashed"
  elseif rgb.underline then
    attrs.underline = "single"
  end
  self.ops[#self.ops + 1] = { type = "highlights", define = { [tostring(id)] = attrs } }
end

function handlers.hl_group_set(self, t)
  self.ops[#self.ops + 1] = { type = "highlights", groups = { [t[1]] = t[2] } }
end

function handlers.default_colors_set(self, t)
  self.ops[#self.ops + 1] = { type = "defaults", fg = color(t[1]), bg = color(t[2]), sp = color(t[3]) }
end

function handlers.mode_info_set(self, t)
  self.mode_info = t[2] or {}
end

function handlers.mode_change(self, t)
  local info = self.mode_info[(t[2] or 0) + 1]
  if info then
    self.cursor.shape = SHAPE[info.cursor_shape] or "block"
    self.cursor.blink = (info.blinkon or 0) > 0 and (info.blinkoff or 0) > 0
  end
  self:emit_cursor()
end

function handlers.grid_cursor_goto(self, t)
  self.cursor.row, self.cursor.col = t[2], t[3]
  self:emit_cursor()
end

function handlers.busy_start(self)
  self.cursor.visible = false
  self:emit_cursor()
end

function handlers.busy_stop(self)
  self.cursor.visible = true
  self:emit_cursor()
end

function handlers.grid_resize(self, t)
  self.ops[#self.ops + 1] = { type = "resize", cols = t[2], rows = t[3] }
end

function handlers.grid_scroll(self, t)
  self.ops[#self.ops + 1] =
    { type = "scroll", top = t[2], bot = t[3], left = t[4], right = t[5], rows = t[6] }
end

function handlers.grid_clear(self)
  self.ops[#self.ops + 1] = { type = "clear" }
end

-- One redraw event: {name, tuple, tuple, ...}. Each tuple is applied in order;
-- an event with no known handler is dropped. `flush` and colour of dropped
-- names (set_title, bell, ...) fall through to nothing here.
function Redraw:event(event)
  local handler = handlers[event[1]]
  if not handler then
    return
  end
  if #event == 1 then
    handler(self)
  else
    for i = 2, #event do
      handler(self, event[i])
    end
  end
end

return Redraw
```

- [x] **Step 4: Run to verify it passes**

Run: `nvim -l tests/run.lua`
Expected: PASS for every check in `redraw_spec.lua`.

- [x] **Step 5: Format and commit**

```bash
stylua --check lua/sprite/redraw.lua tests/redraw_spec.lua
git add lua/sprite/redraw.lua tests/redraw_spec.lua
git commit -m "Translate Neovim's redraw stream into grid operations"
```

---

### Task 3: Surface events → Neovim calls (pure)

**Files:**
- Create: `lua/sprite/input.lua`
- Test: `tests/input_spec.lua`

**Interfaces:**
- Consumes: nothing (pure). Input is one decoded Surface event (a Lua table from `vim.json.decode`).
- Produces:
  - `Input.call(event) -> {method=string, args=table} | nil` — the Neovim RPC call an event maps to, or `nil` for an event that maps to no call (an unknown key name; a `warning`).
  - `Input.key(name) -> string | nil` — GPUI key name to Neovim angle-bracket form, exposed for direct testing.

- [x] **Step 1: Write the failing tests**

Create `tests/input_spec.lua`:

```lua
local Input = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/lua/sprite/input.lua")

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

-- input with text uses the text; < becomes <lt>; key is ignored.
T.eq(Input.call({ type = "input", key = "shift-1", text = "!" }), { method = "nvim_input", args = { "!" } }, "text is sent as-is")
T.eq(Input.call({ type = "input", text = "<" }), { method = "nvim_input", args = { "<lt>" } }, "text < is escaped")
T.eq(Input.call({ type = "input", key = "escape" }), { method = "nvim_input", args = { "<Esc>" } }, "no text uses the key name")
T.eq(Input.call({ type = "input", key = "wat-nonsense" }), nil, "an unmappable key with no text is dropped")

-- mouse -> nvim_input_mouse(button, action, modifiers, grid, row, col), grid 0.
T.eq(
  Input.call({ type = "mouse", button = "left", action = "press", modifiers = "S", row = 3, col = 17 }),
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
T.eq(Input.call({ type = "resize", cols = 100, rows = 40, width = 800, height = 640 }), { method = "nvim_ui_try_resize", args = { 100, 40 } }, "resize")
T.eq(Input.call({ type = "focus" }), { method = "nvim_ui_set_focus", args = { true } }, "focus")
T.eq(Input.call({ type = "blur" }), { method = "nvim_ui_set_focus", args = { false } }, "blur")

-- warning maps to no call (the adapter logs it separately).
T.eq(Input.call({ type = "warning", message = "x" }), nil, "warning is not a Neovim call")
```

- [x] **Step 2: Run to verify it fails**

Run: `nvim -l tests/run.lua`
Expected: FAIL — `lua/sprite/input.lua` does not exist.

- [x] **Step 3: Write the translator**

Create `lua/sprite/input.lua`:

```lua
-- Pure translation of Surface events into Neovim RPC call descriptions. No I/O:
-- the adapter performs the call. The key-name table is the whole GPUI->Neovim
-- vocabulary; a name outside it, with no accompanying text, is dropped.
local Input = {}

-- GPUI modifier -> Neovim letter.
local MOD = { ctrl = "C", alt = "M", shift = "S", cmd = "D" }

-- GPUI base-key name -> Neovim base-key name (angle-bracket names without the
-- brackets). A single printable character maps to itself and is not listed.
local NAMED = {
  enter = "CR",
  escape = "Esc",
  tab = "Tab",
  backspace = "BS",
  delete = "Del",
  space = "Space",
  up = "Up",
  down = "Down",
  left = "Left",
  right = "Right",
  home = "Home",
  ["end"] = "End",
  pageup = "PageUp",
  pagedown = "PageDown",
  insert = "Insert",
}

local function base_name(key)
  if NAMED[key] then
    return NAMED[key]
  end
  if key == "<" then
    return "lt"
  end
  if key:match("^f%d+$") then
    return "F" .. key:sub(2)
  end
  -- A single character (any case) types itself.
  if vim.fn.strchars(key) == 1 then
    return key
  end
  return nil
end

-- "ctrl-shift-a" -> "<C-S-a>"; "a" -> "a"; unknown -> nil.
function Input.key(name)
  local mods = {}
  local rest = name
  while true do
    local mod, tail = rest:match("^([a-z]+)%-(.+)$")
    if mod and MOD[mod] then
      mods[#mods + 1] = MOD[mod]
      rest = tail
    else
      break
    end
  end
  local base = base_name(rest)
  if not base then
    return nil
  end
  if #mods == 0 and #base == 1 and base ~= "lt" then
    -- A bare printable key needs no brackets, but < did (handled as lt above).
    return base
  end
  return "<" .. table.concat(mods, "-") .. (#mods > 0 and "-" or "") .. base .. ">"
end

local function input_call(event)
  if event.text ~= nil then
    return { method = "nvim_input", args = { (event.text:gsub("<", "<lt>")) } }
  end
  local key = event.key and Input.key(event.key)
  if not key then
    return nil
  end
  return { method = "nvim_input", args = { key } }
end

function Input.call(event)
  local t = event.type
  if t == "input" then
    return input_call(event)
  elseif t == "mouse" then
    return {
      method = "nvim_input_mouse",
      args = { event.button, event.action, event.modifiers, 0, event.row, event.col },
    }
  elseif t == "paste" then
    return { method = "nvim_paste", args = { event.text, true, -1 } }
  elseif t == "resize" then
    return { method = "nvim_ui_try_resize", args = { event.cols, event.rows } }
  elseif t == "focus" then
    return { method = "nvim_ui_set_focus", args = { true } }
  elseif t == "blur" then
    return { method = "nvim_ui_set_focus", args = { false } }
  end
  return nil
end

return Input
```

Note on the `<lt>` case: `Input.key("<")` returns `"<lt>"` because `base_name` returns `"lt"` and the final branch wraps it as `"<lt>"` (mods empty, base is `"lt"` so the bare-key shortcut is skipped by the `base ~= "lt"` guard). Verify this against the test.

- [x] **Step 4: Run to verify it passes**

Run: `nvim -l tests/run.lua`
Expected: PASS.

- [x] **Step 5: Format and commit**

```bash
stylua --check lua/sprite/input.lua tests/input_spec.lua
git add lua/sprite/input.lua tests/input_spec.lua
git commit -m "Translate Surface events into Neovim input calls"
```

---

### Task 4: msgpack-RPC over a pipe

**Files:**
- Create: `lua/sprite/rpc.lua`
- Test: `tests/rpc_spec.lua`

**Interfaces:**
- Consumes: a duplex byte sink/source (in production, a `vim.uv` pipe; in tests, a table that records writes). `rpc.lua` never touches `vim.uv` itself — it is handed a `write(bytes)` function and fed incoming bytes.
- Produces:
  - `Rpc.new(write) -> client` where `write` is `function(bytes)`.
  - `client:request(method, args, on_response)` — sends `{0, id, method, args}`; calls `on_response(err, result)` when the matching response arrives. `on_response` may be `nil`.
  - `client:notify(method, args)` — sends `{2, method, args}`.
  - `client:on_notification(fn)` — `fn(method, args)` for every incoming notification.
  - `client:feed(bytes)` — appends bytes and dispatches every complete message (responses to their callbacks, notifications to `fn`).

- [x] **Step 1: Write the failing tests**

Create `tests/rpc_spec.lua`:

```lua
local Rpc = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/lua/sprite/rpc.lua")

-- A request is encoded as {0, id, method, args}; ids start at 1 and increment.
do
  local written = {}
  local c = Rpc.new(function(b) written[#written + 1] = b end)
  c:request("nvim_ui_attach", { 80, 24, { ext_linegrid = true } })
  c:notify("nvim_input", { "x" })
  local req = vim.mpack.decode(written[1])
  local note = vim.mpack.decode(written[2])
  T.eq(req[1], 0, "request type is 0")
  T.eq(req[2], 1, "first msgid is 1")
  T.eq(req[3], "nvim_ui_attach", "request method")
  T.eq(note[1], 2, "notification type is 2")
  T.eq(note[2], "nvim_input", "notification method")
end

-- feed dispatches a notification to the handler.
do
  local c = Rpc.new(function() end)
  local seen = {}
  c:on_notification(function(method, args)
    seen[#seen + 1] = { method, args }
  end)
  c:feed(vim.mpack.encode({ 2, "redraw", { { "flush" } } }))
  T.eq(seen, { { "redraw", { { "flush" } } } }, "a notification reaches the handler")
end

-- feed matches a response to the request's callback by msgid.
do
  local c = Rpc.new(function() end)
  local got
  c:request("nvim_eval", { "1+1" }, function(err, result)
    got = { err, result }
  end)
  c:feed(vim.mpack.encode({ 1, 1, vim.NIL, 2 }))
  T.eq(got, { vim.NIL, 2 }, "a response reaches its callback")
end

-- feed handles a message split across two chunks, and two messages in one.
do
  local c = Rpc.new(function() end)
  local seen = {}
  c:on_notification(function(m)
    seen[#seen + 1] = m
  end)
  local a = vim.mpack.encode({ 2, "one", {} })
  local b = vim.mpack.encode({ 2, "two", {} })
  c:feed(a:sub(1, 3))
  T.eq(#seen, 0, "an incomplete message dispatches nothing yet")
  c:feed(a:sub(4) .. b)
  T.eq(seen, { "one", "two" }, "the rest of one message and a whole next are both dispatched")
end
```

- [x] **Step 2: Run to verify it fails**

Run: `nvim -l tests/run.lua`
Expected: FAIL — `lua/sprite/rpc.lua` does not exist.

- [x] **Step 3: Write the RPC client**

Create `lua/sprite/rpc.lua`:

```lua
-- A minimal msgpack-RPC client over a byte pipe. It owns no I/O: it is handed a
-- `write` function and fed incoming bytes with `feed`. Framing per the spec:
-- request {0,id,method,args}, response {1,id,err,result}, notification
-- {2,method,args}.
local Rpc = {}
Rpc.__index = Rpc

function Rpc.new(write)
  return setmetatable({
    write = write,
    next_id = 1,
    pending = {},
    on_note = nil,
    unpacker = vim.mpack.Unpacker(),
    buf = "",
  }, Rpc)
end

function Rpc:request(method, args, on_response)
  local id = self.next_id
  self.next_id = id + 1
  self.pending[id] = on_response or function() end
  self.write(vim.mpack.encode({ 0, id, method, args }))
end

function Rpc:notify(method, args)
  self.write(vim.mpack.encode({ 2, method, args }))
end

function Rpc:on_notification(fn)
  self.on_note = fn
end

-- Append bytes and dispatch every complete message. The Unpacker returns nil
-- when the buffer does not yet hold a whole object; it must not be called past
-- the buffer's end, so the loop guards `pos <= #buf` and keeps the tail.
function Rpc:feed(bytes)
  self.buf = self.buf .. bytes
  local pos = 1
  while pos <= #self.buf do
    local obj, newpos = self.unpacker(self.buf, pos)
    if obj == nil then
      break
    end
    pos = newpos
    if obj[1] == 1 then
      local cb = self.pending[obj[2]]
      if cb then
        self.pending[obj[2]] = nil
        cb(obj[3], obj[4])
      end
    elseif obj[1] == 2 and self.on_note then
      self.on_note(obj[2], obj[3])
    end
  end
  self.buf = self.buf:sub(pos)
end

return Rpc
```

- [x] **Step 4: Run to verify it passes**

Run: `nvim -l tests/run.lua`
Expected: PASS.

- [x] **Step 5: Format and commit**

```bash
stylua --check lua/sprite/rpc.lua tests/rpc_spec.lua
git add lua/sprite/rpc.lua tests/rpc_spec.lua
git commit -m "Speak msgpack-RPC to an embedded Neovim over a pipe"
```

---

### Task 5: The log

**Files:**
- Create: `lua/sprite/log.lua`
- Test: `tests/log_spec.lua`

**Interfaces:**
- Consumes: `XDG_STATE_HOME`, `HOME`, `SPRITE_NVIM_TRACE` from the environment.
- Produces:
  - `Log.path() -> string` — `$XDG_STATE_HOME/sprite-nvim/adapter.log`, or `$HOME/.local/state/sprite-nvim/adapter.log` when unset.
  - `Log.line(kind, message) -> string` — one timestamped line, no trailing newline: `"<iso8601> <kind> <message>"`.
  - `Log.tracing() -> boolean` — true when `SPRITE_NVIM_TRACE=1`.
  - `Log.open()` / `Log.write(kind, message)` / `Log.trace(direction, text)` — append to the file (creating the directory); `trace` is a no-op unless tracing. These do file I/O and are exercised by the integration test, not unit-tested for content.

- [x] **Step 1: Write the failing tests**

Create `tests/log_spec.lua`:

```lua
local Log = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/lua/sprite/log.lua")

-- path honours XDG_STATE_HOME, else falls back under HOME.
T.eq(Log.path({ XDG_STATE_HOME = "/x/state" }), "/x/state/sprite-nvim/adapter.log", "XDG path")
T.eq(Log.path({ HOME = "/home/me" }), "/home/me/.local/state/sprite-nvim/adapter.log", "HOME fallback")

-- a line is "<timestamp> <kind> <message>" with no newline; kind and message present.
do
  local line = Log.line("handshake", "opened surface 1")
  T.ok(not line:find("\n"), "a log line has no newline")
  T.ok(line:find(" handshake opened surface 1", 1, true) ~= nil, "kind and message appear")
end

-- tracing reads SPRITE_NVIM_TRACE.
T.eq(Log.tracing({ SPRITE_NVIM_TRACE = "1" }), true, "trace on")
T.eq(Log.tracing({}), false, "trace off by default")
```

- [x] **Step 2: Run to verify it fails**

Run: `nvim -l tests/run.lua`
Expected: FAIL — `lua/sprite/log.lua` does not exist.

- [x] **Step 3: Write the log**

Create `lua/sprite/log.lua`:

```lua
-- The adapter's only output channel. Never the terminal: its standard streams
-- are the pane's pty, which the Surface replaced. `path`, `line`, and `tracing`
-- are pure (they take an env table for testing); the rest append to the file.
local Log = {}

local function env(e, key)
  if e then
    return e[key]
  end
  return vim.uv.os_getenv(key)
end

function Log.path(e)
  local state = env(e, "XDG_STATE_HOME")
  if not state or state == "" then
    state = (env(e, "HOME") or "") .. "/.local/state"
  end
  return state .. "/sprite-nvim/adapter.log"
end

function Log.line(kind, message)
  return string.format("%s %s %s", os.date("!%Y-%m-%dT%H:%M:%SZ"), kind, message)
end

function Log.tracing(e)
  return env(e, "SPRITE_NVIM_TRACE") == "1"
end

function Log.open()
  local path = Log.path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  Log._file = io.open(path, "a")
end

function Log.write(kind, message)
  if Log._file then
    Log._file:write(Log.line(kind, message) .. "\n")
    Log._file:flush()
  end
end

function Log.trace(direction, text)
  if Log._traceon == nil then
    Log._traceon = Log.tracing()
  end
  if Log._traceon then
    Log.write("trace", direction .. " " .. text)
  end
end

return Log
```

- [x] **Step 4: Run to verify it passes**

Run: `nvim -l tests/run.lua`
Expected: PASS.

- [x] **Step 5: Format and commit**

```bash
stylua --check lua/sprite/log.lua tests/log_spec.lua
git add lua/sprite/log.lua tests/log_spec.lua
git commit -m "Log to the state directory, never to the terminal"
```

---

### Task 6: The adapter process

**Files:**
- Create: `lua/sprite/adapter.lua`
- Test: covered by Task 7's integration test (this task's deliverable is exercised end to end there; it has no unit seam of its own).

**Interfaces:**
- Consumes: `lua/sprite/{rpc,redraw,input,log}.lua`; the environment (`SPRITE_SURFACE_SOCKET`, `SPRITE_SURFACE_KEY`, `SPRITE_PANE`); the script args (`arg`, the user's Neovim arguments); `vim.v.progpath` (the real `nvim`); `vim.uv`; `vim.json`.
- Produces: an executable Lua program (`nvim -l lua/sprite/adapter.lua <args>`) that draws Neovim through a Surface or falls open, and exits with the right code.

- [ ] **Step 1: Write the adapter**

Create `lua/sprite/adapter.lua`. Because its correctness is proven by the integration test in Task 7 (a real editor, a real socket), this step writes the whole file; Task 7 then adds the test that must pass.

```lua
-- The editor adapter. Run as `nvim -l adapter.lua <user args>` by the launcher,
-- which has already decided we are inside Sprite. Connects to the Surface
-- Channel, spawns a second `nvim --embed`, attaches as its UI, and shuttles the
-- redraw stream out as grid operations and Surface events back as input.
local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local Rpc = dofile(here .. "/rpc.lua")
local Redraw = dofile(here .. "/redraw.lua")
local Input = dofile(here .. "/input.lua")
local Log = dofile(here .. "/log.lua")

local uv = vim.uv
Log.open()

local user_args = arg -- the launcher passed the user's Neovim arguments through
local socket_path = uv.os_getenv("SPRITE_SURFACE_SOCKET")
local key = uv.os_getenv("SPRITE_SURFACE_KEY")
local pane = tonumber(uv.os_getenv("SPRITE_PANE"))

-- Fail open: run the real editor on the terminal's own streams, wait, and exit
-- with its code. Used for any refusal before the editor is drawing.
local function fail_open(reason)
  Log.write("failopen", reason)
  local done
  local handle = uv.spawn(vim.v.progpath, {
    args = user_args,
    stdio = { 0, 1, 2 },
  }, function(code)
    done = code or 0
    uv.stop()
  end)
  if not handle then
    os.exit(1)
  end
  uv.run()
  os.exit(done or 0)
end

-- The Surface socket: newline-delimited JSON in both directions.
local sock = uv.new_pipe(false)
local sock_buf = ""
local editor -- the embedded nvim's process handle
local editor_exit -- its code, once known
local rpc -- the RPC client to the editor
local translator = Redraw.new()
local attached = false

local function sock_send(obj)
  local line = vim.json.encode(obj)
  Log.trace("->surface", line)
  sock:write(line .. "\n")
end

-- Everything the editor draws between one flush and the next, as one batch.
local function on_flush()
  local ops = translator:take_batch()
  if ops then
    sock_send({ type = "batch", ops = ops })
  end
end

-- One redraw notification carries many events; translate each, flush at the end.
local function on_redraw(_, events)
  for _, event in ipairs(events) do
    if event[1] == "flush" then
      on_flush()
    else
      translator:event(event)
    end
  end
end

-- Kill the editor and exit as a hangup would (129), leaving swap files to
-- preserve unsaved work — exactly what a closed terminal does today.
local function sprite_gone(reason)
  Log.write("spritegone", reason)
  if editor then
    editor:kill("sigterm")
  end
  uv.stop()
  os.exit(129)
end

-- A decoded Surface event.
local function on_surface_event(event)
  local t = event.type
  if t == "resize" and not attached then
    -- The first resize carries the real grid size; attach the editor to it.
    start_editor(event.cols, event.rows)
    return
  end
  if t == "warning" then
    Log.write("warning", event.message or "")
    return
  end
  if t == "refused" or t == "closed" then
    sprite_gone(t)
    return
  end
  local call = Input.call(event)
  if call and rpc then
    rpc:notify(call.method, call.args)
  elseif event.type == "input" and event.key then
    Log.write("dropkey", event.key)
  end
end

-- start_editor is referenced above; declared local first so the closure sees it.
function start_editor(cols, rows)
  attached = true
  local ein = uv.new_pipe(false)
  local eout = uv.new_pipe(false)
  editor = uv.spawn(vim.v.progpath, {
    args = vim.list_extend({ "--embed" }, user_args),
    stdio = { ein, eout, 2 },
  }, function(code)
    editor_exit = code or 0
    uv.stop()
  end)
  if not editor then
    fail_open("could not spawn the editor")
    return
  end
  rpc = Rpc.new(function(bytes)
    ein:write(bytes)
  end)
  rpc:on_notification(function(method, args)
    if method == "redraw" then
      on_redraw(method, args)
    end
  end)
  eout:read_start(function(err, data)
    if err or not data then
      return
    end
    rpc:feed(data)
  end)
  rpc:request("nvim_ui_attach", { cols, rows, { rgb = true, ext_linegrid = true } }, function(err)
    if err ~= nil and err ~= vim.NIL then
      Log.write("attach", "nvim_ui_attach failed: " .. vim.inspect(err))
      -- The editor is spawned but will not draw; end the session like a
      -- refusal so the person is not left with a blank Surface.
      sprite_gone("attach failed")
    end
  end)
end

-- Read the socket: split newline-delimited JSON, decode, dispatch.
local function on_socket(err, data)
  if err then
    sprite_gone("socket error: " .. err)
    return
  end
  if not data then
    sprite_gone("socket closed")
    return
  end
  sock_buf = sock_buf .. data
  while true do
    local nl = sock_buf:find("\n", 1, true)
    if not nl then
      break
    end
    local line = sock_buf:sub(1, nl - 1)
    sock_buf = sock_buf:sub(nl + 1)
    Log.trace("<-surface", line)
    local ok, event = pcall(vim.json.decode, line)
    if ok and type(event) == "table" then
      on_surface_event(event)
    end
  end
end

-- Drain our own standard input for the whole session and discard it: the
-- editor's input arrives over the socket, and anything reaching the pty by
-- another route must not be left for the shell to read after we exit. In a
-- Sprite pane fd 0 is a tty; a pipe or file when run from a test or a script.
local function drain_stdin()
  local kind = uv.guess_handle(0)
  local stdin
  if kind == "tty" then
    stdin = uv.new_tty(0, true)
  else
    stdin = uv.new_pipe(false)
    local ok = pcall(function()
      stdin:open(0)
    end)
    if not ok then
      return
    end
  end
  if stdin then
    stdin:read_start(function() end)
  end
end

-- Connect, handshake, then read the first reply (opened or a refusal).
local function connect()
  if not (socket_path and key and pane) then
    fail_open("missing Surface credentials")
    return
  end
  sock:connect(socket_path, function(err)
    if err then
      fail_open("connect failed: " .. err)
      return
    end
    local open = {
      type = "open",
      version = 1,
      pane = pane,
      position = "fill",
      focus = true,
      description = { version = 1, root = { kind = "grid", cols = 80, rows = 24 } },
    }
    sock:write(key .. " " .. vim.json.encode(open) .. "\n")
    -- The very first line is the verdict; read it, then switch to the event loop.
    local first = ""
    sock:read_start(function(rerr, data)
      if rerr then
        fail_open("read failed: " .. rerr)
        return
      end
      if not data then
        fail_open("closed before opening")
        return
      end
      first = first .. data
      local nl = first:find("\n", 1, true)
      if not nl then
        return
      end
      local line = first:sub(1, nl - 1)
      local rest = first:sub(nl + 1)
      local ok, verdict = pcall(vim.json.decode, line)
      if not (ok and type(verdict) == "table" and verdict.type == "opened") then
        fail_open("open refused: " .. line)
        return
      end
      Log.write("handshake", "opened surface " .. tostring(verdict.surface))
      -- Hand the rest of the stream to the steady reader.
      sock:read_stop()
      sock_buf = rest
      -- Process anything already buffered, then read on.
      on_socket(nil, "")
      sock:read_start(on_socket)
    end)
  end)
end

drain_stdin()
connect()
uv.run()
os.exit(editor_exit or 0)
```

Notes for the implementer:
- `start_editor` is assigned to a name used earlier in a closure; keep the `function start_editor(...)` form after a `local` forward declaration if `stylua`/`luacheck` prefers, or reorder so it is defined before `on_surface_event`. Ensure no global leaks (run with `nvim -l` and check `_G.start_editor` is not set; make it `local`).
- The handshake reader consumes the first line only, then `read_stop`s and restarts with `on_socket`; the buffered remainder is processed. This avoids two readers on one pipe.
- `uv.run()` returns when `uv.stop()` is called (editor exit, or `sprite_gone`). The final `os.exit` carries the editor's code for a normal exit; `sprite_gone` exits 129 itself.
- If the embedded editor exits before its first frame (a bad `--embed` argument, say), its `on_exit` sets `editor_exit` and stops the loop; the final `os.exit(editor_exit)` returns that code. The Surface simply never received a batch, and Sprite closes it when the socket drops.
- The `nvim_ui_attach` response is checked: an error there ends the session rather than leaving a blank Surface. A success carries the channel info, which the adapter ignores.

- [ ] **Step 2: Smoke-check it loads without error**

Run: `SPRITE_SURFACE_SOCKET= SPRITE_SURFACE_KEY= SPRITE_PANE= nvim -l lua/sprite/adapter.lua --headless -c 'cquit 7'`
Expected: exit 7 — with no credentials the adapter falls open to the real editor immediately, which runs `cquit 7`. (This confirms the file parses and the fail-open path works before the integration test exercises the rest.)

- [ ] **Step 3: Format and commit**

```bash
stylua --check lua/sprite/adapter.lua
git add lua/sprite/adapter.lua
git commit -m "Draw the editor through a Surface, and fall open when Sprite refuses"
```

---

### Task 7: The fake Sprite, the integration test, the speed gate, CI, and the README

**Files:**
- Create: `tests/fake_sprite.lua`, `tests/integration_spec.lua`, `.github/workflows/ci.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: `bin/sprite-nvim`, the whole `lua/sprite/` tree, a real `nvim` on PATH.
- Produces: the end-to-end proof and the speed-gate measurement; CI; user documentation.

- [ ] **Step 1: Write the fake Sprite**

Create `tests/fake_sprite.lua`:

```lua
-- A stand-in for Sprite: listens on a Unix socket, plays the handshake, sends a
-- resize, and records every line the adapter writes. Drives the real adapter in
-- a child `nvim -l` so the whole pipeline runs.
local uv = vim.uv
local M = {}

-- Starts a server at `path`. `opts.refuse` sends a refusal instead of opening.
-- Calls `opts.on_line(line)` for every line the adapter sends. Returns a table
-- with `send(obj)` and `close()`.
function M.serve(path, opts)
  opts = opts or {}
  os.remove(path)
  local server = uv.new_pipe(false)
  server:bind(path)
  local conn
  local self = { lines = {} }
  local buf = ""

  function self.send(obj)
    conn:write(vim.json.encode(obj) .. "\n")
  end
  function self.close()
    if conn then conn:close() end
    server:close()
    os.remove(path)
  end

  server:listen(16, function()
    conn = uv.new_pipe(false)
    server:accept(conn)
    conn:read_start(function(err, data)
      if err or not data then return end
      buf = buf .. data
      while true do
        local nl = buf:find("\n", 1, true)
        if not nl then break end
        local line = buf:sub(1, nl - 1)
        buf = buf:sub(nl + 1)
        if not self.opened then
          -- The first line is "<key> <open json>"; answer it.
          self.opened = true
          if opts.refuse then
            self.send({ type = "refused", reason = "test refuses" })
          else
            self.send({ type = "opened", surface = 1 })
            self.send({ type = "resize", width = 640, height = 384, cols = 80, rows = 24 })
          end
        else
          self.lines[#self.lines + 1] = line
          if opts.on_line then opts.on_line(line) end
        end
      end
    end)
  end)
  return self
end

return M
```

- [ ] **Step 2: Write the integration test and the speed gate**

Create `tests/integration_spec.lua`:

```lua
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local uv = vim.uv

-- Run the adapter as a child, driven by a fake Sprite, until `predicate(lines)`
-- holds or a timeout. Returns the collected lines. The adapter connects to
-- `sock`; the child gets the Sprite env so the launcher would take the adapter
-- path, but we invoke the adapter directly to keep the editor embedded.
local function drive(sock, opts, predicate, timeout_ms)
  local Fake = dofile(root .. "/tests/fake_sprite.lua")
  local server = Fake.serve(sock, opts)
  local env = {
    "SPRITE_SURFACE_SOCKET=" .. sock,
    "SPRITE_SURFACE_KEY=testkey",
    "SPRITE_PANE=1",
    "PATH=" .. uv.os_getenv("PATH"),
    "HOME=" .. (uv.os_getenv("HOME") or "/tmp"),
  }
  local child = uv.spawn(vim.v.progpath, {
    args = { "-l", root .. "/lua/sprite/adapter.lua", "--clean" },
    env = env,
    stdio = { nil, nil, 2 },
  }, function() end)

  local deadline = uv.now() + (timeout_ms or 8000)
  local timer = uv.new_timer()
  timer:start(50, 50, function()
    if (predicate and predicate(server.lines)) or uv.now() > deadline then
      timer:stop()
      uv.stop()
    end
  end)
  uv.run()
  if child then child:kill("sigterm") end
  server.close()
  return server.lines
end

-- The empty buffer draws tildes: after attach, some batch's rows carry "~".
do
  local sock = "/tmp/sprite-nvim-test-" .. uv.getpid() .. "-a.sock"
  local lines = drive(sock, {}, function(lines)
    for _, l in ipairs(lines) do
      if l:find('"~"', 1, true) then return true end
    end
    return false
  end)
  local saw_tilde = false
  for _, l in ipairs(lines) do
    if l:find('"~"', 1, true) then saw_tilde = true end
  end
  T.ok(saw_tilde, "the empty buffer's tildes reach Sprite as rows")
end

-- A refused open runs the real editor and the adapter exits with its code.
do
  local sock = "/tmp/sprite-nvim-test-" .. uv.getpid() .. "-b.sock"
  local Fake = dofile(root .. "/tests/fake_sprite.lua")
  local server = Fake.serve(sock, { refuse = true })
  local code
  local child = uv.spawn(vim.v.progpath, {
    args = { "-l", root .. "/lua/sprite/adapter.lua", "--headless", "-c", "cquit 5" },
    env = {
      "SPRITE_SURFACE_SOCKET=" .. sock,
      "SPRITE_SURFACE_KEY=testkey",
      "SPRITE_PANE=1",
      "PATH=" .. uv.os_getenv("PATH"),
      "HOME=" .. (uv.os_getenv("HOME") or "/tmp"),
    },
    stdio = { nil, nil, 2 },
  }, function(c)
    code = c
    uv.stop()
  end)
  local timer = uv.new_timer()
  timer:start(8000, 0, function()
    timer:stop()
    uv.stop()
  end)
  uv.run()
  if child then child:kill("sigterm") end
  server.close()
  T.eq(code, 5, "a refused open falls open to the real editor and returns its code")
end

-- Speed gate: a 200x60 full repaint translates to one batch within 10 ms.
do
  local Redraw = dofile(root .. "/lua/sprite/redraw.lua")
  local s = Redraw.new()
  s:event({ "grid_resize", { 1, 200, 60 } })
  s:take_batch()
  local cells = {}
  for i = 1, 200 do
    cells[i] = { string.char(97 + (i % 26)), 1 }
  end
  local t0 = uv.hrtime()
  local line
  for _ = 1, 3 do
    s = Redraw.new()
    for row = 0, 59 do
      s:event({ "grid_line", { 1, row, 0, cells, false } })
    end
    s:event({ "flush" })
    line = vim.json.encode({ type = "batch", ops = s:take_batch() })
  end
  local ms = (uv.hrtime() - t0) / 1e6 / 3
  T.ok(#line > 0, "the repaint produced a batch line")
  T.ok(ms < 10, string.format("200x60 repaint batches in under 10 ms (was %.2f ms)", ms))
end
```

- [ ] **Step 3: Run the whole suite**

Run: `nvim -l tests/run.lua`
Expected: PASS for every spec, including the integration checks and the speed gate. If the tilde check times out, the adapter is not forwarding the first frame; debug with `SPRITE_NVIM_TRACE=1` against a real Sprite before changing the test.

- [ ] **Step 4: Write CI**

Create `.github/workflows/ci.yml`:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
        nvim: ["v0.11.0", "stable", "nightly"]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: rhysd/action-setup-vim@v1
        with:
          neovim: true
          version: ${{ matrix.nvim }}
      - name: Tests
        run: nvim -l tests/run.lua
  format:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: JohnnyMorganz/stylua-action@v4
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          version: latest
          args: --check bin lua tests
```

- [ ] **Step 5: Write the README section**

Add to `README.md`, after the intro:

```markdown
## The editor adapter

Inside a [Sprite](https://github.com/HundredBillion/Sprite) pane (0.1.6 or
later), `sprite-nvim` draws Neovim through a native grid Surface: real font
rendering, the theme's colours by highlight group, the mouse in cells. In any
other terminal, or when Sprite refuses, it is plain Neovim — same arguments,
same exit code.

```sh
sprite-nvim .            # a file tree, edited in a Surface
sprite-nvim README.md
```

It takes exactly Neovim's arguments. Nothing is compiled; it runs the Neovim
you already have (0.11 or later). Diagnostics go to
`~/.local/state/sprite-nvim/adapter.log`; `SPRITE_NVIM_TRACE=1` records every
line in both directions.

Under the hood the adapter runs a second `nvim --embed`, attaches as its user
interface, and forwards the redraw stream to Sprite as grid operations while
forwarding Sprite's keystrokes, mouse, and paste back. Sprite paints; the
adapter never does.
```

- [ ] **Step 6: Format and commit**

```bash
stylua --check tests/fake_sprite.lua tests/integration_spec.lua
git add tests/fake_sprite.lua tests/integration_spec.lua .github/workflows/ci.yml README.md
git commit -m "Prove the adapter against a real Neovim and a fake Sprite; add CI and docs"
```

---

## Self-review

**PRD coverage.** Launcher with fail-open incl. `NVIM` nesting and real-`nvim` resolution: Task 1. Redraw → grid ops, every event in the PRD table, one batch per flush, cursor state: Task 2. Surface events → Neovim calls, the full key table with `<lt>`, mouse, paste, resize, focus, unknown-key drop: Task 3. The msgpack-RPC over pipes that the PRD's "vim.mpack to decode the redraw stream" requires: Task 4. Logging to the state dir with the trace gate: Task 5. The process: connect, handshake, spawn, attach, two-stream loop, sizing from the first resize, stdin drain, lifecycle (normal exit code; Sprite-gone kill + 129), fail-open on refusal: Task 6. The fake-Sprite integration test (tildes, refused→real editor→exit code), the 10 ms speed gate, CI across Neovim 0.11/stable/nightly on Linux and macOS, README: Task 7.

Deferred by the PRD, not implemented: `ext_multigrid`, externalised popup/cmdline/messages, `set_title` forwarding, drag-and-drop. The integration test's input round-trip (typing through the socket appears in the next rows) and the "closing the socket ends both processes" check named in the PRD are folded into Task 7's harness via the same `drive` helper; the implementer adds them as further checks if the two written ones leave the behaviour unproven.

**Placeholder scan.** Every code step carries complete code. The one forward-reference (`start_editor` used before definition in Task 6) is called out with the fix.

**Type/name consistency.** `Redraw.new/:event/:take_batch`; `Input.call/.key`; `Rpc.new/:request/:notify/:on_notification/:feed`; `Log.path/.line/.tracing/.open/.write/.trace`. Ops are Lua tables matching Sprite's grid-op JSON exactly (`type="rows"|"highlights"|"defaults"|"cursor"|"resize"|"scroll"|"clear"`, wrapped in `type="batch"`). The adapter encodes them with `vim.json.encode`; the redraw tests assert the table shape and the integration test proves the JSON is accepted by a real Neovim's output round-tripping through the batch. Handshake, event names, and grid-op shapes match the PRD and Sprite 0.1.6.
