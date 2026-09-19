# Sprite Lua Plugin API Technical Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use dmi-superpowers:executing-plans to implement this TSP task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow plugins in ordinary nvim and sprite-nvim to open owned Sprite docks, display native lists, receive events, and return focus to their editor.

**Architecture:** A small public `sprite` module hides a scheduled NDJSON client and presentation/session detection. The editor adapter only adds its process-local grid identity and runtimepath bootstrap. Surface lifecycle, not editor input emulation, owns the plugin UI.

**Tech Stack:** Lua, Neovim >=0.11, vim.uv, vim.json, existing tests/run.lua; Linux and macOS.

**PRD:** `Sprite/docs/PRDs/09-18-2026-svgtree-native-explorer.md`.
**Interface authority:** `Sprite/docs/TSPs/09-18-2026-native-explorer-contract.md`.
**Prerequisite:** Sprite's `09-18-2026-plugin-surface-support.md` implementation and protocol fixture.

## Global Constraints

- Installing or loading sprite.nvim is not required for the non-Sprite terminal path.
- Native rendering must work with both ordinary nvim and sprite-nvim inside Sprite Terminal.
- Environment variables alone do not prove support.
- Run editor-facing callbacks on Neovim's scheduled execution context, not inside raw libuv callbacks.
- Initialization is asynchronous with a bounded timeout. Do not log the Surface key.
- Retain the existing adapter/launcher behavior and Linux/macOS × Neovim 0.11/stable/nightly CI matrix.
- The plugin API adds no mandatory binary, external Lua package or nightly-only API.
- Execute in an isolated worktree; run commands below from this repository root.

## File responsibilities

| File | Responsibility |
| --- | --- |
| `lua/sprite/init.lua` (new) | Public API and owned handle lifecycle |
| `lua/sprite/channel.lua` (new) | NDJSON framing, socket, bounds, timeout, serialized replies |
| `lua/sprite/session.lua` (new) | Session eligibility and editor return target |
| `lua/sprite/adapter.lua` | Capture grid id and bootstrap the actual editing process |
| `lua/sprite/input.lua` | Existing key normalization, reused by consumers |
| `tests/channel_spec.lua` (new) | Transport failure and chunking coverage |
| `tests/run.lua` | Put this checkout on runtimepath for public-module tests |
| `tests/session_spec.lua` (new) | Ordinary/adapter/nested identity coverage |
| `tests/plugin_spec.lua` (new) | Public API lifecycle and real-editor callbacks |
| `tests/fake_sprite.lua` | Strict validation and fault-injection modes |
| `tests/integration_spec.lua` | Early initialization and existing adapter regressions |
| `README.md`, `CONTEXT.md` | Public usage and concise new vocabulary |

## Task 1: Bounded scheduled Surface Channel

**Interfaces:** Internal module exports
`Channel.connect(opts, callback) -> cancel`, with
`opts={path,key,first,on_event,on_close,timeout_ms=2000}` and callback `(err,ch)`.
`ch:request(message,expected_type,callback)` serializes acknowledged messages;
`ch:send(message)` is only for final close; `ch:close(reason)` is idempotent.
Callbacks use nil or `{code,message}` errors. Channel has no knowledge of Neovim
windows, tree paths, or editor focus targets.

- [ ] Add tests using a temporary Unix socket and the existing T.eq/T.ok harness. Cover a split first reply, two replies in one read, a final unterminated line, bad JSON, refused first reply, EOF before ready, timeout, and close while a callback is pending.

Before loading specs, prepend the repository root in tests/run.lua:

```lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(root, ':h'))
```

```lua
local Channel = require('sprite.channel')
local lines = {}
local decoder = Channel.decoder(function(value) lines[#lines + 1] = value end)
assert(decoder:feed('{"type":"op'))
assert(decoder:feed('ened","surface":7}\n{"type":"focus"}\n'))
T.eq(lines, { {type='opened',surface=7}, {type='focus'} }, 'split and merged frames')
T.eq(decoder:finish(), true, 'no partial frame at EOF')
```

Define the internal pure seam `Channel.decoder(on_value, max_bytes)` with
`:feed(bytes) -> true | nil,error` and `:finish() -> true | nil,error`. This explicit
decoder seam permits framing tests without a scheduler or actual socket.

- [ ] Isolate existing integration and launcher tests from personal Neovim configuration: child editors must use `--clean`, and subprocess PATH must select the same Neovim binary/runtime as the runner. The minimum-version baseline exposed LazyVim startup and mixed nightly/stable runtime failures; do not change user config or raise the version floor to hide them.
- [ ] Run `nvim -l tests/run.lua`; observe the new specs fail before implementation.
- [ ] Implement framing with an incremental buffer, newline extraction, vim.json.decode under pcall, and a strict 16 MiB buffer/message cap. Keep the authentication key outside decoded objects and logs. Decode outside editor callbacks but schedule all public deliveries with vim.schedule; use a generation/closed guard inside the scheduled closure.

```lua
local function deliver(self, callback, ...)
  local args = { n = select('#', ...), ... }
  local generation = self.generation
  vim.schedule(function()
    if self.generation == generation and not self.closed then
      callback(unpack(args, 1, args.n))
    end
  end)
end
```

Teardown callbacks are scheduled separately after closed is set, so closing
does not suppress the required final on_close notification or error completion.
Protect consumer callbacks with pcall and report callback errors via notify;
do not kill an editor because a plugin callback threw.

- [ ] Connect with uv.new_pipe, send `key .. ' ' .. json .. '\n'`, and complete readiness only on the expected first verdict. Start a 2000-ms uv timer; cancel/close it on completion. Stop reads and close all handles on timeout/EOF/error. Test that no callback observes `vim.in_fast_event()==true`.
- [ ] Serialize requests with one in flight; bound queued bytes to 16 MiB; start a 2000-ms deadline for each request. Match applied.operation/revision when present, reject mismatched replies, and close on request timeout so later acknowledgements cannot be misattributed. Events may arrive between replies. Drain cancellations exactly once.
- [ ] Run the whole suite; commit as `feat: add a bounded asynchronous Surface Channel client`.

## Task 2: Session detection and adapter bootstrap

**Interfaces:** `Session.current() -> context | nil,error`, where context is
`{pane,path,key,pid,return_target,presentation='terminal'|'grid'}`.
`Session.bootstrap(repo, surface) -> string` produces the early Lua --cmd.
Do not cache successful ownership beyond one discovery/open sequence.
For an ordinary terminal UI, `pid` is the attached terminal UI client's
reported process ID (`nvim_get_chan_info(ui.chan).client.attributes.pid`),
provided that channel is a terminal-attached UI. Neovim may run its builtin
TUI in a parent process while the editing process has a different process
group. For an embedded grid marker, `pid` remains the marked editor process
ID. Missing or ambiguous terminal UI client PID fails closed.

- [ ] Add table-driven tests for missing environment, malformed pane, wrong-PID marker, valid grid marker, ordinary tty, no attached UI, nested NVIM, TMUX/STY, and pipe stdin. Pass an injected facts table to internal `Session.resolve(facts)`; current() supplies actual vim/uv values.
- [ ] Test a stale marker is refused instead of falling through to terminal mode. Test environment inheritance without a marker cannot choose a parent grid. With an attached terminal UI and valid tty, return_target is exactly `terminal`.
- [ ] Use existing adapter handshake verdict.surface as the grid id; retain it rather than just logging it. Add owner_pid=uv.os_getpid() to the fill open. Construct child arguments before uv.spawn:

```lua
local command = 'lua vim.opt.runtimepath:prepend(' .. vim.json.encode(repo)
  .. '); vim.g.sprite_session = {pid=vim.fn.getpid(),surface='
  .. tostring(surface) .. '}'
local args = vim.list_extend({ '--embed', '--cmd', command }, user_args)
```

`repo` is resolved from the adapter source location, as the launcher already
does. Validate surface as a positive safe integer before interpolation. This is
a direct argument array, not a shell command. No credential enters the command.

- [ ] Add real embedded-Neovim integration with an init.lua that calls require('sprite') and inspects its marker during startup, before UI attachment. Check path quoting with spaces. Reuse fake_sprite.lua to send a known Surface id; verify the child sees its own PID and that nested Neovim sees no marker.
- [ ] Handle ordinary nvim availability before UIEnter by waiting for UIEnter within the public 2000-ms initialization deadline. Missing UI after the deadline returns unavailable; it does not hang startup. Grid sessions with a validated process-local marker need not wait for terminal stdin.
- [ ] Run `nvim -l tests/run.lua`, retaining launcher symlink, refused-open fail-open, real redraw/input, and adapter hangup tests. Commit as `feat: identify plugin sessions with and without the editor adapter`.

## Task 3: Public discovery, tokens, and owned dock handles

**Interfaces:** Implement every public function and handle method in the common
contract without exposing raw socket messages or Surface ids to SVGTree.
Require all four feature flags. Error codes are `unavailable`, `unsupported`,
`refused`, `timeout`, `protocol`, `closed`, `queue_full`, and `callback`.
Handle operations after closure return error code `closed`. on_close receives
`{kind='requested'|'suspend'|'exit'|'failure',error=err_or_nil}` as defined in the
common contract; only `failure` is eligible for consumer fallback.

- [ ] Add a public API test with this consumer shape:

```lua
local sprite = require('sprite')
sprite.available(function(err, caps)
  assert(not vim.in_fast_event())
  assert(err == nil and caps.features['virtual-list-v1'])
  sprite.open({side='left',width=280,description=description,
    on_event=function(event) received[#received+1]=event end,
    on_close=function(reason) closed[#closed+1]=reason end}, function(open_err,h)
    assert(open_err == nil)
    h:assets({test=svg}, function(asset_err)
      assert(asset_err == nil)
      h:rows(1, {{id='a',text='a',indent=0}}, 'a', function(row_err)
        assert(row_err == nil)
        h:focus(function(focus_err) assert(focus_err == nil) end)
      end)
    end)
  end)
end)
```

The test defines description as the contract's empty virtual_list description,
svg as a minimal valid 16×16 SVG, and received/closed as empty arrays. Its fake
server validates the complete authenticated requests, not merely message type.

- [ ] Implement available with Session.current and a capabilities exchange; return a set-like features table to Lua. Never count a discovered socket file as support. Register tokens sequentially, close each one-shot connection, and return a token-conflict error intact.
- [ ] Implement open with focus=false, all required owned-dock fields, and side/width validation. Recheck server eligibility. If another dock occupies the side, return refused without closing that dock or retrying on the other side.
- [ ] Implement assets/rows/state with exact object/list JSON shapes, callbacks on matching applied replies, and sent-revision tracking. Preserve null using vim.NIL. Coalesce only unsent state messages for the same revision and complete all associated callbacks on the eventual acknowledgement. Do not coalesce rows with focus/close operations.
- [ ] Implement update(description,callback) using the owned Surface's applied acknowledgement. Test a changed header retains rows/assets and that a refused root-kind change keeps the previous view usable.
- [ ] Implement focus and focus_editor as one-shot requests with acknowledged focused replies. Check handle liveness before starting. Route to the handle's Surface id or the stored Session return_target. On error, return it; never silently focus terminal as a substitute for a grid.
- [ ] Implement idempotent close and exactly-once on_close. Retire callbacks, timers and all owned sockets on VimLeavePre. Close pending opens too. Test deliberate q-style close reports requested, suspension reports suspend, exit reports exit, and unexpected socket EOF reports failure/unavailable.
- [ ] Run all tests and formatter check `stylua --check bin lua tests` where installed; use the pinned project CI setup to install the formatter if needed. Commit as `feat: expose native dock lifecycle and list operations to Lua plugins`.

## Task 4: Suspension, strict protocol fixtures, and real-server checks

**Interfaces:** Lifecycle callbacks include `{type='suspend'}` before a
terminal-editor handle closes for VimSuspend, and a module-level subscription
`sprite.on_resume(callback) -> unsubscribe`. On resume consumers choose whether
to reopen. This subscription must be optional, scheduled, and removed on exit.
The common contract includes this subscription; test callback cancellation too.

- [x] Handle VimSuspend by remembering which handles were open, delivering suspend synchronously from the normal autocmd context, and closing them before job-control suspension. Never call vim.wait in a libuv callback. On VimResume emit resume once; do not restore a view the consumer intentionally closed while suspended.
- [x] Fix real-PTY adapter startup exposed by the live integration run: a top-level `uv.run()` can return while handles remain active and neither editor exit nor hangup occurred. Keep the single non-nested event loop running until a real terminal condition, preserving fail-open exit codes and hangup semantics. Add a regression that fails the premature-exit path; address the same stopped-loop assumption in the test harness rather than relying on spec filename order.
- [x] Normalize valid no-op zero-repeat Neovim redraw cells before sending them to Sprite, whose wire cells require repeat 1..1024. Add a translator regression and make the strict fake reject invalid repeats so a real-host batch refusal cannot hide behind parser-only tests.
- [x] Strengthen tests/fake_sprite.lua with exact required fields, row-id/revision checks, and empty-object validation. Keep existing adapter tests passing. Add refused capabilities and delayed acknowledgement modes; prove that the first pending request times out and a late reply cannot complete a different request.
- [x] Read Sprite's committed protocol fixture via `SPRITE_SOURCE` in a new test; fail explicitly when the integration job lacks this variable rather than reporting a pass without exercising a parser. Standalone module unit tests do not require the Sprite checkout.
- [x] Add `scripts/plugin-demo.lua` showing discovery, tokens, owned list, events, focus return and close. Run it in ordinary terminal nvim and the updated sprite-nvim in real Sprite; verify `j` sent to the dock is received only there and typing after return reaches the editor.
- [ ] Run Neovim 0.11/stable/nightly on Linux and macOS through the existing matrix, plus the required real-Sprite interactive run. An unavailable macOS machine remains an explicit acceptance gap.
- [x] Update README with an ordinary-nvim lazy.nvim installation example for the API and a launcher example. No API setup function, PATH change, mandatory consumer dependency outside Sprite, or live-config edit.
- [x] Add glossary entries for Plugin API, Editing Session and Editor Presentation in CONTEXT.md without code/config details. Commit as `test: verify plugin lifecycle across both editor presentations`.

## Self-review and hardening record

The API keeps presentation-specific focus in one place. The adapter bootstrap
is process-local, early enough for user init, and does not depend on user plugin
load order. Initialization deadlines bound startup failure. Explicit applied
replies serialize mutations and allow user callbacks only after acceptance.
Normal closure, suspension, and failure are distinct so a user cannot close the
tree only to have fallback reopen it. The transport test doubles now validate
shapes that the original fake server missed.

Plan review reconciled the resume subscription and decoder success type with
the shared contract. No API callback relies on a hidden editor window or a
global keymap.
