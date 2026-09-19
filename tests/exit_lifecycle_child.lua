local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(root)
local sprite = require("sprite")
local session = sprite.session
local cancels, available_calls, open_codes = 0, 0, {}
session.await_ui = function(_, _)
  return function()
    cancels = cancels + 1
  end
end
sprite.available(function()
  available_calls = available_calls + 1
end)
sprite.open(
  { side = "left", width = 280, description = { version = 1, root = { kind = "virtual_list" } } },
  function(problem)
    open_codes[#open_codes + 1] = problem and problem.code
  end
)
vim.api.nvim_exec_autocmds("VimLeavePre", {})
vim.wait(50)
vim.fn.writefile({
  vim.fn.json_encode({
    cancels = cancels,
    available_calls = available_calls,
    open_codes = open_codes,
  }),
}, vim.env.SPRITE_EXIT_TEST_RESULT)
