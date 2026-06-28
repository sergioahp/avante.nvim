local SelectionDiffHighlight = require("avante.selection_diff_highlight")
local Config = require("avante.config")

describe("selection diff highlight", function()
  it(
    "defaults to a short flash",
    function() assert.equals(100, Config._defaults.selection.diff_highlight_timeout_ms) end
  )

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

  it("finds exact deleted ranges when removing typst bold calls", function()
    local deleted = SelectionDiffHighlight.deleted_ranges({ "bold(c)_1 + bold(x)_1" }, { "c_1 + x_1" }, 1)

    assert.are.same({ "bold(", ")", "bold(", ")" }, vim.tbl_map(function(token) return token.text end, deleted))
  end)

  it("places deletion extmarks on text that will disappear", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local old_line = "bold(c)_1 + bold(x)_1"
    local new_line = "c_1 + x_1"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { old_line })

    local count = SelectionDiffHighlight.show_deletions(bufnr, { old_line }, { new_line }, 1, { timeout_ms = -1 })

    local marks = vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._namespace, 0, -1, { details = true })
    local ranges = vim.tbl_map(function(mark)
      local details = mark[4]
      return old_line:sub(mark[3] + 1, details.end_col)
    end, marks)

    assert.equals(4, count)
    assert.are.same({ "bold(", ")", "bold(", ")" }, ranges)
    assert.equals("AvanteSelectionDiffDelete", marks[1][4].hl_group)
  end)

  it("does not place insertion highlights for byte-level pure deletions", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local old_line = "bold(c)_1 + bold(x)_1"
    local new_line = "c_1 + x_1"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { new_line })

    SelectionDiffHighlight.show(bufnr, { old_line }, { new_line }, 1, { timeout_ms = -1 })

    local marks = vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._namespace, 0, -1, { details = true })
    assert.equals(0, #marks)
  end)

  it("delays replacement while deletion flash is visible", function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    local old_line = "bold(c)_1"
    local new_line = "c_1"
    local applied = false
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { old_line })

    local delayed = SelectionDiffHighlight.flash_deletions_before(bufnr, { old_line }, { new_line }, 1, function()
      applied = true
      vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { new_line })
    end, { timeout_ms = 20 })

    assert.is_true(delayed)
    assert.is_false(applied)
    assert.are.same({ old_line }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

    vim.wait(200, function() return applied end, 5)

    assert.is_true(applied)
    assert.are.same({ new_line }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    local marks = vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._namespace, 0, -1, { details = true })
    assert.equals(0, #marks)
  end)
end)
