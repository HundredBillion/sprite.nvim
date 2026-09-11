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
