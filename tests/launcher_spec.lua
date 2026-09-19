local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
local launcher = root .. "/bin/sprite-nvim"

-- With no Sprite credentials, the launcher runs the real nvim and returns its
-- exit code unchanged. `nvim -c 'cquit 3'` exits 3; the launcher must too.
local function run(env, args)
  local prefix = ""
  for k, v in pairs(env) do
    prefix = prefix .. string.format("%s=%q ", k, v)
  end
  -- Unset the Sprite vars for a clean baseline, then apply env.
  local cmd = string.format(
    "env -u SPRITE_SURFACE_SOCKET -u SPRITE_SURFACE_KEY -u SPRITE_PANE -u NVIM PATH=%q VIMRUNTIME=%q %s %q %s",
    vim.fn.fnamemodify(vim.v.progpath, ":h") .. ":" .. (vim.env.PATH or ""),
    vim.env.VIMRUNTIME,
    prefix,
    launcher,
    args
  )
  -- This Neovim's embedded LuaJIT returns os.execute's Lua-5.1-style single
  -- raw wait() status (exit code shifted left 8 bits), not Lua 5.2+'s
  -- (ok, "exit"/"signal", code) triple. Normalize to the 5.2 shape so
  -- `select(3, ...)` below yields the exit code either way.
  local status = os.execute(cmd)
  if type(status) == "number" then
    return true, "exit", math.floor(status / 256)
  end
  return status
end

T.eq(select(3, run({}, "--clean --headless -c 'cquit 0'")), 0, "fail-open returns nvim's exit 0")
T.eq(select(3, run({}, "--clean --headless -c 'cquit 3'")), 3, "fail-open returns nvim's exit 3")
-- NVIM set (a nested :terminal editor) also falls open.
T.eq(
  select(
    3,
    run({
      NVIM = "/tmp/x",
      SPRITE_SURFACE_SOCKET = "/tmp/s",
      SPRITE_SURFACE_KEY = "k",
      SPRITE_PANE = "1",
    }, "--clean --headless -c 'cquit 4'")
  ),
  4,
  "NVIM present falls open"
)
-- A non-editing flag falls open even with full credentials.
T.eq(
  select(
    3,
    run(
      { SPRITE_SURFACE_SOCKET = "/tmp/s", SPRITE_SURFACE_KEY = "k", SPRITE_PANE = "1" },
      "--version"
    )
  ),
  0,
  "--version falls open (prints and exits 0)"
)
