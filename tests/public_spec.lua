local uv = vim.uv
local sprite = require("sprite")
local Session = sprite.session
local fixture = vim.json.decode(
  table.concat(vim.fn.readfile("../native-explorer/tests/fixtures/surface-list-v1.json"), "\n")
)
local original_await = Session.await_ui
local path = vim.fn.tempname()
local key = "public-test-key"
local context = {
  pane = 0,
  path = path,
  key = key,
  pid = uv.os_getpid(),
  return_target = "terminal",
  presentation = "terminal",
}

local function server(responder)
  os.remove(path)
  local listener = uv.new_pipe(false)
  listener:bind(path)
  local clients = {}
  local requests = {}
  listener:listen(32, function()
    local client = uv.new_pipe(false)
    listener:accept(client)
    clients[#clients + 1] = client
    local buffer = ""
    local first = true
    client:read_start(function(e, bytes)
      if e or not bytes then
        return
      end
      buffer = buffer .. bytes
      while true do
        local nl = buffer:find("\n", 1, true)
        if not nl then
          break
        end
        local line = buffer:sub(1, nl - 1)
        buffer = buffer:sub(nl + 1)
        local document = line
        if first then
          local secret
          secret, document = line:match("^([^ ]+) (.+)$")
          T.eq(secret, key, "authenticated first request")
          first = false
        else
          T.ok(line:sub(1, 1) == "{", "later requests are raw JSON")
        end
        local message = vim.json.decode(document)
        requests[#requests + 1] = { message = message, line = document }
        local response = responder(message, client)
        if response then
          client:write(
            (type(response) == "string" and response or vim.json.encode(response)) .. "\n"
          )
        end
      end
    end)
  end)
  return requests,
    function()
      for _, client in ipairs(clients) do
        if not client:is_closing() then
          client:close()
        end
      end
      listener:close()
      os.remove(path)
    end
end

local function with_context(run)
  Session.await_ui = function(_, cb)
    vim.schedule(function()
      cb(nil, context)
    end)
    return function() end
  end
  run()
end

local function wait_for(condition)
  T.ok(vim.wait(2000, condition, 10), "public API completed")
end

local function describe(name, fn)
  print(name)
  fn()
end

describe("sprite public API", function()
  local closed, received = {}, {}
  local description = fixture.description
  local svg = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"></svg>'
  local requests, stop = server(function(message)
    if message.type == "capabilities" then
      T.eq(message, {
        type = "capabilities",
        version = 1,
        pane = context.pane,
        owner_pid = context.pid,
        return_target = "terminal",
      }, "complete discovery")
      return fixture.capabilities.reply
    end
    if message.type == "open" then
      T.eq(message, {
        type = "open",
        version = 1,
        pane = context.pane,
        position = "dock",
        side = "left",
        size = 280,
        focus = false,
        description = description,
        owner_pid = context.pid,
        return_target = "terminal",
        resizable = true,
      }, "complete owned open")
      return { type = "opened", surface = 357 }
    end
    if message.type == "assets" then
      T.eq(message, { type = "assets", entries = { test = svg } }, "assets request")
      return { type = "applied", operation = "assets" }
    end
    if message.type == "list_rows" then
      T.eq(message, {
        type = "list_rows",
        revision = 1,
        rows = { { id = "a", text = "a", indent = 0 } },
        selected = "a",
      }, "rows request")
      return { type = "applied", operation = "list_rows", revision = 1 }
    end
    if message.type == "focus" then
      T.eq(message, { type = "focus", pane = context.pane, target = 357 }, "focus request")
      return { type = "focused" }
    end
  end)
  local finished = false
  with_context(function()
    sprite.available(function(e, caps)
      T.ok(not vim.in_fast_event(), "discovery callback scheduled")
      T.eq(e, nil, "discovery error")
      T.ok(caps.features["virtual-list-v1"], "virtual list support")
      sprite.open({
        side = "left",
        width = 280,
        description = description,
        on_event = function(event)
          received[#received + 1] = event
        end,
        on_close = function(reason)
          closed[#closed + 1] = reason
        end,
      }, function(open_err, h)
        T.eq(open_err, nil, "open error")
        T.eq(h.surface, nil, "Surface id hidden from consumer")
        h:assets({ test = svg }, function(asset_err)
          T.eq(asset_err, nil, "asset error")
          h:rows(1, { { id = "a", text = "a", indent = 0 } }, "a", function(row_err)
            T.eq(row_err, nil, "row error")
            h:focus(function(focus_err)
              T.eq(focus_err, nil, "focus error")
              h:close()
              h:close()
              finished = true
            end)
          end)
        end)
      end)
    end)
  end)
  wait_for(function()
    return finished and #closed == 1
  end)
  T.eq(closed[1].kind, "requested", "requested close once")
  T.eq(#received, 0, "no spurious events")
  T.ok(#requests >= 5, "all requests observed")
  stop()
  Session.await_ui = original_await
end)

describe("sprite wire shapes and large ids", function()
  local surface = 9007199254740991
  local state_count = 0
  local saw = {}
  local requests, stop = server(function(message)
    saw[#saw + 1] = message.type
    if message.type == "capabilities" then
      return fixture.capabilities.reply
    end
    if message.type == "open" then
      return '{"type":"opened","surface":9007199254740991}'
    end
    if message.type == "assets" then
      return { type = "applied", operation = "assets" }
    end
    if message.type == "list_rows" then
      return '{"type":"applied","operation":"list_rows","revision":9007199254740991}'
    end
    if message.type == "list_state" then
      T.eq(message.selected, vim.NIL, "JSON null retained")
      return '{"type":"applied","operation":"list_state","revision":9007199254740991}'
    end
    if message.type == "update" then
      return { type = "applied", operation = "update" }
    end
    if message.type == "focus" then
      return { type = "focused" }
    end
  end)
  local done = false
  with_context(function()
    sprite.open({ side = "right", width = 300, description = fixture.description }, function(e, h)
      T.eq(e, nil, "large-id open")
      h:assets({}, function(asset_err)
        T.eq(asset_err, nil, "empty asset object")
        h:rows(surface, {}, nil, function(rows_err)
          T.eq(rows_err, nil, "empty rows")
          h:state(surface, { selected = vim.NIL }, function(state_err)
            T.eq(state_err, nil, "null state")
            local changed = vim.deepcopy(fixture.description)
            changed.root.heading.text = "CHANGED"
            h:update(changed, function(update_err)
              T.eq(update_err, nil, "header update")
              h:focus(function(focus_err)
                T.eq(focus_err, nil, "large Surface focus")
                h:close()
                done = true
              end)
            end)
          end)
        end)
      end)
    end)
  end)
  wait_for(function()
    return done
  end)
  local asset, rows, state, focus
  for _, entry in ipairs(requests) do
    if entry.message.type == "assets" then
      asset = entry
    end
    if entry.message.type == "list_rows" then
      rows = entry
    end
    if entry.message.type == "list_state" then
      state = entry
    end
    if entry.message.type == "focus" then
      focus = entry
    end
  end
  T.ok(
    asset.line:find('"entries": {}', 1, true) ~= nil
      or asset.line:find('"entries":{}', 1, true) ~= nil,
    "empty assets encode as object"
  )
  T.ok(
    rows.line:find('"rows": []', 1, true) ~= nil or rows.line:find('"rows":[]', 1, true) ~= nil,
    "empty rows encode as array"
  )
  T.ok(rows.line:find("9007199254740991", 1, true) ~= nil, "large revision exact on wire")
  T.ok(
    state.line:find('"selected": null', 1, true) ~= nil
      or state.line:find('"selected":null', 1, true) ~= nil,
    "null exact on wire"
  )
  T.ok(focus.line:find("9007199254740991", 1, true) ~= nil, "large Surface exact on wire")
  T.eq(state_count, 0, "no extra state callbacks")
  stop()
  Session.await_ui = original_await
end)

describe("queued state patches", function()
  local state_requests, completions = {}, 0
  local requests, stop = server(function(message, client)
    if message.type == "capabilities" then
      return fixture.capabilities.reply
    end
    if message.type == "open" then
      return { type = "opened", surface = 12 }
    end
    if message.type == "assets" then
      vim.defer_fn(function()
        if not client:is_closing() then
          client:write('{"type":"applied","operation":"assets"}\n')
        end
      end, 30)
      return
    end
    if message.type == "list_state" then
      state_requests[#state_requests + 1] = message
      return { type = "applied", operation = "list_state", revision = 1 }
    end
  end)
  local done = false
  with_context(function()
    sprite.open({ side = "left", width = 280, description = fixture.description }, function(e, h)
      T.eq(e, nil, "coalesce open")
      h:assets({}, function(asset_err)
        T.eq(asset_err, nil, "blocking asset acknowledgement")
      end)
      h:state(1, { reveal = "a", status = "before" }, function(state_err)
        T.eq(state_err, nil, "first coalesced callback")
        completions = completions + 1
      end)
      h:state(1, { scroll = { id = "b", offset = 2 }, status = vim.NIL }, function(state_err)
        T.eq(state_err, nil, "second coalesced callback")
        completions = completions + 1
        h:close()
        done = true
      end)
    end)
  end)
  wait_for(function()
    return done and completions == 2
  end)
  T.eq(#state_requests, 1, "one coalesced wire request")
  T.eq(
    state_requests[1],
    { type = "list_state", revision = 1, scroll = { id = "b", offset = 2 }, status = vim.NIL },
    "last state patch wins"
  )
  T.ok(#requests >= 4, "discovery, open, asset, state")
  stop()
  Session.await_ui = original_await
end)

describe("owned handle lifecycle", function()
  local events, reasons = {}, {}
  local requests, stop = server(function(message)
    if message.type == "capabilities" then
      return fixture.capabilities.reply
    end
    if message.type == "open" then
      return { type = "opened", surface = 23 }
    end
    if message.type == "update" then
      return { type = "refused", reason = "root kind cannot change" }
    end
    if message.type == "assets" then
      return { type = "applied", operation = "assets" }
    end
    if message.type == "focus" then
      return { type = "focused" }
    end
  end)
  local done = false
  with_context(function()
    sprite.open({
      side = "left",
      width = 280,
      description = fixture.description,
      on_event = function(event)
        events[#events + 1] = event
      end,
      on_close = function(reason)
        reasons[#reasons + 1] = reason
      end,
    }, function(e, h)
      T.eq(e, nil, "lifecycle open")
      h:update({ version = 1, root = { kind = "grid" } }, function(update_err)
        T.eq(update_err.code, "refused", "refused update retained")
        h:assets({}, function(asset_err)
          T.eq(asset_err, nil, "view usable after refused update")
          h:focus_editor(function(focus_err)
            T.eq(focus_err, nil, "editor focus")
            vim.api.nvim_exec_autocmds("VimSuspend", {})
            done = true
          end)
        end)
      end)
    end)
  end)
  wait_for(function()
    return done and #reasons == 1
  end)
  T.eq(events[#events].type, "suspend", "suspend delivered to consumer")
  T.eq(reasons[1].kind, "suspend", "suspend close reason")
  T.eq(requests[#requests].message.target, "terminal", "focus return target")
  stop()
  Session.await_ui = original_await
end)

describe("unexpected owned socket EOF", function()
  local reasons = {}
  local _, stop = server(function(message, client)
    if message.type == "capabilities" then
      return fixture.capabilities.reply
    end
    if message.type == "open" then
      vim.defer_fn(function()
        if not client:is_closing() then
          client:close()
        end
      end, 30)
      return { type = "opened", surface = 31 }
    end
  end)
  with_context(function()
    sprite.open({
      side = "right",
      width = 280,
      description = fixture.description,
      on_close = function(reason)
        reasons[#reasons + 1] = reason
      end,
    }, function(e, h)
      T.eq(e, nil, "EOF open")
      T.ok(h ~= nil, "EOF handle opened")
    end)
  end)
  wait_for(function()
    return #reasons == 1
  end)
  T.eq(reasons[1].kind, "failure", "unexpected EOF is failure")
  T.eq(reasons[1].error.code, "unavailable", "unexpected EOF code")
  stop()
  Session.await_ui = original_await
end)
