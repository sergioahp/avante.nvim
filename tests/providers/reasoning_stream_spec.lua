local Config = require("avante.config")
local claude_provider = require("avante.providers.claude")
local ollama_provider = require("avante.providers.ollama")
local openai_provider = require("avante.providers.openai")

Config.custom_tools = {}
Config.providers = {
  openai = {},
}

local function new_split_handler()
  local content = ""
  local reasoning = ""
  return {
    on_chunk = function(chunk) content = content .. chunk end,
    on_reasoning_chunk = function(chunk) reasoning = reasoning .. chunk end,
    on_messages_add = function() end,
    on_stop = function() end,
  }, function() return content, reasoning end
end

describe("provider reasoning streams", function()
  it("routes OpenAI-compatible reasoning deltas to on_reasoning_chunk", function()
    local opts, get_output = new_split_handler()
    local ctx = {}

    openai_provider:parse_response(
      ctx,
      vim.json.encode({
        choices = {
          {
            delta = {
              reasoning_content = "thinking with <code>ignored</code>",
            },
          },
        },
      }),
      nil,
      opts
    )
    openai_provider:parse_response(
      ctx,
      vim.json.encode({
        choices = {
          {
            delta = {
              content = "<code>actual edit</code>",
            },
          },
        },
      }),
      nil,
      opts
    )

    local content, reasoning = get_output()
    assert.equals("<code>actual edit</code>", content)
    assert.equals("<think>\nthinking with <code>ignored</code>\n</think>\n", reasoning)
  end)

  it("keeps OpenAI-compatible reasoning in on_chunk when no reasoning callback is provided", function()
    local content = ""
    local opts = {
      on_chunk = function(chunk) content = content .. chunk end,
      on_messages_add = function() end,
      on_stop = function() end,
    }
    local ctx = {}

    openai_provider:parse_response(
      ctx,
      vim.json.encode({
        choices = {
          {
            delta = {
              reasoning_content = "thinking",
            },
          },
        },
      }),
      nil,
      opts
    )
    openai_provider:parse_response(
      ctx,
      vim.json.encode({
        choices = {
          {
            delta = {
              content = "answer",
            },
          },
        },
      }),
      nil,
      opts
    )

    assert.equals("<think>\nthinking\n</think>\nanswer", content)
  end)

  it("routes Claude thinking deltas to on_reasoning_chunk", function()
    local opts, get_output = new_split_handler()
    local ctx = { content_blocks = {} }

    claude_provider:parse_response(
      ctx,
      vim.json.encode({
        index = 0,
        content_block = {
          type = "thinking",
          thinking = "",
          signature = "",
        },
      }),
      "content_block_start",
      opts
    )
    claude_provider:parse_response(
      ctx,
      vim.json.encode({
        index = 0,
        delta = {
          type = "thinking_delta",
          thinking = "claude thinking with <code>ignored</code>",
        },
      }),
      "content_block_delta",
      opts
    )
    claude_provider:parse_response(ctx, vim.json.encode({ index = 0 }), "content_block_stop", opts)
    claude_provider:parse_response(
      ctx,
      vim.json.encode({
        index = 1,
        content_block = {
          type = "text",
          text = "",
        },
      }),
      "content_block_start",
      opts
    )
    claude_provider:parse_response(
      ctx,
      vim.json.encode({
        index = 1,
        delta = {
          type = "text_delta",
          text = "<code>claude edit</code>",
        },
      }),
      "content_block_delta",
      opts
    )

    local content, reasoning = get_output()
    assert.equals("<code>claude edit</code>", content)
    assert.equals("<think>\nclaude thinking with <code>ignored</code>\n</think>\n\n", reasoning)
  end)

  it("routes Ollama thinking to on_reasoning_chunk", function()
    local opts, get_output = new_split_handler()

    ollama_provider:parse_stream_data(
      {},
      vim.json.encode({
        message = {
          thinking = "ollama thinking with <code>ignored</code>",
          content = "<code>ollama edit</code>",
        },
      }),
      opts
    )

    local content, reasoning = get_output()
    assert.equals("<code>ollama edit</code>", content)
    assert.equals("ollama thinking with <code>ignored</code>", reasoning)
  end)
end)
