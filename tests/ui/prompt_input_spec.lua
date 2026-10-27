local PromptInput = require("avante.ui.prompt_input")
local Config = require("avante.config")

describe("prompt submission shortcuts", function()
  local prompt, options

  before_each(function()
    options = Config._options
    Config._options = vim.deepcopy(Config._defaults)
  end)

  after_each(function()
    if prompt then prompt:close() end
    prompt = nil
    Config._options = options
  end)

  it("keeps the Tab routing switch on prompts without selection review", function()
    local submitted
    prompt = PromptInput:new({
      win_opts = {},
      default_value = "rename the value",
      close_on_submit = true,
      switch = { off = "morph", on = "chat" },
      submit_callback = function(input, opts) submitted = { input = input, switch_on = opts.switch_on } end,
    })
    prompt:open()
    assert.is_nil(vim.fn.maparg("<C-j>", "i", false, true).callback)
    vim.fn.maparg("<Tab>", "i", false, true).callback()
    vim.fn.maparg(Config.mappings.submit.insert, "i", false, true).callback()
    assert.are.same({ input = "rename the value", switch_on = true }, submitted)
    assert.is_nil(prompt.bufnr)
  end)

  it("uses the configured review shortcut without invoking direct submission", function()
    Config.mappings.submit.review = "<C-k>"
    local reviewed
    prompt = PromptInput:new({
      win_opts = {},
      default_value = "rename the value",
      submit_callback = function() error("review must not submit a direct edit") end,
      review_callback = function(input) reviewed = input end,
    })
    prompt:open()
    assert.is_nil(vim.fn.maparg("<C-j>", "i", false, true).callback)
    vim.fn.maparg("<C-k>", "i", false, true).callback()
    assert.equals("rename the value", reviewed)
  end)
end)
