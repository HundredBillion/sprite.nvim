# sprite.nvim
Neovim plugin that draws Neovim through Sprite's native Surfaces

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

## Plugin API

A `virtual_list` Surface description may set `root.border_side` to `all`,
`left`, `right`, or `none`. If omitted, the host draws all four border edges.
For an Explorer dock, use `right` when docked left and `left` when docked right
to draw only the editor-facing separator. Other values are refused.

Install the Lua API in ordinary Neovim with lazy.nvim:

```lua
{
  "HundredBillion/sprite.nvim",
  lazy = false,
}
```

The API loads in any Neovim 0.11 or later. `require("sprite").available(callback)`
reports whether this editor is in an eligible Sprite pane; plugins can use
their ordinary Neovim view when it is unavailable. A Sprite checkout and a
special setup function are not required for consumers.

To launch the editor through Sprite's grid presentation from this checkout, run:

```sh
./bin/sprite-nvim README.md
```

See [scripts/plugin-demo.lua](scripts/plugin-demo.lua) for a runnable API
example. Start Neovim with `-u scripts/plugin-demo.lua`, then run `:SpriteDemo`.
In the dock, `j` changes the selected row, `e` returns focus to the editor,
and `q` closes the dock. After a terminal editor resumes from suspension,
run `:SpriteDemo` to open it again.

The standalone test suite runs with `nvim -l tests/run.lua`. Run
`SPRITE_BENCHMARK=1 nvim -l tests/run.lua` on a quiet machine to also enforce
the 10 ms repaint performance budget after warmup. CI checks repaint contents
without a wall-clock limit because shared runner scheduling varies. To check this
plugin against Sprite's committed protocol fixture from a local Sprite
checkout, run `SPRITE_SOURCE=/path/to/Sprite sh scripts/test-protocol.sh`.
The protocol integration command requires `SPRITE_SOURCE` and exits with an
error if it is missing.

Native file tabs are enabled automatically when the grid host advertises
`grid-tabs-v1`. Older Sprite versions and ordinary terminals retain Neovim's
normal tabline. The native strip is 35 pixels tall and supports file selection,
close actions, modified markers, and optional inline SVG icons.

Distros can configure `require('sprite.tabs').setup` with `snapshot`, `select`,
and `close` callbacks. `snapshot()` returns `{ items, active, height, colors }`;
each item has a Neovim `buffer` number, `label`, `modified`, and optional SVG
source in `icon`. `active` is a buffer number. `select(buffer)` and
`close(buffer)` run inside Neovim; the distro should preserve unsaved work when
closing. The bridge assigns IDs/revisions, rejects stale clicks, limits visible
items to 256 around the active buffer, bounds icon payloads, and coalesces
unchanged updates. A provider error restores the ordinary tabline.

On Sprite builds with definition-pointer support, holding Cmd/Super over a
highlighted function or method shows a pointing hand. The adapter requests
Neovim's highlight metadata and forwards an optional `definition` hint on the
highlight attributes. Older hosts ignore this hint. The hint indicates a
navigation action; the language server still resolves the destination on click.
