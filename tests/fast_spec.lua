local Fast = require("avante.fast")
local History = require("avante.history")
local Llm = require("avante.llm")
local Path = require("avante.path")
local Provider = require("avante.providers")
local Config = require("avante.config")
local Morph = require("avante.morph")
local PendingEdits = require("avante.pending_edits")
local EditContext = require("avante.edit_context")
local PromptInput = require("avante.ui.prompt_input")

local api = vim.api

local originals = {}
local buffers

local function make_buf(lines)
  local buf = api.nvim_create_buf(false, true)
  buffers[#buffers + 1] = buf
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_current_buf(buf)
  return buf
end

describe("fast submit", function()
  before_each(function()
    buffers = {}
    originals.options = Config._options
    originals.stream = Llm.stream
    originals.morph = rawget(Provider, "morph")
    originals.history_load = Path.history.load
    originals.history_save = Path.history.save
    originals.provider = Config.provider
    originals.get_provider_config = Config.get_provider_config
    originals.morph_apply = Morph.apply
    originals.submit = Fast.submit
    originals.prompt_new = PromptInput.new

    Config._options = vim.deepcopy(Config._defaults)
    rawset(Provider, "morph", { is_env_set = function() return true end })
    Config.provider = "openai"
    Config.get_provider_config = function() return { model = "gpt-test" } end
  end)

  after_each(function()
    Llm.stream = originals.stream
    rawset(Provider, "morph", originals.morph)
    Path.history.load = originals.history_load
    Path.history.save = originals.history_save
    Config.provider = originals.provider
    Config.get_provider_config = originals.get_provider_config
    Config._options = originals.options
    Morph.apply = originals.morph_apply
    Fast.submit = originals.submit
    PromptInput.new = originals.prompt_new
    for _, buf in ipairs(buffers) do
      PendingEdits.dismiss_all(buf)
      if api.nvim_buf_is_valid(buf) then api.nvim_buf_delete(buf, { force = true }) end
    end
  end)

  it("keeps the no-selection float path ephemeral", function()
    local buf = make_buf({ "local value = 1" })
    local captured

    Path.history.load = function() error("ephemeral fast submit must not load persistent history") end
    Path.history.save = function() error("ephemeral fast submit must not save persistent history") end
    Llm.stream = function(opts)
      captured = opts
      opts.on_stop({ reason = "complete" })
    end

    Fast.submit({ prompt = "increment value", bufnr = buf, ephemeral = true, with_diagnostics = false })

    assert.are.equal("fast_ephemeral", captured.mode)
    assert.are.equal(1, #captured.history_messages)
    assert.are.equal("increment value", captured.history_messages[1].message.content)
    assert.are.equal("openai", captured.history_messages[1].provider)
    assert.are.equal("gpt-test", captured.history_messages[1].model)
  end)

  it("sends the source cursor after focus moves into a prompt", function()
    local buf = make_buf({ "first", "  second" })
    make_buf({ "prompt" })
    local captured
    Llm.stream = function(opts) captured = opts end
    Fast.submit({ prompt = "change this", bufnr = buf, cursor = { 2, 2 }, ephemeral = true, with_diagnostics = false })
    assert.equals("first\n  <cursor/>second", captured.selected_files[1].content)
    assert.are.same({ "first", "  second" }, api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("captures the code cursor before opening the floating prompt", function()
    local buf = make_buf({ "first", "  second" })
    api.nvim_win_set_cursor(0, { 2, 2 })
    local prompt, submitted
    PromptInput.new = function(_, opts)
      prompt = opts
      return { open = function() make_buf({ "prompt" }) end }
    end
    Fast.submit = function(opts) submitted = opts end
    require("avante.api").fast_prompt()
    prompt.submit_callback("change this", {})
    assert.equals(buf, submitted.bufnr)
    assert.are.same({ 2, 2 }, submitted.cursor)
  end)

  it("never passes the cursor annotation to Morph or writes a proposal before approval", function()
    local buf = make_buf({ "local value = 1" })
    local captured, original_code
    Llm.stream = function(opts) captured = opts end
    Morph.apply = function(code, _, _, callback)
      original_code = code
      callback("local value = 2")
    end
    Fast.submit({ prompt = "increment this", bufnr = buf, ephemeral = true, with_diagnostics = false })
    assert.is_truthy(captured.selected_files[1].content:find("<cursor/>", 1, true))
    captured.tools[1].func({ code_edit = "local value = 2" }, {})
    assert.equals("local value = 1", original_code)
    assert.are.same({ "local value = 1" }, api.nvim_buf_get_lines(buf, 0, -1, false))
    assert.is_true(PendingEdits.has_pending(buf))
    PendingEdits.accept_all(buf)
    assert.are.same({ "local value = 2" }, api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("rejects a draft if the buffer changed since it was shown to the model", function()
    local buf = make_buf({ "local value = 1" })
    local tools = Fast.make_fast_tools(buf, { with_diagnostics = false })
    api.nvim_buf_set_lines(buf, 0, -1, false, { "manual" })
    Morph.apply = function() error("stale drafts must not be submitted to Morph") end
    local _, err = tools[1].func({ code_edit = "local value = 2" }, {})
    assert.equals("__CANCELLED__", err)
    assert.are.same({ "manual" }, api.nvim_buf_get_lines(buf, 0, -1, false))
  end)

  it("uses the constrained selection editor for visual review requests", function()
    local buf = make_buf({ "local value = old_name" })
    local captured
    Llm.stream = function(opts) captured = opts end
    Fast.submit({
      prompt = "rename this",
      bufnr = buf,
      selection = {
        filepath = "example.lua",
        filetype = "lua",
        content = "local value = old_name",
        range = { start = { lnum = 1, col = 15 }, finish = { lnum = 1, col = 22 } },
      },
    })
    assert.equals("editing_regen", captured.mode)
    assert.equals("rewrite_window", captured.tools[1].name)
    assert.is_truthy(captured.instructions:find("<selection>old_name</selection>", 1, true))
  end)

  it("keeps UTF-8 characters whole when inserting the cursor annotation", function()
    local char = vim.fn.nr2char(233)
    local buf = make_buf({ "a" .. char .. "b" })
    local context = EditContext.file(buf, { 1, 2 })
    assert.equals("a<cursor/>" .. char .. "b", context.content)
  end)

  it("keeps persistent history for sidebar fast mode", function()
    local buf = make_buf({ "local value = 1" })
    local captured
    local loaded_buf
    local saved_buf
    local saved_history
    local old_message = History.Message:new("assistant", "remembered context")

    Path.history.load = function(load_buf)
      loaded_buf = load_buf
      return {
        title = "old chat",
        timestamp = "2026-07-06 12:00:00",
        entries = {},
        messages = { old_message },
        todos = {},
        filename = "1.json",
      }
    end
    Path.history.save = function(save_buf, history)
      saved_buf = save_buf
      saved_history = history
    end
    Llm.stream = function(opts)
      captured = opts
      opts.on_stop({ reason = "complete" })
    end

    Fast.submit({ prompt = "continue", bufnr = buf, with_diagnostics = false })

    assert.are.equal(buf, loaded_buf)
    assert.are.equal(buf, saved_buf)
    assert.are.equal("fast", captured.mode)
    assert.are.equal(2, #captured.history_messages)
    assert.are.equal("remembered context", captured.history_messages[1].message.content)
    assert.are.equal("continue", captured.history_messages[2].message.content)
    assert.are.equal(2, #saved_history.messages)
  end)
end)
