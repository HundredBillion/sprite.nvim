# sprite.nvim: the editor adapter

**Status:** design approved 2026-09-10; awaiting the TSP.
**Depends on:** Sprite v0.1.5's Surface Channel and grid Surface, plus two
small Sprite additions this document specifies.
**Repository:** `HundredBillion/sprite.nvim`. This is the first of three PRDs
for the repository; the plugin API and the distribution follow it.

## Summary

A person types `nvim` in a Sprite pane and the editor is drawn by Sprite's
own painter, with the pane's font, line height, padding, and theme colours by
highlight group, instead of into the terminal's character grid. Quitting
returns the shell in the same directory with the exit code intact. In any
other terminal, or in a Sprite pane whose Surface Channel refuses, the same
command runs plain Neovim exactly as today.

The piece that makes this happen is an **adapter**: a process that runs
Neovim embedded, attaches as its user interface over RPC, and forwards
Neovim's redraw stream to Sprite as grid Surface operations while forwarding
Sprite's keystrokes and mouse events back to Neovim. It paints nothing and
keeps no picture of the screen. Sprite's grid operations were designed as a
mirror of Neovim's `ext_linegrid` events, so the adapter is a translation
table with a socket on each side.

Sprite never learns the name `nvim`. Everything editor-specific is in this
repository, and nothing here is compiled.

## Why the adapter lives here, and why it is Lua

Sprite's Native Surfaces PRD (`docs/PRDs/09-07-2026-native-surfaces.md` in
the Sprite repository) settled the boundary: programs describe what to draw
over a socket, Sprite draws it. It also settled that the Neovim side is a
process beside Neovim, because `nvim_ui_attach` exists only over RPC, and
that this process, the Lua API plugins call, and the `nvim` launcher all
live in `sprite.nvim`. This document does not revisit those decisions.

What it decides is the runtime. The adapter reformats one stream into
another and never paints, so speed matters far less than for a renderer such
as Neovide. Three runtimes were weighed:

- **Neovim itself, running a Lua script with `nvim -l`.** Everything the
  adapter needs ships inside Neovim: `vim.uv` for processes, pipes, and
  Unix sockets; `vim.mpack` to decode the msgpack-RPC redraw stream;
  `vim.json` to write Surface lines. There is nothing to compile, download,
  or verify, and the plugin installs as plain files through any plugin
  manager. The risk is throughput in LuaJIT, addressed by a measured gate
  below.
- **A Rust binary.** Sprite's toolchain and Neovide's well-trodden path, but
  it puts a compiled artefact inside a Lua plugin: every user needs cargo,
  or the repository ships prebuilt binaries per platform with a download
  step and checksums. That is the bundling burden the Native Surfaces PRD
  was written to escape.
- **Python or Node.** Mature RPC libraries, but each drags a runtime and a
  package manager into the install, with no advantage over Lua and worse
  speed than Rust.

**Decision: Lua run by Neovim.** If the speed gate fails, the same wire
behaviour ports to Rust without changing anything Sprite sees; the protocol
and the tests in this document are the specification either way.

## Scope

This release is a **daily driver**: the project owner's own LazyVim
configuration, used all day in Sprite, with everything working that works in
Ghostty today, plus native font and line-height styling. That bar includes
the mouse: wheel scrolling, clicking to place the cursor, and dragging to
select. It excludes what Neovim leaves to the terminal today: the system
clipboard (Neovim's own providers such as `pbcopy` keep working because the
embedded editor is a normal process), window titles, and bells.

Out of scope for this PRD, each with its own later PRD:

- **The plugin API**: a Lua module plugins call to open dock, fill, and
  overlay Surfaces of their own, send documents, receive events, and hand
  focus to and from the editor grid. `scm.nvim` and `svgtree.nvim` build on
  it.
- **The distribution**: placing the launcher first on PATH under the name
  `nvim` through Sprite's shell-integration directory, the install story,
  and the adaptations to `scm.nvim` and `svgtree.nvim` themselves.

Also out of scope: `ext_multigrid` (one grid, composed by Neovim, as
Neovim's own terminal UI does), `ext_popupmenu`, `ext_cmdline`,
`ext_messages`, and any other externalised element. Neovim draws them into
the single grid and Sprite paints the result.

## User outcome

- In a Sprite pane, `sprite-nvim .` (and later, through the distribution
  PRD, plain `nvim .`) opens the editor drawn by Sprite: real font
  rendering, the configured line height and padding, colours from the
  theme's `[highlights]` table by group name, a cursor that changes shape
  with the mode. Typing, including shifted symbols, dead keys, and input
  methods, produces the right characters. The wheel scrolls; clicks place
  the cursor; drags select. Resizing the pane resizes the editor.
- Quitting returns the prompt in the same directory, and `$?` is Neovim's
  exit code.
- In Ghostty, Kitty, or any other terminal, `sprite-nvim .` is plain
  Neovim with no visible difference and no extra process.
- Inside Sprite, if the Surface Channel refuses the adapter for any reason,
  the person gets plain Neovim in text mode and the adapter's log says why.

## Shape

Three files in this repository do the work. Nothing is compiled.

### `bin/sprite-nvim`

A POSIX shell script that takes exactly Neovim's arguments.

- If any of `SPRITE_SURFACE_SOCKET`, `SPRITE_SURFACE_KEY`, or `SPRITE_PANE`
  is absent from the environment, it runs `exec nvim "$@"` and is gone. This is the whole
  fail-open path outside Sprite: one process, no adapter started.
- Otherwise it runs `exec nvim -l <repo>/lua/sprite/adapter.lua "$@"`, so
  the adapter *is* the process the shell started.
- "The real `nvim`" means the first `nvim` on PATH that is not this script
  or a link to it, resolved by walking PATH and comparing resolved paths.
  This is what lets the distribution PRD later install the script under the
  name `nvim` without an infinite loop.

### `lua/sprite/adapter.lua`

The process that lives for the whole editing session.

1. Connects to the Unix socket named by `SPRITE_SURFACE_SOCKET`.
2. Sends the handshake: one line consisting of the key from
   `SPRITE_SURFACE_KEY`, a space, and the open message
   `{"type":"open","version":1,"pane":<SPRITE_PANE>,"position":"fill","focus":true,"description":{"version":1,"root":{"kind":"grid","cols":80,"rows":24}}}`.
   The columns and rows are placeholders; Sprite decides the real size.
3. Reads Sprite's answer. `{"type":"opened","surface":N}` continues.
   Anything else is a refusal: the adapter falls open (below).
4. Waits for the first `resize` event, which carries `cols` and `rows`.
5. Spawns `nvim --embed <the user's arguments>` with pipes on standard
   input and output, and attaches with
   `nvim_ui_attach(cols, rows, {rgb=true, ext_linegrid=true})`.
6. Loops until the editor exits: redraw notifications become grid
   operations; Surface events become `nvim_input`, `nvim_input_mouse`,
   `nvim_ui_try_resize`, and `nvim_ui_set_focus` calls.
7. When the editor process ends, closes the socket and exits with the
   editor's exit code.

Neovim's standard streams are pipes to the adapter, so nothing Neovim
prints reaches the terminal grid; the pane shows only the Surface. The
adapter itself writes nothing to the terminal, ever, because its standard
streams are what the Surface replaced.

### Fail-open inside the adapter

The shell script cannot see a refusal, so the adapter handles it: if the
handshake is refused, the socket cannot be connected, or the connection
drops before the first `resize`, the adapter spawns the real `nvim` with
the user's arguments and the terminal's own standard streams (the file
descriptors it inherited), waits, and exits with that process's code. The
person sees ordinary text-mode Neovim, one process deeper than in the
no-Sprite case. The reason is written to the log.

## The two streams

### Editor to Sprite

Every redraw notification is translated as it arrives. Everything between
one `flush` and the next is sent as a single `batch` line, so Sprite paints
each Neovim frame in one step. The translation is fixed and stateless:

| Neovim event | Grid operation |
|---|---|
| `grid_line` | `rows`. Neovim's cells already carry a highlight id, an optional repeat count, and empty text for the second column of a wide character, which is exactly what `rows` accepts. |
| `hl_attr_define` | `highlights.define` with the same id: `fg`, `bg`, `sp`, `bold`, `italic`, `reverse`, `strikethrough`, and the underline style (`underline`, `undercurl`, `underdouble`, `underdotted`, `underdashed`). |
| `hl_group_set` | `highlights.groups`, the group name to id map that lets Sprite's `[highlights]` table restyle by name. |
| `default_colors_set` | `defaults`. |
| `mode_info_set` | Remembered as the one piece of state: the cursor shape and blink for each mode. |
| `mode_change` | `cursor` with the shape and blink of the new mode. |
| `grid_cursor_goto` | `cursor` with the new row and column. |
| `busy_start` / `busy_stop` | `cursor` with `visible` false / true. |
| `grid_scroll` | `scroll`. |
| `grid_clear` | `clear`. |
| `grid_resize` | `resize`. |
| `flush` | Ends the batch and writes it. |
| `set_title`, `set_icon`, `bell`, `visual_bell`, `option_set`, `mouse_on`, `mouse_off`, `update_menu`, `suspend`, anything unknown | Dropped. |

The mode table is the adapter's only state, and it is a copy of what Neovim
sent, not a model of the screen.

### Sizing

Sprite decides the grid's size from the pane and its font. The adapter
attaches at the size in the first `resize` event, and every later `resize`
event becomes `nvim_ui_try_resize(cols, rows)`. Neovim answers with a
`grid_resize` that flows to Sprite as usual. The adapter never guesses a
cell size.

### Sprite to editor

| Surface event | Neovim call |
|---|---|
| `{"type":"input","key":K}` | `nvim_input` with `K` rewritten from GPUI's notation (`ctrl-shift-a`, `enter`, `escape`, `pageup`) to Neovim's angle brackets (`<C-S-a>`, `<CR>`, `<Esc>`, `<PageUp>`). The modifier letters are `C` for ctrl, `M` for alt, `S` for shift, `D` for cmd. |
| `{"type":"input","key":K,"text":T}` | `nvim_input` with `T`, and `<` in `T` sent as `<lt>`. When text is present, the key name is ignored: the text is what the keystroke produced, layout, dead keys, and input methods already applied. |
| `{"type":"mouse",...}` | `nvim_input_mouse(button, action, modifiers, 0, row, col)` with the fields passed straight through; grid 0 because the adapter does not use `ext_multigrid`. |
| `{"type":"resize",...}` | `nvim_ui_try_resize(cols, rows)`. |
| `{"type":"focus"}` / `{"type":"blur"}` | `nvim_ui_set_focus(true)` / `nvim_ui_set_focus(false)`, so `FocusGained` and `FocusLost` autocommands behave as in a terminal. |
| `{"type":"warning",...}` | Written to the log. A refused operation is an adapter bug, not something the person can act on. |
| `{"type":"refused",...}`, `{"type":"closed"}`, end of stream | The session is over (below). |

The key-name table is complete for every name GPUI produces on macOS and
Linux, and every pair is a test case.

## Two Sprite additions

Both are small changes to Sprite's existing Surface wrapper and event
writers, delivered as a TSP in the Sprite repository that cites this
document. Sprite's protocol version stays 1: both are additive fields and a
new event type that older clients ignore.

1. **Input events carry the produced text.** Today a Surface's keystroke
   event carries only the key name and modifiers (`shift-1`), while the
   terminal pane receives typed text through GPUI's input handler and types
   `!` correctly. The event becomes
   `{"type":"input","key":"shift-1","text":"!"}` whenever the keystroke
   produced text, and stays as it is when it did not (`ctrl-a`, `escape`).
   This is what makes shifted symbols, dead keys, and input methods type
   correctly into any Surface, not only the editor's.
2. **Grid Surfaces report the mouse in cells.** A grid Surface today swallows
   clicks and the wheel. It reports
   `{"type":"mouse","button":B,"action":A,"modifiers":M,"row":R,"col":C}`
   where `B` is `left`, `right`, `middle`, or `wheel`; `A` is `press`,
   `drag`, or `release` for buttons and `up`, `down`, `left`, or `right`
   for the wheel; `M` is Neovim's modifier string (`""`, `"C"`, `"S"`,
   `"C-S"`, and so on); and `R`, `C` are the cell under the pointer, clamped
   to the grid. Sprite already knows the cell size, so the adapter never
   does. One wheel event is reported per detent, or per accumulated cell of
   smooth scrolling.

Element Surfaces (box, text, list, image, button) are unchanged by the
second addition; their click reporting by button name stays as it is.

## Focus

A `fill` Surface takes the keyboard when it opens, which is what an editor
wants. Sprite's own shortcuts, such as the focus cycle and pane commands,
are intercepted before the Surface sees them, so they keep working. The
adapter never hands focus back to the terminal on its own; the terminal
behind a `fill` Surface has nothing to show.

## Lifecycle and failure

**Normal exit.** The editor process ends; the adapter closes the socket and
exits with the editor's code. Sprite closes the Surface when the connection
drops. The shell prompt returns in the same directory with `$?` intact.

**Sprite goes away first.** If the socket closes, or a `refused` or
`closed` line arrives, while the editor is running, the adapter kills the
editor process and exits. This is what happens to text-mode Neovim when a
terminal closes today; Neovim's swap files preserve unsaved work. No
attempt is made to quit the editor politely, because the alternative rule
(quit only when no buffer is modified, otherwise kill) adds a decision the
person never sees and cannot influence.

**Refusal before the editor starts.** Fail-open, as above.

**Warnings.** Logged and ignored.

**Logging.** The adapter writes to `$XDG_STATE_HOME/sprite-nvim/adapter.log`
(`~/.local/state/sprite-nvim/adapter.log` when the variable is unset):
handshake results, refusals, warnings, and exits, one line each with a
timestamp. Setting `SPRITE_NVIM_TRACE=1` additionally records every line in
both directions, for debugging a translation bug against a real session.

## Speed gate

A synthetic full repaint of 200 columns by 60 rows, delivered to the
adapter as one `grid_line` event per row followed by a `flush`, is written
to the socket as one `batch` line within **10 milliseconds** on the project
owner's machine, measured by the adapter's own test. If the Lua adapter
misses this after reasonable tuning, the fallback is a Rust port with the
same wire behaviour, and this document's tables and tests remain its
specification.

## Testing

Adapter tests run with Neovim itself, `nvim -l tests/run.lua`, with no test
framework to install. Three layers:

- **Translation tests.** Pure functions from one redraw event to one grid
  operation, and from one Surface event to one `nvim_input` string, checked
  against literal expected values. Every GPUI-to-Neovim key-name pair is a
  case, including the produced-text path and `<lt>` escaping. The mode
  table's effect on `cursor` is a case.
- **A fake Sprite.** A test listens on a Unix socket, answers the handshake
  and the open with the lines Sprite sends, emits a `resize`, and records
  what the adapter writes. The adapter runs against a real
  `nvim --embed --clean`. The test asserts that the first batch after attach
  contains the tilde-filled rows Neovim draws for an empty buffer; that an
  `input` event typed through the socket appears in the next rows; that
  closing the socket ends both processes; and that a `refused` answer to the
  open runs the real editor and returns its exit code.
- **Fail-open at the shell.** The script with the variables unset runs the
  real `nvim` and returns its exit code, verified with `nvim --version` and
  with `nvim -c 'cquit 3'`.

Sprite's two additions are covered by Rust unit tests in Sprite's channel
and wrapper modules: the input event line carries `text` when the keystroke
has one and omits it otherwise; a grid Surface turns a press at a pixel
position into the right cell, clamps positions outside the grid, and reports
a wheel detent as one event.

Continuous integration on GitHub Actions runs the adapter tests on Linux and
macOS against Neovim stable and nightly, plus `stylua --check`. The Sprite
half goes through Sprite's own CI.

**Done means** the project owner's LazyVim configuration runs in Sprite all
day: open, edit, search, use the file picker, scroll with the wheel, click
to place the cursor, drag to select, resize the pane, quit, and get the
prompt back with the exit code. That is the by-hand proof, run the same way
the Native Surfaces proofs were.

## Global constraints

- Neovim 0.11 or later runs the adapter (`vim.uv`, `vim.mpack`, `vim.json`,
  `nvim -l`, and `nvim_ui_set_focus` are all present). The embedded editor
  is the same binary, so the same floor applies.
- Sprite with the two additions above; Surface Channel protocol version 1.
- No dependencies beyond Neovim and a POSIX shell. No compiled code. No
  Rust in this repository.
- Lua formatted by `stylua`; every source file passes `stylua --check`.
- Licence: MIT or Apache-2.0, matching Sprite.
- The adapter writes nothing to the terminal's standard streams.

## Later

Recorded so they are not forgotten, and deliberately not in this release:

- `ext_multigrid`, which would let floating windows become their own
  Surfaces with shadows and rounded corners.
- Externalised popup menu, command line, and messages drawn as element
  Surfaces.
- Forwarding `set_title` to the pane's title once Sprite has one.
- Bracketed paste and drag-and-drop of files into the editor.
