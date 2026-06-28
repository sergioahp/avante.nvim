local SelectionDiffHighlight = require("avante.selection_diff_highlight")

describe("selection diff highlight", function()
  it("returns only changed replacement tokens", function()
    local old_tokens = SelectionDiffHighlight._tokenize({ "local result = old_value + keep" }, 1)
    local new_tokens = SelectionDiffHighlight._tokenize({ "local result = new_value + keep" }, 1)
    local changed = SelectionDiffHighlight.changed_tokens(old_tokens, new_tokens)

    assert.are.same({ "new_value" }, vim.tbl_map(function(token) return token.text end, changed))
  end)

  it("does not highlight pure deletions", function()
    local old_tokens = SelectionDiffHighlight._tokenize({ "remove_me" }, 1)
    local new_tokens = SelectionDiffHighlight._tokenize({ "" }, 1)
    local changed = SelectionDiffHighlight.changed_tokens(old_tokens, new_tokens)

    assert.are.same({}, changed)
  end)

  it("places extmarks on the changed tokens in the final buffer", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local line = "local result = new_value + keep"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "before", line, "after" })

    SelectionDiffHighlight.show(bufnr, { "local result = old_value + keep" }, { line }, 2, { timeout_ms = -1 })

    local marks = vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._namespace, 0, -1, { details = true })
    assert.equals(1, #marks)

    local start_col = assert(line:find("new_value", 1, true)) - 1
    local details = marks[1][4]
    assert.equals(1, marks[1][2])
    assert.equals(start_col, marks[1][3])
    assert.equals(start_col + #"new_value", details.end_col)
    assert.equals("AvanteSelectionDiff", details.hl_group)
  end)
end)
