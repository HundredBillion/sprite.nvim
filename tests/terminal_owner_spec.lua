local child = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
  .. "/terminal_owner_child.lua"
local output = vim.fn.tempname()
local command = "stty rows 24 cols 80; exec env -u NVIM -u TMUX -u STY TERM=xterm-256color SPRITE_PANE=0 SPRITE_SURFACE_SOCKET=/tmp/sprite-test.sock SPRITE_SURFACE_KEY=secret SPRITE_TEST_RESULT="
  .. vim.fn.shellescape(output)
  .. " "
  .. vim.fn.shellescape(vim.v.progpath)
  .. " --clean -c "
  .. vim.fn.shellescape("set rtp^=" .. vim.fn.fnamemodify(child, ":h:h"))
  .. " -c "
  .. vim.fn.shellescape("luafile " .. child)
local script_args = vim.uv.os_uname().sysname == "Darwin"
    and { "script", "-q", "/dev/null", "sh", "-c", command }
  or { "script", "-q", "-e", "-c", command, "/dev/null" }
local transcript = vim.fn.system(script_args)
T.eq(vim.v.shell_error, 0, "ordinary TUI child exited cleanly: " .. transcript:sub(-120))
local lines = vim.fn.filereadable(output) == 1 and vim.fn.readfile(output) or {}
T.ok(#lines > 0, "ordinary TUI child wrote ownership facts")
if #lines > 0 then
  local facts = vim.json.decode(lines[1])
  T.eq(facts.problem, nil, "ordinary TUI ownership resolved")
  T.eq(facts.presentation, "terminal", "ordinary TUI presentation")
  T.eq(facts.owner_pid, facts.ui_pid, "owner is attached UI client")
  T.ok(facts.owner_pid ~= facts.editor_pid, "owner differs from editor child PID")
end
os.remove(output)
