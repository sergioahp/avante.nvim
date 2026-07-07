local OpenAI = require("avante.providers.openai")

-- A provider that inherits `reasoning_effort` from the openai base but declares its own
-- nested `reasoning` override ends up with both in the body after the deep merge. OpenRouter
-- rejects that (400: "reasoning_effort and reasoning.effort are both provided with conflicting
-- values"). set_allowed_params keeps the explicit nested form and drops the inherited scalar.
describe("openai.set_allowed_params reasoning reconciliation", function()
  it("drops the scalar reasoning_effort when a nested reasoning is also present", function()
    local body = {
      reasoning_effort = "medium",
      reasoning = { effort = "minimal" },
    }
    OpenAI.set_allowed_params({ model = "openai/gpt-5.4-mini" }, body)
    assert.is_nil(body.reasoning_effort)
    assert.are.same({ effort = "minimal" }, body.reasoning)
  end)

  it("preserves a scalar-only reasoning_effort (openai-direct style)", function()
    local body = { reasoning_effort = "medium" }
    OpenAI.set_allowed_params({ model = "openai/gpt-5.4-mini" }, body)
    assert.are.equal("medium", body.reasoning_effort)
    assert.is_nil(body.reasoning)
  end)

  it("clears both on a non-reasoning model", function()
    local body = { reasoning_effort = "medium", reasoning = { effort = "minimal" } }
    OpenAI.set_allowed_params({ model = "gpt-4o" }, body)
    assert.is_nil(body.reasoning_effort)
    assert.is_nil(body.reasoning)
  end)
end)
