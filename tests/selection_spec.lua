package.loaded["avante.repo_map"] = {
  get_repo_map = function() return nil end,
}

local Selection = require("avante.selection")

describe("Selection", function()
  describe("_parse_editing_response", function()
    it("extracts code blocks", function()
      local response = table.concat({
        "Here is the edit:",
        "<code>",
        "local value = true",
        "</code>",
      }, "\n")

      assert.are.same({ "local value = true" }, Selection._parse_editing_response(response))
    end)

    it("ignores code blocks inside think blocks", function()
      local response = table.concat({
        "<think>",
        "The selected text is a table, so I will return the replacement.",
        "<code>",
        "duplicated from reasoning",
        "</code>",
        "</think>",
        "<code>",
        "actual replacement",
        "</code>",
      }, "\n")

      assert.are.same({ "actual replacement" }, Selection._parse_editing_response(response))
    end)
  end)
end)
