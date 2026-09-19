local child = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
  .. "/exit_lifecycle_child.lua"
local output = vim.fn.tempname()
local old = vim.env.SPRITE_EXIT_TEST_RESULT
vim.env.SPRITE_EXIT_TEST_RESULT = output
local transcript = vim.fn.system({ vim.v.progpath, "-l", child })
vim.env.SPRITE_EXIT_TEST_RESULT = old
T.eq(vim.v.shell_error, 0, "exit lifecycle child completed: " .. transcript:sub(-120))
local lines = vim.fn.readfile(output)
T.ok(#lines > 0, "exit lifecycle child wrote result")
if #lines > 0 then
  local result = vim.json.decode(lines[1])
  T.eq(result.cancels, 2, "exit cancels both pending availability and open waits")
  T.eq(result.available_calls, 0, "availability callback retired on exit")
  T.eq(result.open_codes, { "closed" }, "pending open closes once on exit")
end
os.remove(output)
