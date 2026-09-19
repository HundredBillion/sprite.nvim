local result = vim.env.SPRITE_TEST_RESULT
vim.defer_fn(function()
  local context, problem = require("sprite.session").current()
  local ui = vim.api.nvim_list_uis()[1]
  local info = ui and vim.api.nvim_get_chan_info(ui.chan)
  vim.fn.writefile({
    vim.fn.json_encode({
      editor_pid = vim.fn.getpid(),
      owner_pid = context and context.pid,
      presentation = context and context.presentation,
      problem = problem,
      ui_pid = info and info.client and info.client.attributes and info.client.attributes.pid,
    }),
  }, result)
  vim.cmd("qa!")
end, 80)
