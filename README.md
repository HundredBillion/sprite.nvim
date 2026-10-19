# sprite.nvim

Native Markdown providers can register with `require('sprite.markdown').setup`
using `next`, `dispatch`, `before_input`, `attached`, and `stop` callbacks.
The adapter enables them only when the host negotiates `grid-markdown-v1`.
`next` yields document/state operations; the bridge assigns revisions and
validates returned toolbar actions before dispatch. `before_input` returns
false to consume preview edits and paste, preserving ordinary command input.
Call `changed()` when a new operation is ready. Detached and older hosts keep
the normal editor grid and input behavior.
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

The API loads in any Neovim 0.11 or later. When opening a dock, call
`sprite.open(opts, callback)` directly:

```lua
local sprite = require("sprite")

sprite.open({
  side = "left",
  width = 300,
  description = description,
}, function(err, dock)
  if err then
    -- Keep using the plugin's ordinary Neovim view.
    return
  end
  -- Use the opened dock.
end)
```

`open` waits for the current UI context and checks native dock capability and
eligibility itself. A preceding `sprite.available(callback)` repeats that
discovery, so use `available` only when checking whether this editor is in an
eligible Sprite pane without opening a dock. A Sprite checkout and a special
setup function are not required for consumers.

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
`height` is optional and defaults to the host's tab height (35 pixels in Sprite).
Set it to a value from 24 to 64 to request a different height;
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

A native minimap is used only when the host advertises `grid-minimap-v1` and
an editor integration registers `require('sprite.minimap').setup(provider)`.
The provider supplies `next()`, `dispatch(event)`, `before_input(event)`, and
`stop()`. `next()` returns one source transaction or lightweight state operation,
without a revision, or nil when no work is ready. Call `changed()` when more work
is available. The bridge assigns connection revisions and rejects stale actions;
the adapter yields between source chunks and never reloads source for scrolling.

`before_input(event)` restores a preserved selection before the original input
resolves its Normal or Visual mapping, including copy, cut, and paste. The
adapter requests the hook separately from native input so continuation keys
(replace, find, mapping prefixes, and input readers) can reach a blocked editor.
During a modal wait, fast keyboard and mouse input retain Neovim's native
priority over deferred minimap/tab actions. A mode reply detects a wait; it does
not acknowledge that an earlier key has been consumed. Paste keeps Neovim's
deferred API behavior. Navigation waits for outstanding restoration hooks, so a
late hook cannot restore a selection created by newer navigation.

The hook must only resume or clear selection state created by `dispatch()`;
it must not create new saved selections or require execution during a modal
input wait.
Input keys are normalized Neovim key text; paste and mouse keep their event
types. Resize, focus, and blur use direct RPC because Neovim exposes those UI
methods only over RPC. `stop()` releases source jobs on replacement, restart, and
Surface teardown. Provider failures hide the minimap and are recorded in the
adapter log while ordinary editing and native tabs continue. Older hosts and
editors without a provider start no minimap source jobs.

The optional real-provider adapter checks run when a sibling `VSVim` checkout
is present, or when `VSVIM_SOURCE=/path/to/VSVim` names that checkout.

### Reordering native file tabs

A tab provider can opt into drag-to-reorder with a `reorder(buffer, before)`
callback in `require('sprite.tabs').setup`. `buffer` is the buffer to move;
`before` is the destination buffer, or nil to append. Return false for a rejected
or unchanged move. The provider owns the order and returns it in subsequent
snapshots. The adapter validates the revision and both stable IDs, advertises
`reorderable` only when the callback exists, and keeps the active file unchanged.
Older hosts retain their existing tab controls.

### Full-width statusline

Hosts advertising `grid-footer-v1` draw a global statusline (`laststatus=3`)
across the editor and native minimap. The adapter evaluates the existing
`statusline` option at the host's full width, retaining its highlights and
alignment. Commands, messages, and popup content can cover the statusline row.
Window-local statuslines and older hosts retain the ordinary grid presentation.

The implementation uses Neovim's
[`nvim_eval_statusline`](https://neovim.io/doc/user/api.html#nvim_eval_statusline())
with `maxwidth` and `highlights`; highlight byte offsets identify each styled
run, and stacked highlight groups are applied in priority order.
