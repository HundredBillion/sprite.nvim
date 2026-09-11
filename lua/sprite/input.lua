-- Pure translation of Surface events into Neovim RPC call descriptions. No I/O:
-- the adapter performs the call. The key-name table is the whole GPUI->Neovim
-- vocabulary; a name outside it, with no accompanying text, is dropped.
local Input = {}

-- GPUI modifier -> Neovim letter.
local MOD = { ctrl = "C", alt = "M", shift = "S", cmd = "D" }

-- GPUI base-key name -> Neovim base-key name (angle-bracket names without the
-- brackets). A single printable character maps to itself and is not listed.
local NAMED = {
  enter = "CR",
  escape = "Esc",
  tab = "Tab",
  backspace = "BS",
  delete = "Del",
  space = "Space",
  up = "Up",
  down = "Down",
  left = "Left",
  right = "Right",
  home = "Home",
  ["end"] = "End",
  pageup = "PageUp",
  pagedown = "PageDown",
  insert = "Insert",
}

local function base_name(key)
  if NAMED[key] then
    return NAMED[key]
  end
  if key == "<" then
    return "lt"
  end
  if key:match("^f%d+$") then
    return "F" .. key:sub(2)
  end
  -- A single character (any case) types itself.
  if vim.fn.strchars(key) == 1 then
    return key
  end
  return nil
end

-- "ctrl-shift-a" -> "<C-S-a>"; "a" -> "a"; unknown -> nil.
function Input.key(name)
  local mods = {}
  local rest = name
  while true do
    local mod, tail = rest:match("^([a-z]+)%-(.+)$")
    if mod and MOD[mod] then
      mods[#mods + 1] = MOD[mod]
      rest = tail
    else
      break
    end
  end
  local base = base_name(rest)
  if not base then
    return nil
  end
  if #mods == 0 and vim.fn.strchars(base) == 1 and base ~= "lt" then
    -- A bare printable key needs no brackets, but < did (handled as lt above).
    return base
  end
  return "<" .. table.concat(mods, "-") .. (#mods > 0 and "-" or "") .. base .. ">"
end

local function input_call(event)
  -- Real typed text wins over the key name -- it has the layout, dead keys, and
  -- input methods already applied. But GPUI reports Enter as the text "\n" and
  -- Tab as "\t"; sending those verbatim types Ctrl-J / Ctrl-I and kills every
  -- <CR>/<Tab> mapping. So text is used only when it has no control character;
  -- a control-bearing text falls through to the key path, which maps
  -- enter -> <CR> and tab -> <Tab> (and keeps modifiers, e.g. <C-CR>).
  if event.text ~= nil and not event.text:find("%c") then
    return { method = "nvim_input", args = { (event.text:gsub("<", "<lt>")) } }
  end
  local key = event.key and Input.key(event.key)
  if not key then
    return nil
  end
  return { method = "nvim_input", args = { key } }
end

function Input.call(event)
  local t = event.type
  if t == "input" then
    return input_call(event)
  elseif t == "mouse" then
    return {
      method = "nvim_input_mouse",
      args = { event.button, event.action, event.modifiers, 0, event.row, event.col },
    }
  elseif t == "paste" then
    return { method = "nvim_paste", args = { event.text, true, -1 } }
  elseif t == "resize" then
    return { method = "nvim_ui_try_resize", args = { event.cols, event.rows } }
  elseif t == "focus" then
    return { method = "nvim_ui_set_focus", args = { true } }
  elseif t == "blur" then
    return { method = "nvim_ui_set_focus", args = { false } }
  end
  return nil
end

return Input
