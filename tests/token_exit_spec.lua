local child = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
  .. "/token_exit_child.lua"
local output = vim.fn.tempname()
local old = vim.env.SPRITE_TOKEN_EXIT_RESULT
vim.env.SPRITE_TOKEN_EXIT_RESULT = output
local transcript = vim.fn.system({ vim.v.progpath, "-l", child })
vim.env.SPRITE_TOKEN_EXIT_RESULT = old
T.eq(vim.v.shell_error, 0, "token exit child completed: " .. transcript:sub(-120))
local result = vim.json.decode(table.concat(vim.fn.readfile(output), "\n"))
T.eq(result.names, { "a" }, "accepted token reply cannot open another socket after exit")
T.eq(
  result.codes,
  { "closed", "closed", "closed", "closed" },
  "chain and new API requests close once"
)
os.remove(output)
