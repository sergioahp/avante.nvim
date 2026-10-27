local Sidebar = require("avante.sidebar")
local Config = require("avante.config")
local Llm = require("avante.llm")
local Morph = require("avante.morph")
local Provider = require("avante.providers")
local Path = require("avante.path")
local Utils = require("avante.utils")
local PendingEdits = require("avante.pending_edits")

local api = vim.api

describe("fast sidebar review", function()
  local originals, bufnr, result_buf, sidebar, captured, timers

  before_each(function()
    originals = {
      options = Config._options,
      stream = Llm.stream,
      apply = Morph.apply,
      morph = rawget(Provider, "morph"),
      save = Path.history.save,
      diagnostics = Utils.lsp.get_current_selection_diagnostics,
      defer_fn = vim.defer_fn,
    }
    Config._options = vim.deepcopy(Config._defaults)
    Config._options.chat_mode = "fast"
    Config._options.behaviour.auto_apply_diff_after_generation = true
    timers = {}
    vim.defer_fn = function(callback) timers[#timers + 1] = callback end
    Llm.stream = function(opts) captured = opts end
    Path.history.save = function() end
    Utils.lsp.get_current_selection_diagnostics = function() return {} end
    rawset(Provider, "morph", { is_env_set = function() return true end })
    bufnr = api.nvim_create_buf(false, true)
    result_buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, { "local value = old_name" })
    api.nvim_set_current_buf(bufnr)
    api.nvim_win_set_cursor(0, { 1, 14 })
    sidebar = setmetatable({
      code = { bufnr = bufnr, winid = api.nvim_get_current_win() },
      containers = { result = { bufnr = result_buf } },
      chat_history = { messages = {} },
      file_selector = { get_selected_filepaths = function() return {} end },
      update_content = function() end,
      clear_state = function() end,
      render_state = function() end,
      add_history_messages = function(self, messages) vim.list_extend(self.chat_history.messages, messages) end,
      get_generate_prompts_options = function(_, _, callback)
        callback({ ask = true, selected_filepaths = { "stale-context.lua" } })
      end,
      apply = function() error("fast review must never automatically apply") end,
    }, Sidebar)
  end)

  after_each(function()
    Config._options = originals.options
    Llm.stream = originals.stream
    Morph.apply = originals.apply
    rawset(Provider, "morph", originals.morph)
    Path.history.save = originals.save
    Utils.lsp.get_current_selection_diagnostics = originals.diagnostics
    vim.defer_fn = originals.defer_fn
    PendingEdits.dismiss_all(bufnr)
    api.nvim_buf_delete(bufnr, { force = true })
    api.nvim_buf_delete(result_buf, { force = true })
  end)

  it("sends the code-window cursor and bypasses automatic application", function()
    sidebar:handle_submit("rename this")
    assert.equals("fast", captured.mode)
    assert.equals("local value = <cursor/>old_name", captured.selected_files[1].content)
    assert.is_nil(captured.selected_filepaths)
    captured.on_stop({ reason = "complete" })
    for _, callback in ipairs(timers) do
      callback()
    end
  end)

  it("restricts a visual sidebar request to selected columns until accepted", function()
    sidebar.code.selection = {
      content = "local value = old_name",
      filepath = "example.lua",
      filetype = "lua",
      range = { start = { lnum = 1, col = 15 }, finish = { lnum = 1, col = 22 } },
    }
    Morph.apply = function(_, _, _, callback) callback("local value = new_name") end
    sidebar:handle_submit("rename this")
    assert.equals("editing_regen", captured.mode)
    assert.is_truthy(captured.instructions:find("<selection>old_name</selection>", 1, true))
    captured.tools[1].func({ code = "local value = new_name" }, { on_complete = function() end })
    captured.on_stop({ reason = "complete" })
    for _, callback in ipairs(timers) do
      callback()
    end
    assert.are.same({ "local value = old_name" }, api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.is_true(PendingEdits.has_pending(bufnr))
    PendingEdits.accept_all(bufnr)
    assert.are.same({ "local value = new_name" }, api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)
end)
