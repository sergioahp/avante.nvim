local Fast = require("avante.fast")
local History = require("avante.history")
local Llm = require("avante.llm")
local Path = require("avante.path")
local Provider = require("avante.providers")
local Config = require("avante.config")

local api = vim.api

local originals = {}

local function make_buf(lines)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_current_buf(buf)
  return buf
end

describe("fast submit", function()
  before_each(function()
    originals.stream = Llm.stream
    originals.morph = rawget(Provider, "morph")
    originals.history_load = Path.history.load
    originals.history_save = Path.history.save
    originals.provider = Config.provider
    originals.get_provider_config = Config.get_provider_config

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
