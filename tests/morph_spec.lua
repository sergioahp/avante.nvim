local Morph = require("avante.morph")

describe("morph.crop_around_selection", function()
  local function numbered_lines(count)
    local lines = {}
    for i = 1, count do
      lines[i] = "line " .. i
    end
    return lines
  end

  it("keeps six context lines on each side of a small selection", function()
    local cropped, start_lnum, finish_lnum, source_start, source_finish =
      Morph.crop_around_selection(numbered_lines(30), 15, 15)
    assert.are.same(9, source_start)
    assert.are.same(21, source_finish)
    assert.are.same(7, start_lnum)
    assert.are.same(7, finish_lnum)
    assert.are.same(13, #cropped)
    assert.are.same("line 15", cropped[start_lnum])
  end)

  it("grows each side in proportion to a larger selection", function()
    local cropped, start_lnum, finish_lnum, source_start, source_finish =
      Morph.crop_around_selection(numbered_lines(60), 20, 29)
    assert.are.same(10, source_start)
    assert.are.same(39, source_finish)
    assert.are.same(11, start_lnum)
    assert.are.same(20, finish_lnum)
    assert.are.same(30, #cropped)
    assert.are.same("line 20", cropped[start_lnum])
    assert.are.same("line 29", cropped[finish_lnum])
  end)

  it("clamps context at the start of the file", function()
    local cropped, start_lnum, finish_lnum, source_start, source_finish =
      Morph.crop_around_selection(numbered_lines(30), 1, 2)
    assert.are.same(1, source_start)
    assert.are.same(8, source_finish)
    assert.are.same(1, start_lnum)
    assert.are.same(2, finish_lnum)
    assert.are.same(8, #cropped)
  end)

  it("clamps context at the end of the file", function()
    local cropped, start_lnum, finish_lnum, source_start, source_finish =
      Morph.crop_around_selection(numbered_lines(30), 29, 30)
    assert.are.same(23, source_start)
    assert.are.same(30, source_finish)
    assert.are.same(7, start_lnum)
    assert.are.same(8, finish_lnum)
    assert.are.same(8, #cropped)
  end)
end)

describe("morph.window_around_selection", function()
  local function numbered_lines(count)
    local lines = {}
    for i = 1, count do
      lines[i] = "line " .. i
    end
    return lines
  end

  it("keeps three context lines on each side", function()
    local ws, wf = Morph.window_around_selection(numbered_lines(30), 10, 12)
    assert.are.same(7, ws)
    assert.are.same(15, wf)
  end)

  it("clamps at the buffer edges", function()
    local ws, wf = Morph.window_around_selection(numbered_lines(10), 1, 9)
    assert.are.same(1, ws)
    assert.are.same(10, wf)
  end)
end)

describe("morph.fuzzy_align_region", function()
  it("returns the region unchanged when the context is copied exactly", function()
    local orig = { "a", "b", "SEL", "c", "d" }
    local model = { "a", "b", "NEW1", "NEW2", "c", "d" }
    assert.are.same({ "NEW1", "NEW2" }, Morph.fuzzy_align_region(orig, model, 2, 2))
  end)

  it("discards context lines the model dropped (blank-line drift)", function()
    local orig = { "x = 1", "", "", "SEL", "", "y = 2" }
    -- model collapsed the double blank line before the selection and dropped the
    -- blank after it
    local model = { "x = 1", "", "NEW", "y = 2" }
    assert.are.same({ "NEW" }, Morph.fuzzy_align_region(orig, model, 3, 2))
  end)

  it("tolerates whitespace-only drift in context lines", function()
    local orig = { "  before", "SEL", "  after" }
    local model = { "before", "CHANGED", "after  " }
    assert.are.same({ "CHANGED" }, Morph.fuzzy_align_region(orig, model, 1, 1))
  end)

  it("keeps a grown region between duplicate-looking context lines", function()
    local orig = { "}", "", "POOL = {", "  timeout = 30,", "}", "" }
    local model = { "}", "", "POOL = {", "  timeout = 90,", "  retries = 3,", "}" }
    assert.are.same(
      { "POOL = {", "  timeout = 90,", "  retries = 3,", "}" },
      Morph.fuzzy_align_region(orig, model, 2, 1)
    )
  end)
end)

describe("morph.scoped_region_change", function()
  it("returns the replacement lines for a mid-file edit (markers both sides)", function()
    local orig = { "a", "b", "c", "d", "e" }
    -- Morph changed only line 3 ("c" -> "C")
    local merged = { "a", "b", "C", "d", "e" }
    local region, err = Morph.scoped_region_change(orig, merged, 3, 3)
    assert.is_nil(err)
    assert.are.same({ "C" }, region)
  end)

  it("handles a region that grows (one selected line becomes several)", function()
    local orig = { "a", "b", "c", "d", "e" }
    local merged = { "a", "b", "c1", "c2", "c3", "d", "e" }
    local region, err = Morph.scoped_region_change(orig, merged, 3, 3)
    assert.is_nil(err)
    assert.are.same({ "c1", "c2", "c3" }, region)
  end)

  it("handles a region that shrinks (two selected lines collapse to one)", function()
    local orig = { "a", "b", "c", "d", "e" }
    local merged = { "a", "b", "CD", "e" }
    local region, err = Morph.scoped_region_change(orig, merged, 3, 4)
    assert.is_nil(err)
    assert.are.same({ "CD" }, region)
  end)

  it("handles an edit at the start of the file (no leading context)", function()
    local orig = { "a", "b", "c" }
    local merged = { "A", "b", "c" }
    local region, err = Morph.scoped_region_change(orig, merged, 1, 1)
    assert.is_nil(err)
    assert.are.same({ "A" }, region)
  end)

  it("handles an edit at the end of the file (no trailing context)", function()
    local orig = { "a", "b", "c" }
    local merged = { "a", "b", "C" }
    local region, err = Morph.scoped_region_change(orig, merged, 3, 3)
    assert.is_nil(err)
    assert.are.same({ "C" }, region)
  end)

  it("rejects a merge that changed a line BEFORE the selected region", function()
    local orig = { "a", "b", "c", "d", "e" }
    -- selection is line 4, but Morph also touched line 2
    local merged = { "a", "B", "c", "D", "e" }
    local region, err = Morph.scoped_region_change(orig, merged, 4, 4)
    assert.is_nil(region)
    assert.is_truthy(err)
    assert.is_truthy(err:match("before the selected region"))
  end)

  it("rejects a merge that changed a line AFTER the selected region", function()
    local orig = { "a", "b", "c", "d", "e" }
    -- selection is line 2, but Morph also touched line 5
    local merged = { "a", "B", "c", "d", "E" }
    local region, err = Morph.scoped_region_change(orig, merged, 2, 2)
    assert.is_nil(region)
    assert.is_truthy(err)
    assert.is_truthy(err:match("after the selected region"))
  end)

  -- The real-world failure: an unanchored snippet meant for one row landed on a
  -- different, similar-looking row elsewhere in the file. The selection was the
  -- LAST z-row; Morph instead rewrote an earlier z-row. The guard must reject it.
  it("rejects the wrong-z-row mis-apply (edit landed outside the selection)", function()
    local orig = {
      "z, 1, -2, 1, 0;",
      "z, 0, -5/2, 3/2, 3;", -- earlier z-row, must stay untouched
      "x_3, 0, 1/3, 1, 6;",
      "z,", -- the selected (empty) z-row, lines 4..4
    }
    -- Morph wrongly rewrote line 2 and left line 4 empty
    local merged = {
      "z, 1, -2, 1, 0;",
      "z, 0, 0, -3, 12;",
      "x_3, 0, 1/3, 1, 6;",
      "z,",
    }
    local region, err = Morph.scoped_region_change(orig, merged, 4, 4)
    assert.is_nil(region)
    assert.is_truthy(err)
  end)

  -- Morph normalizes EOF whitespace: the original buffer ended with a trailing
  -- blank line, the merged output dropped it. That is outside the selection but
  -- must NOT be treated as a stray edit.
  it("tolerates a trailing blank line dropped at EOF (outside the selection)", function()
    local orig = { "a", "b", "c", "" } -- trailing blank line 4
    local merged = { "a", "B", "c" } -- selection was line 2; trailing blank dropped
    local region, err = Morph.scoped_region_change(orig, merged, 2, 2)
    assert.is_nil(err)
    assert.are.same({ "B" }, region)
  end)

  -- Morph also strips a trailing space from a line it otherwise leaves alone. That
  -- is the "space on the last line" case that used to reject a clean map expansion.
  it("tolerates a trailing space stripped from the last line (outside the selection)", function()
    local orig = { "a", "b", "c", "d " } -- last line has a stray trailing space
    local merged = { "a", "B1", "B2", "c", "d" } -- selection line 2 grew; Morph stripped line 4's space
    local region, err = Morph.scoped_region_change(orig, merged, 2, 2)
    assert.is_nil(err)
    assert.are.same({ "B1", "B2" }, region)
  end)

  it("tolerates trailing whitespace added before the selection", function()
    local orig = { "a", "b", "c" }
    local merged = { "a ", "B", "c" } -- Morph added a trailing space to line 1 (before sel line 2)
    local region, err = Morph.scoped_region_change(orig, merged, 2, 2)
    assert.is_nil(err)
    assert.are.same({ "B" }, region)
  end)

  it("still rejects a non-whitespace change on the last line", function()
    local orig = { "a", "b", "c", "d" }
    local merged = { "a", "B", "c", "D" } -- selection line 2; line 4 really changed (d -> D)
    local region, err = Morph.scoped_region_change(orig, merged, 2, 2)
    assert.is_nil(region)
    assert.is_truthy(err)
  end)

  it("still rejects a real edit after the region even when EOF blanks differ", function()
    local orig = { "a", "b", "c", "d", "" }
    local merged = { "A", "b", "c", "D" } -- changed line 4 (after sel line 1) AND dropped EOF blank
    local region, err = Morph.scoped_region_change(orig, merged, 1, 1)
    assert.is_nil(region)
    assert.is_truthy(err)
  end)

  it("accepts the correct apply on the selected z-row", function()
    local orig = {
      "z, 1, -2, 1, 0;",
      "z, 0, -5/2, 3/2, 3;",
      "x_3, 0, 1/3, 1, 6;",
      "z,",
    }
    local merged = {
      "z, 1, -2, 1, 0;",
      "z, 0, -5/2, 3/2, 3;",
      "x_3, 0, 1/3, 1, 6;",
      "z, 0, -3, 0, 12;",
    }
    local region, err = Morph.scoped_region_change(orig, merged, 4, 4)
    assert.is_nil(err)
    assert.are.same({ "z, 0, -3, 0, 12;" }, region)
  end)
end)

describe("morph.check_region_boundaries", function()
  -- The failure this guards: one value inside a single-line list was selected and
  -- the whole line came back rewritten. The line-level guard cannot see that.
  -- `  local opts = { width = 40, height = 20, border = "single" }` with `40`
  -- selected splits into:
  local prefix = "  local opts = { width = "
  local suffix = ', height = 20, border = "single" }'

  it(
    "passes a whole-line selection through untouched",
    function() assert.is_nil(Morph.check_region_boundaries({ "anything at all" }, "", "")) end
  )

  it(
    "accepts a rewrite confined to the selected columns",
    function() assert.is_nil(Morph.check_region_boundaries({ prefix .. "80" .. suffix }, prefix, suffix)) end
  )

  it("rejects a rewrite that changed the fields after the selection", function()
    local merged = '  local opts = { width = 80, height = 40, border = "single" }'
    local err, detail = Morph.check_region_boundaries({ merged }, prefix, suffix)
    assert.is_truthy(err)
    assert.are.same("suffix", detail.where)
  end)

  it("rejects a rewrite that changed the text before the selection", function()
    local merged = '  local opts = { win_width = 80, height = 20, border = "single" }'
    local err, detail = Morph.check_region_boundaries({ merged }, prefix, suffix)
    assert.is_truthy(err)
    assert.are.same("prefix", detail.where)
  end)

  it(
    "rejects a merge that dropped the selected line entirely",
    function() assert.is_truthy(Morph.check_region_boundaries({}, prefix, suffix)) end
  )

  it(
    "rejects a line too short to still hold the unselected text",
    function() assert.is_truthy(Morph.check_region_boundaries({ "80" }, prefix, suffix)) end
  )

  it("checks the first and last lines when a partial selection grew to several", function()
    local region = { prefix .. "compute_width(", "    base,", "  )" .. suffix }
    assert.is_nil(Morph.check_region_boundaries(region, prefix, suffix))
    region[3] = "  ), height = 20 }"
    assert.is_truthy(Morph.check_region_boundaries(region, prefix, suffix))
  end)

  it("ignores an unused side", function()
    assert.is_nil(Morph.check_region_boundaries({ "new tail" }, "", ""))
    assert.is_nil(Morph.check_region_boundaries({ prefix .. "new tail" }, prefix, ""))
    assert.is_truthy(Morph.check_region_boundaries({ "new tail" }, prefix, ""))
  end)

  -- "make this multi-line" on a partial selection: the selected span becomes
  -- several lines, and the guard must not read that growth as straying outside.
  it("accepts a partial selection exploded into a multi-line argument list", function()
    local sig_prefix = "local function resize("
    local sig_suffix = ")"
    local region = { sig_prefix, "  width,", "  height,", "  border" .. sig_suffix }
    assert.is_nil(Morph.check_region_boundaries(region, sig_prefix, sig_suffix))
  end)

  it("accepts a multi-line explosion that closes on its own line", function()
    local json_prefix = '  "sizes": '
    local json_suffix = ","
    local region = { json_prefix .. "[", "    1,", "    2,", "    3", "  ]" .. json_suffix }
    assert.is_nil(Morph.check_region_boundaries(region, json_prefix, json_suffix))
  end)

  it("still rejects a multi-line explosion that ate the text after the selection", function()
    local json_prefix = '  "sizes": '
    local json_suffix = ', "unit": "px"'
    local region = { json_prefix .. "[", "    1,", "    2", "  ]" }
    assert.is_truthy(Morph.check_region_boundaries(region, json_prefix, json_suffix))
  end)

  it(
    "tolerates trailing whitespace stripped from the suffix",
    function() assert.is_nil(Morph.check_region_boundaries({ "x = 1;" }, "", ";   ")) end
  )
end)
