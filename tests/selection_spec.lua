local Selection = require("avante.selection")
local Config = require("avante.config")
local Llm = require("avante.llm")
local Provider = require("avante.providers")
local Morph = require("avante.morph")
local EditTrace = require("avante.edit_trace")
local Utils = require("avante.utils")
local Diff = require("avante.selection_diff_highlight")
local PendingEdits = require("avante.pending_edits")

local api = vim.api

describe("selection edit highlighting", function()
  local originals, bufnr, selection, stream, timers
  local old_line = "local value = old_name"
  local new_line = "local value = new_name"

  local function lines() return api.nvim_buf_get_lines(bufnr, 0, -1, false) end

  local function marks(namespace) return api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true }) end

  local function select_range(content, first, last, start_col, finish_col)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
    selection.selection.content = table.concat(vim.list_slice(content, first, last), "\n")
    selection.selection.range = {
      start = { lnum = first, col = start_col or 1 },
      finish = { lnum = last, col = finish_col or #content[last] },
    }
  end

  before_each(function()
    originals = {
      stream = Llm.stream,
      get_config = Provider.get_config,
      morph_provider = rawget(Provider, "morph"),
      morph_apply = Morph.apply,
      trace = EditTrace.last,
      diagnostics = Utils.lsp.get_current_selection_diagnostics,
      options = Config._options,
      defer_fn = vim.defer_fn,
    }
    timers = {}
    Config._options = vim.deepcopy(Config._defaults)
    vim.defer_fn = function(callback, timeout) timers[#timers + 1] = { callback = callback, timeout = timeout } end
    Config.selection.fastapply = false
    Config.selection.diff_highlight_instant = true
    Config.selection.diff_highlight_timeout_ms = 100
    Config.selection.diff_highlight_added_timeout_ms = 500
    Provider.get_config = function() return { edit_stream_flush_interval_ms = 0 } end
    rawset(Provider, "morph", { is_env_set = function() return true end })
    Utils.lsp.get_current_selection_diagnostics = function() return {} end
    Llm.stream = function(opts) stream = opts end
    Morph.apply = function(_, _, _, callback) callback(new_line) end
    bufnr = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, { old_line })
    vim.bo[bufnr].filetype = "lua"
    selection = setmetatable({
      code_bufnr = bufnr,
      selection = {
        content = old_line,
        filetype = "lua",
        filepath = "example.lua",
        range = { start = { lnum = 1, col = 1 }, finish = { lnum = 1, col = #old_line } },
      },
      close_editing_input = function(self) self.closed = true end,
    }, Selection)
  end)

  after_each(function()
    Llm.stream = originals.stream
    Provider.get_config = originals.get_config
    rawset(Provider, "morph", originals.morph_provider)
    Morph.apply = originals.morph_apply
    EditTrace.last = originals.trace
    Utils.lsp.get_current_selection_diagnostics = originals.diagnostics
    Config._options = originals.options
    vim.defer_fn = originals.defer_fn
    Diff.clear(bufnr)
    PendingEdits.dismiss_all(bufnr)
    api.nvim_buf_delete(bufnr, { force = true })
  end)

  it("preserves the selection while the opening code tag streams", function()
    selection:submit_input("rename the value")
    stream.on_chunk("<co")
    assert.are.same({ old_line }, lines())
    stream.on_chunk("de>\n")
    assert.are.same({ old_line }, lines())
    stream.on_chunk(new_line .. "\n</code>")
    assert.are.same({ new_line }, lines())
    stream.on_stop({})
    assert.equals(1, #marks(Diff._namespace))
    assert.equals(1, #marks(Diff._delete_namespace))
  end)

  it("marks the selected position in both contexts of the auto-applying editor", function()
    Config.selection.fastapply = true
    select_range({ "before", old_line, "after" }, 2, 2, 15, 22)
    selection:submit_input("rename the value")
    local marked = "local value = <selection>old_name</selection>"
    assert.is_truthy(stream.selected_files[1].content:find(marked, 1, true))
    assert.is_truthy(stream.instructions:find(marked, 1, true))
    assert.equals("old_name", stream.selected_code.content)
  end)

  it("previews the validated selection even when automatic fastapply is off", function()
    selection:submit_input("rename the value", { review = true })
    assert.equals("editing_regen", stream.mode)
    stream.tools[1].func({ code = new_line }, { on_complete = function() end })
    assert.are.same({ old_line }, lines())
    assert.is_true(PendingEdits.has_pending(bufnr))
    PendingEdits.accept_all(bufnr)
    assert.are.same({ new_line }, lines())
  end)

  it("does not turn a prose answer in review mode into an edit", function()
    Morph.apply = function() error("answers must not be applied as code") end
    local result
    selection:submit_input("what does this do?", { review = true, on_done = function(value) result = value end })
    assert.is_true(stream.selection_review)
    stream.on_chunk("It initializes a local variable.")
    stream.on_stop({})
    assert.is_false(result.applied)
    assert.equals("It initializes a local variable.", result.text)
    assert.is_false(PendingEdits.has_pending(bufnr))
    assert.are.same({ old_line }, lines())
  end)

  it("keeps partial-line boundaries unchanged through review and acceptance", function()
    local before = "local value = old_name + keep"
    local after = "local value = new_name + keep"
    select_range({ "prefix", before, "suffix" }, 2, 2, 15, 22)
    Morph.apply = function(_, _, _, callback) callback("prefix\n" .. after .. "\nsuffix") end
    selection:submit_input("rename this", { review = true })
    assert.equals("old_name", stream.selected_code.content)
    assert.is_truthy(stream.instructions:find("<selection>old_name</selection>", 1, true))
    stream.tools[1].func({ code = "prefix\n" .. after .. "\nsuffix" }, { on_complete = function() end })
    assert.are.same({ "prefix", before, "suffix" }, lines())
    PendingEdits.accept_all(bufnr)
    assert.are.same({ "prefix", after, "suffix" }, lines())
  end)

  it("changes only the selected occurrence of duplicate text", function()
    select_range({ old_line, old_line }, 2, 2)
    Morph.apply = function(_, _, _, callback) callback(old_line .. "\n" .. new_line) end
    selection:submit_input("rename this", { review = true })
    stream.tools[1].func({ code = old_line .. "\n" .. new_line }, { on_complete = function() end })
    assert.are.same({ old_line, old_line }, lines())
    PendingEdits.accept_all(bufnr)
    assert.are.same({ old_line, new_line }, lines())
  end)

  it("preserves unselected columns when a selection expands to multiple lines", function()
    local before = "call(old_name, keep)"
    local after = { "call(first,", "second, keep)" }
    select_range({ "before", before, "after" }, 2, 2, 6, 13)
    Morph.apply = function(_, _, _, callback) callback("before\n" .. table.concat(after, "\n") .. "\nafter") end
    selection:submit_input("expand this", { review = true })
    stream.tools[1].func({ code = table.concat(after, "\n") }, { on_complete = function() end })
    assert.are.same({ "before", before, "after" }, lines())
    PendingEdits.accept_all(bufnr)
    assert.are.same({ "before", after[1], after[2], "after" }, lines())
  end)

  it("rejects changes before the selected columns and limits retries", function()
    select_range({ old_line }, 1, 1, 15, 22)
    Morph.apply = function(_, _, _, callback) callback("local changed = new_name") end
    selection:submit_input("rename this", { review = true })
    local errors = {}
    for _ = 1, 3 do
      stream.tools[1].func({ code = "local changed = new_name" }, {
        on_complete = function(_, err) errors[#errors + 1] = err end,
      })
    end
    assert.equals(3, #errors)
    assert.is_truthy(errors[1]:find("REJECTED", 1, true))
    assert.equals("__CANCELLED__", errors[3])
    assert.is_false(PendingEdits.has_pending(bufnr))
    assert.are.same({ old_line }, lines())
  end)

  it("preserves exact unselected suffix whitespace", function()
    select_range({ old_line .. "  " }, 1, 1, 15, 22)
    Morph.apply = function(_, _, _, callback) callback(new_line) end
    selection:submit_input("rename this", { review = true })
    local err
    stream.tools[1].func({ code = new_line }, { on_complete = function(_, value) err = value end })
    assert.is_truthy(err:find("REJECTED", 1, true))
    assert.is_false(PendingEdits.has_pending(bufnr))
    assert.are.same({ old_line .. "  " }, lines())
  end)

  it("drops a response after the buffer changes", function()
    local complete
    Morph.apply = function(_, _, _, callback) complete = callback end
    selection:submit_input("rename this", { review = true })
    stream.tools[1].func({ code = new_line }, { on_complete = function() end })
    api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local manual = 2" })
    complete(new_line)
    assert.is_false(PendingEdits.has_pending(bufnr))
    assert.are.same({ "local manual = 2" }, lines())
  end)

  it("does not widen a blockwise selection into whole lines for review", function()
    selection.selection.visual_mode = "\22"
    stream = nil
    selection:submit_input("rename this", { review = true })
    assert.is_nil(stream)
    assert.is_false(PendingEdits.has_pending(bufnr))
  end)

  it("rejects a selection whose captured text is stale", function()
    api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local manual = 2" })
    stream = nil
    selection:submit_input("rename this", { review = true })
    assert.is_nil(stream)
    assert.are.same({ "local manual = 2" }, lines())
  end)

  it("preserves the selection when the response contains no code block", function()
    selection:submit_input("rename the value")
    stream.on_chunk("There is no replacement code.")
    stream.on_stop({})
    assert.are.same({ old_line }, lines())
    assert.equals(0, #marks(Diff._namespace))
    assert.equals(0, #marks(Diff._delete_namespace))
  end)

  it("preserves the selection when an opening code tag is never completed", function()
    selection:submit_input("rename the value")
    stream.on_chunk("<code>\n")
    stream.on_stop({})
    assert.are.same({ old_line }, lines())
  end)

  it("keeps unselected boundary text when an empty block deletes a partial selection", function()
    selection.selection.range.start.col = #"local value = " + 1
    selection:submit_input("remove the selected name")
    stream.on_chunk("<code></code>")
    assert.are.same({ old_line }, lines())
    stream.on_stop({})
    assert.are.same({ "local value = " }, lines())
  end)

  it("waits for the deletion flash when instant mode is disabled for streaming edits", function()
    Config.selection.diff_highlight_instant = false
    selection:submit_input("rename the value")
    stream.on_chunk("<code>" .. new_line .. "</code>")
    stream.on_stop({})
    assert.are.same({ old_line }, lines())
    assert.is_nil(selection.closed)
    assert.equals(1, #marks(Diff._delete_namespace))
    assert.equals(100, timers[1].timeout)
    timers[1].callback()
    assert.are.same({ new_line }, lines())
    assert.equals(0, #marks(Diff._delete_namespace))
    assert.equals(1, #marks(Diff._namespace))
  end)

  for _, instant in ipairs({ true, false }) do
    it("honors instant mode " .. tostring(instant) .. " for Morph edits", function()
      Config.selection.diff_highlight_instant = instant
      Config.selection.fastapply = true
      selection:submit_input("rename the value")
      stream.tools[1].func({ code = new_line }, { on_complete = function() end })
      if instant then
        assert.are.same({ new_line }, lines())
        assert.equals(1, #marks(Diff._namespace))
        assert.are.same({ { "old", "AvanteSelectionDiffDelete" } }, marks(Diff._delete_namespace)[1][4].virt_text)
      else
        assert.are.same({ old_line }, lines())
        assert.equals(0, #marks(Diff._namespace))
        timers[1].callback()
        assert.are.same({ new_line }, lines())
        assert.equals(0, #marks(Diff._delete_namespace))
        assert.equals(1, #marks(Diff._namespace))
      end
    end)

    it("allows disabling all highlights in instant mode " .. tostring(instant), function()
      Config.selection.diff_highlight_instant = instant
      Config.selection.diff_highlight_timeout_ms = 0
      Config.selection.diff_highlight_added_timeout_ms = 0
      selection:submit_input("rename the value")
      stream.on_chunk("<code>" .. new_line .. "</code>")
      stream.on_stop({})
      assert.are.same({ new_line }, lines())
      assert.equals(0, #marks(Diff._namespace))
      assert.equals(0, #marks(Diff._delete_namespace))
    end)
  end
end)
