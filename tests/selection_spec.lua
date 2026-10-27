local Selection = require("avante.selection")
local Config = require("avante.config")
local Llm = require("avante.llm")
local Provider = require("avante.providers")
local Morph = require("avante.morph")
local EditTrace = require("avante.edit_trace")
local Utils = require("avante.utils")
local Diff = require("avante.selection_diff_highlight")

local api = vim.api

describe("selection edit highlighting", function()
  local originals, bufnr, selection, stream, timers
  local old_line = "local value = old_name"
  local new_line = "local value = new_name"

  local function lines() return api.nvim_buf_get_lines(bufnr, 0, -1, false) end

  local function marks(namespace) return api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true }) end

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
