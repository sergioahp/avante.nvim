local Morph = require("avante.morph")

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
