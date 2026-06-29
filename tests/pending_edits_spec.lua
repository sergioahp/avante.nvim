local PendingEdits = require("avante.pending_edits")

local api = vim.api

---Make a scratch buffer the current buffer, seeded with `lines`.
local function make_buf(lines)
  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  api.nvim_set_current_buf(buf)
  return buf
end

local function buf_lines(buf) return api.nvim_buf_get_lines(buf, 0, -1, false) end

describe("pending_edits", function()
  after_each(function()
    -- Clean overlay state between cases on whatever buffer is current.
    PendingEdits.dismiss_all(0)
  end)

  it("renders no hunks when nothing changed", function()
    local buf = make_buf({ "a", "b", "c" })
    local n = PendingEdits.set(buf, { "a", "b", "c" }, { "a", "b", "c" })
    assert.are.equal(0, n)
    assert.is_false(PendingEdits.has_pending(buf))
  end)

  it("accepts a single-line replacement under the cursor", function()
    local buf = make_buf({ "a", "b", "c" })
    local n = PendingEdits.set(buf, { "a", "b", "c" }, { "a", "B", "c" })
    assert.are.equal(1, n)
    assert.is_true(PendingEdits.has_pending(buf))
    -- buffer bytes untouched until accept
    assert.are.same({ "a", "b", "c" }, buf_lines(buf))

    api.nvim_win_set_cursor(0, { 2, 0 })
    assert.is_true(PendingEdits.accept_or_next(buf))
    assert.are.same({ "a", "B", "c" }, buf_lines(buf))
    assert.is_false(PendingEdits.has_pending(buf))
  end)

  it("jumps to the next hunk when the cursor is not on one, then accepts", function()
    local buf = make_buf({ "a", "b", "c", "d", "e" })
    PendingEdits.set(buf, { "a", "b", "c", "d", "e" }, { "a", "b", "C", "d", "e" })
    api.nvim_win_set_cursor(0, { 1, 0 })

    assert.is_true(PendingEdits.accept_or_next(buf))
    -- moved onto the hunk (line 3), buffer still unchanged
    assert.are.equal(3, api.nvim_win_get_cursor(0)[1])
    assert.are.same({ "a", "b", "c", "d", "e" }, buf_lines(buf))

    assert.is_true(PendingEdits.accept_or_next(buf))
    assert.are.same({ "a", "b", "C", "d", "e" }, buf_lines(buf))
  end)

  it("accepts a pure insertion", function()
    local buf = make_buf({ "a", "c" })
    local n = PendingEdits.set(buf, { "a", "c" }, { "a", "b", "c" })
    assert.are.equal(1, n)
    PendingEdits.accept_all(buf)
    assert.are.same({ "a", "b", "c" }, buf_lines(buf))
  end)

  it("accepts an insertion at the top of the file", function()
    local buf = make_buf({ "b", "c" })
    PendingEdits.set(buf, { "b", "c" }, { "a", "b", "c" })
    PendingEdits.accept_all(buf)
    assert.are.same({ "a", "b", "c" }, buf_lines(buf))
  end)

  it("accepts a deletion", function()
    local buf = make_buf({ "a", "b", "c" })
    PendingEdits.set(buf, { "a", "b", "c" }, { "a", "c" })
    PendingEdits.accept_all(buf)
    assert.are.same({ "a", "c" }, buf_lines(buf))
  end)

  it("applies several hunks together with correct line offsets", function()
    local buf = make_buf({ "a", "b", "c", "d", "e" })
    local n = PendingEdits.set(buf, { "a", "b", "c", "d", "e" }, { "A", "b", "c", "D", "e" })
    assert.are.equal(2, n)
    PendingEdits.accept_all(buf)
    assert.are.same({ "A", "b", "c", "D", "e" }, buf_lines(buf))
  end)

  it("handles a hunk that grows the line count, shifting later hunks", function()
    local buf = make_buf({ "a", "b", "c" })
    -- first line becomes three lines; last line also changes
    PendingEdits.set(buf, { "a", "b", "c" }, { "a1", "a2", "a3", "b", "C" })
    PendingEdits.accept_all(buf)
    assert.are.same({ "a1", "a2", "a3", "b", "C" }, buf_lines(buf))
  end)

  it("rejects the hunk under the cursor without touching bytes", function()
    local buf = make_buf({ "a", "b", "c" })
    PendingEdits.set(buf, { "a", "b", "c" }, { "a", "B", "c" })
    api.nvim_win_set_cursor(0, { 2, 0 })
    assert.is_true(PendingEdits.reject_under_cursor(buf))
    assert.are.same({ "a", "b", "c" }, buf_lines(buf))
    assert.is_false(PendingEdits.has_pending(buf))
  end)

  it("dismiss_all clears the overlay", function()
    local buf = make_buf({ "a", "b", "c" })
    PendingEdits.set(buf, { "a", "b", "c" }, { "a", "B", "c" })
    assert.is_true(PendingEdits.has_pending(buf))
    PendingEdits.dismiss_all(buf)
    assert.is_false(PendingEdits.has_pending(buf))
    assert.are.same({ "a", "b", "c" }, buf_lines(buf))
  end)

  it("accept_or_next returns false when there is nothing pending", function()
    local buf = make_buf({ "a", "b", "c" })
    assert.is_false(PendingEdits.accept_or_next(buf))
  end)
end)
