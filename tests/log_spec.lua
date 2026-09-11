local Log =
  dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/lua/sprite/log.lua")

-- path honours XDG_STATE_HOME, else falls back under HOME.
T.eq(Log.path({ XDG_STATE_HOME = "/x/state" }), "/x/state/sprite-nvim/adapter.log", "XDG path")
T.eq(
  Log.path({ HOME = "/home/me" }),
  "/home/me/.local/state/sprite-nvim/adapter.log",
  "HOME fallback"
)

-- a line is "<timestamp> <kind> <message>" with no newline; kind and message present.
do
  local line = Log.line("handshake", "opened surface 1")
  T.ok(not line:find("\n"), "a log line has no newline")
  T.ok(line:find(" handshake opened surface 1", 1, true) ~= nil, "kind and message appear")
end

-- tracing reads SPRITE_NVIM_TRACE.
T.eq(Log.tracing({ SPRITE_NVIM_TRACE = "1" }), true, "trace on")
T.eq(Log.tracing({}), false, "trace off by default")
