local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(root)
local Channel = require("sprite.channel")
local names, codes = {}, {}
Channel.connect = function(opts, callback)
  names[#names + 1] = opts.first.name
  vim.schedule(function()
    callback(nil, { first_reply = { type = "registered" }, close = function() end })
  end)
  return function() end
end
local sprite = require("sprite")
sprite.session.current = function()
  return {
    path = "/tmp/unused",
    key = "secret",
    pane = 1,
    pid = vim.uv.os_getpid(),
    return_target = "terminal",
  }
end
sprite.register_tokens({
  { name = "a", default = "#111111", description = "A" },
  { name = "b", default = "#222222", description = "B" },
}, function(problem)
  codes[#codes + 1] = problem and problem.code or "ok"
end)
vim.api.nvim_exec_autocmds("VimLeavePre", {})
sprite.register_tokens({}, function(problem)
  codes[#codes + 1] = problem and problem.code or "ok"
end)
sprite.available(function(problem)
  codes[#codes + 1] = problem and problem.code or "ok"
end)
sprite.open({ side = "left", width = 280, description = {} }, function(problem)
  codes[#codes + 1] = problem and problem.code or "ok"
end)
vim.wait(50)
vim.fn.writefile(
  { vim.json.encode({ names = names, codes = codes }) },
  vim.env.SPRITE_TOKEN_EXIT_RESULT
)
