local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
local sprite = require("sprite")
local fixture = vim.json.decode(
  table.concat(vim.fn.readfile(root .. "/tests/fixtures/surface-list-v1.json"), "\n")
)
local handle
local selected = 1
local rows = {
  { id = "first", text = "First file", indent = 0, guides = {} },
  { id = "second", text = "Second file", indent = 0, guides = {} },
}

local function report(label, err)
  if err then
    vim.notify("Sprite demo " .. label .. ": " .. err.message, vim.log.levels.ERROR)
  end
end

sprite.on_resume(function()
  vim.notify("Sprite demo resumed; run :SpriteDemo to reopen the dock")
end)

vim.api.nvim_create_user_command("SpriteDemo", function()
  if handle then
    handle:focus(function(err)
      report("focus", err)
    end)
    return
  end
  sprite.available(function(err)
    if err then
      report("discovery", err)
      return
    end
    sprite.register_tokens({
      { name = "demo.accent", default = "#61afef", description = "Demo accent" },
    }, function(token_err)
      if token_err then
        report("tokens", token_err)
        return
      end
      sprite.open({
        side = "left",
        width = 300,
        description = fixture.description,
        on_event = function(event)
          if event.type == "input" and event.key == "j" then
            selected = selected % #rows + 1
            handle:state(1, { selected = rows[selected].id }, function(err)
              report("state", err)
            end)
          elseif event.type == "input" and event.key == "e" then
            handle:focus_editor(function(err)
              report("focus editor", err)
            end)
          elseif event.type == "input" and event.key == "q" then
            handle:close()
          end
        end,
        on_close = function(reason)
          handle = nil
          vim.notify("Sprite demo closed: " .. reason.kind)
        end,
      }, function(open_err, dock)
        if open_err then
          report("open", open_err)
          return
        end
        handle = dock
        dock:assets({}, function(asset_err)
          if asset_err then
            report("assets", asset_err)
            return
          end
          dock:rows(1, rows, rows[selected].id, function(rows_err)
            if rows_err then
              report("rows", rows_err)
              return
            end
            dock:focus(function(err)
              report("focus", err)
            end)
          end)
        end)
      end)
    end)
  end)
end, {})
