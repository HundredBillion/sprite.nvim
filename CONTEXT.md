# sprite.nvim

The Neovim-side repository of the Sprite project: the adapter that draws
Neovim through a Sprite grid Surface, and later the Lua API plugins call and
the distribution. Sprite's own vocabulary (Pane, Surface, Surface Channel,
Surface Description, Semantic Token, Surface Client) is defined in the Sprite
repository's `CONTEXT.md` and `crates/CONTEXT.md` and is used here unchanged.

## Language

**Adapter**:
The process that runs Neovim embedded, attaches as its user interface over
RPC, forwards the Redraw Stream to Sprite as grid Surface operations, and
forwards Sprite's input back to Neovim. It paints nothing and holds no picture
of the screen. One adapter per editing session.
_Avoid_: the renderer, the UI, the bridge, the plugin (unqualified)

**Plugin API**:
The public Lua interface that lets a Neovim plugin discover Sprite and own a
native dock alongside its editor. It reports availability and accepts the
plugin's content and event callbacks.
_Avoid_: the Adapter, the renderer

**Editing Session**:
One editor and its associated Sprite surfaces for the time that editor is
running. A nested editor starts a separate session.
_Avoid_: window, buffer, process (unqualified)

**Editor Presentation**:
The place where the person sees and controls the editor: an ordinary terminal
or a Sprite grid Surface. A plugin can use the same API in either presentation.
_Avoid_: mode, backend

**Launcher**:
The command a person runs in place of `nvim`. Outside Sprite it becomes plain
Neovim; inside Sprite it becomes the Adapter. It takes exactly Neovim's
arguments.
_Avoid_: wrapper, shim, the script (unqualified)

**Fail-open**:
The rule that when Sprite cannot be used, the person gets plain Neovim in
text mode rather than an error: no Surface Channel in the environment, a
refused handshake, or a connection lost before the editor starts.
_Avoid_: fallback mode, degraded mode, compatibility mode

**Redraw Stream**:
The sequence of `redraw` notifications Neovim sends an attached UI under
`ext_linegrid`: `grid_line`, `hl_attr_define`, `grid_cursor_goto`,
`mode_change`, `flush`, and the rest. Neovim's complete description of its
screen, keystroke by keystroke.
_Avoid_: the UI events, screen updates, the diff

**Frame**:
Everything in the Redraw Stream between one `flush` and the next, sent to
Sprite as one `batch` so it is painted in one step.
_Avoid_: tick, update (unqualified), transaction

**Mode Table**:
The cursor shape and blink for each of Neovim's modes, as sent by
`mode_info_set`. The Adapter's only remembered state, and a copy of what
Neovim sent rather than a model of the screen.
_Avoid_: cursor state, mode cache

**Produced Text**:
The character a single key press typed, with the keyboard layout applied:
`!` for shift-1 on a US keyboard. Carried on a Surface key event as `text`.
_Avoid_: key char, the character (unqualified), the glyph

**Composed Text**:
Text that arrives after a composition rather than from one key press: a dead
key sequence (option-e then e gives é) or an input method commit. Carried on
a Surface input event as `text` with no key.
_Avoid_: IME text, preedit (for the committed result), marked text (for the
committed result)
