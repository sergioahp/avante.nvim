local SelectionDiffHighlight = require("avante.selection_diff_highlight")
local Config = require("avante.config")

describe("selection diff highlight", function()
  local buffers
  local defer_fn

  local function make_buf(lines)
    local bufnr = vim.api.nvim_create_buf(false, true)
    buffers[#buffers + 1] = bufnr
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
  end

  local function deleted_marks(bufnr)
    return vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._delete_namespace, 0, -1, { details = true })
  end

  before_each(function()
    buffers = {}
    defer_fn = vim.defer_fn
  end)

  after_each(function()
    vim.defer_fn = defer_fn
    for _, bufnr in ipairs(buffers) do
      SelectionDiffHighlight.clear(bufnr)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("defaults to a short flash", function()
    assert.is_true(Config._defaults.selection.diff_highlight_instant)
    assert.equals(100, Config._defaults.selection.diff_highlight_timeout_ms)
    assert.equals(500, Config._defaults.selection.diff_highlight_added_timeout_ms)
  end)

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
    local bufnr = make_buf({})
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
    local bufnr = make_buf({})
    local old_line = "bold(c)_1 + bold(x)_1"
    local new_line = "c_1 + x_1"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { old_line })

    local count = SelectionDiffHighlight.show_deletions(bufnr, { old_line }, { new_line }, 1, { timeout_ms = -1 })

    local marks =
      vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._delete_namespace, 0, -1, { details = true })
    local ranges = vim.tbl_map(function(mark)
      local details = mark[4]
      return old_line:sub(mark[3] + 1, details.end_col)
    end, marks)

    assert.equals(4, count)
    assert.are.same({ "bold(", ")", "bold(", ")" }, ranges)
    assert.equals("AvanteSelectionDiffDelete", marks[1][4].hl_group)
  end)

  it("does not place insertion highlights for byte-level pure deletions", function()
    local bufnr = make_buf({})
    local old_line = "bold(c)_1 + bold(x)_1"
    local new_line = "c_1 + x_1"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { new_line })

    SelectionDiffHighlight.show(bufnr, { old_line }, { new_line }, 1, { timeout_ms = -1 })

    local marks = vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._namespace, 0, -1, { details = true })
    assert.equals(0, #marks)
  end)

  it("shows small replacements inline over the already-applied buffer", function()
    local bufnr = make_buf({})
    local old_line = "local result = old_value + keep"
    local new_line = "local result = new_value + keep"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { new_line })

    SelectionDiffHighlight.show_transition(bufnr, { old_line }, { new_line }, 1, {
      transition_timeout_ms = -1,
      added_timeout_ms = -1,
    })

    assert.are.same({ new_line }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

    local added = vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._namespace, 0, -1, { details = true })
    local deleted =
      vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._delete_namespace, 0, -1, { details = true })
    assert.equals(1, #added)
    assert.equals("new", new_line:sub(added[1][3] + 1, added[1][4].end_col))
    assert.equals(1, #deleted)
    assert.are.same({ { "old", "AvanteSelectionDiffDelete" } }, deleted[1][4].virt_text)
    assert.equals("inline", deleted[1][4].virt_text_pos)
  end)

  it("uses a virtual before line for a heavy replacement", function()
    local bufnr = make_buf({})
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "omega" })

    SelectionDiffHighlight.show_transition(bufnr, { "alpha" }, { "omega" }, 1, {
      transition_timeout_ms = -1,
      added_timeout_ms = -1,
    })

    local deleted =
      vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._delete_namespace, 0, -1, { details = true })
    assert.equals(1, #deleted)
    assert.are.same({ { { "alpha", "AvanteSelectionDiffDelete" } } }, deleted[1][4].virt_lines)
    assert.is_true(deleted[1][4].virt_lines_above)
  end)

  it("keeps a pure deletion visible as a virtual line over the final buffer", function()
    local bufnr = make_buf({})
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "after" })

    SelectionDiffHighlight.show_transition(bufnr, { "remove me" }, {}, 1, {
      transition_timeout_ms = -1,
      added_timeout_ms = -1,
    })

    assert.are.same({ "after" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._namespace, 0, -1, {}))
    local deleted =
      vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._delete_namespace, 0, -1, { details = true })
    assert.equals(1, #deleted)
    assert.are.same({ { { "remove me", "AvanteSelectionDiffDelete" } } }, deleted[1][4].virt_lines)
  end)

  it("clears virtual deletions before the added highlight", function()
    local bufnr = make_buf({})
    local old_line = "local value = old_name"
    local new_line = "local value = new_name"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { new_line })

    SelectionDiffHighlight.show_transition(bufnr, { old_line }, { new_line }, 1, {
      transition_timeout_ms = 20,
      added_timeout_ms = 40,
    })

    assert.equals(
      1,
      #vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._delete_namespace, 0, -1, { details = true })
    )
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._namespace, 0, -1, {}))

    assert.is_true(
      vim.wait(
        200,
        function()
          return #vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._delete_namespace, 0, -1, {}) == 0
        end,
        5
      )
    )
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._namespace, 0, -1, {}))

    assert.is_true(
      vim.wait(
        200,
        function() return #vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._namespace, 0, -1, {}) == 0 end,
        5
      )
    )
    assert.are.same({ new_line }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)

  it("does not show deleted text for a pure inline insertion", function()
    local bufnr = make_buf({ "local new_name = 1" })
    SelectionDiffHighlight.show_transition(bufnr, { "local name = 1" }, { "local new_name = 1" }, 1, {
      transition_timeout_ms = -1,
      added_timeout_ms = -1,
    })
    assert.equals(0, #deleted_marks(bufnr))
  end)

  it("anchors a deletion at the start of a selection below its untouched prefix", function()
    local bufnr = make_buf({ "prefix", "keep", "suffix" })
    SelectionDiffHighlight.show_transition(bufnr, { "remove", "keep" }, { "keep" }, 2, {
      transition_timeout_ms = -1,
      added_timeout_ms = -1,
    })
    local deleted = deleted_marks(bufnr)
    assert.equals(1, #deleted)
    assert.equals(1, deleted[1][2])
    assert.is_true(deleted[1][4].virt_lines_above)
    assert.are.same({ { { "remove", "AvanteSelectionDiffDelete" } } }, deleted[1][4].virt_lines)
  end)

  it("keeps surplus deleted lines between the replacement and its untouched suffix", function()
    local bufnr = make_buf({ "prefix", "omega", "suffix" })
    SelectionDiffHighlight.show_transition(bufnr, { "alpha", "remove" }, { "omega" }, 2, {
      transition_timeout_ms = -1,
      added_timeout_ms = -1,
    })
    local deleted = deleted_marks(bufnr)
    assert.equals(2, #deleted)
    assert.equals(2, deleted[2][2])
    assert.is_true(deleted[2][4].virt_lines_above)
    assert.are.same({ { { "remove", "AvanteSelectionDiffDelete" } } }, deleted[2][4].virt_lines)
  end)

  it("anchors a fully deleted selection immediately above the following line", function()
    local bufnr = make_buf({ "prefix", "suffix" })
    SelectionDiffHighlight.show_transition(bufnr, { "remove" }, {}, 2, {
      transition_timeout_ms = -1,
      added_timeout_ms = -1,
    })
    local deleted = deleted_marks(bufnr)
    assert.equals(1, deleted[1][2])
    assert.is_true(deleted[1][4].virt_lines_above)
  end)

  it("places a deletion at EOF below the final surviving line", function()
    local bufnr = make_buf({ "prefix", "keep" })
    SelectionDiffHighlight.show_transition(bufnr, { "keep", "remove" }, { "keep" }, 2, {
      transition_timeout_ms = -1,
      added_timeout_ms = -1,
    })
    local deleted = deleted_marks(bufnr)
    assert.equals(1, deleted[1][2])
    assert.is_false(deleted[1][4].virt_lines_above)
  end)

  it("keeps multibyte replacements intact in virtual text and highlight columns", function()
    local old_char, new_char = vim.fn.nr2char(225), vim.fn.nr2char(233)
    local prefix, suffix = 'local label = "', '"'
    local old_line, new_line = prefix .. old_char .. suffix, prefix .. new_char .. suffix
    local bufnr = make_buf({ new_line })
    SelectionDiffHighlight.show_transition(bufnr, { old_line }, { new_line }, 1, {
      transition_timeout_ms = -1,
      added_timeout_ms = -1,
    })
    local deleted = deleted_marks(bufnr)
    assert.are.same({ { old_char, "AvanteSelectionDiffDelete" } }, deleted[1][4].virt_text)
    assert.equals(#prefix, deleted[1][3])
    local added = vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._namespace, 0, -1, { details = true })
    assert.equals(#prefix, added[1][3])
    assert.equals(#prefix + #new_char, added[1][4].end_col)
  end)

  it("does not let a legacy highlight timer clear a newer transition", function()
    local timers = {}
    vim.defer_fn = function(callback) timers[#timers + 1] = callback end
    local bufnr = make_buf({ "local new_name = 1" })
    SelectionDiffHighlight.show(bufnr, { "local old_name = 1" }, { "local new_name = 1" }, 1, { timeout_ms = 20 })
    SelectionDiffHighlight.show_transition(bufnr, { "local old_name = 1" }, { "local new_name = 1" }, 1, {
      transition_timeout_ms = -1,
      added_timeout_ms = -1,
    })
    timers[1]()
    assert.equals(1, #deleted_marks(bufnr))
    assert.equals(1, #vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._namespace, 0, -1, {}))
  end)

  it("captures the actual buffer when called with buffer zero", function()
    local timers = {}
    vim.defer_fn = function(callback) timers[#timers + 1] = callback end
    local bufnr = make_buf({ "local new_name = 1" })
    vim.api.nvim_set_current_buf(bufnr)
    SelectionDiffHighlight.show_transition(0, { "local old_name = 1" }, { "local new_name = 1" }, 1, {
      transition_timeout_ms = 20,
      added_timeout_ms = 0,
    })
    local other = make_buf({ "other" })
    vim.api.nvim_set_current_buf(other)
    timers[1]()
    assert.equals(0, #deleted_marks(bufnr))
    assert.equals(0, #vim.api.nvim_buf_get_extmarks(bufnr, SelectionDiffHighlight._namespace, 0, -1, {}))
  end)
end)
