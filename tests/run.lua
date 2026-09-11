-- Runs every tests/*_spec.lua under `nvim -l`. A spec calls `describe`/`it`
-- from the tiny harness below; a failed assert prints and flips the exit.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
local failures = 0
local total = 0

_G.T = {
  eq = function(a, b, msg)
    total = total + 1
    if not vim.deep_equal(a, b) then
      failures = failures + 1
      print(
        string.format(
          "  FAIL %s\n    expected %s\n    got      %s",
          msg or "",
          vim.inspect(b),
          vim.inspect(a)
        )
      )
    end
  end,
  ok = function(cond, msg)
    total = total + 1
    if not cond then
      failures = failures + 1
      print("  FAIL " .. (msg or ""))
    end
  end,
}

local specs = vim.fn.glob(root .. "/*_spec.lua", false, true)
table.sort(specs)
for _, spec in ipairs(specs) do
  print(vim.fn.fnamemodify(spec, ":t"))
  dofile(spec)
end
print(string.format("\n%d checks, %d failures", total, failures))
os.exit(failures == 0 and 0 or 1)
