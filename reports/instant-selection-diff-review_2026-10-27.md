# Instant selection diff review

Reviewed `feat/instant-selection-diff-render`, including commit `c6866ee`,
against current `main`. The original 11 highlight tests passed, but seven
additional regression cases failed before the fixes.

## Findings and fixes

- Removing the pre-edit flash also removed the guard against empty streaming
  output. An opening tag or prose could erase the selected region before any
  replacement arrived. The edit now waits for usable code or a completed empty
  code block. An empty partial-selection replacement preserves the unselected
  prefix and suffix.
- Deleted virtual lines were anchored on the wrong side of surrounding text.
  This affected deletions at the start of a selection, complete removal of a
  selected region, and replacements that remove more lines than they insert.
  Anchors now use the next surviving line, with an EOF fallback.
- Byte-level diffing could split a multibyte character into invalid virtual
  text and place highlights inside that character. Diff tokens now preserve
  whole UTF-8 characters while retaining Neovim's byte-column coordinates.
- A pure insertion within a line displayed its unchanged original line as a
  deletion. The virtual before-line fallback now requires an actual deletion.
- Timers from the legacy highlight functions could clear a newer transition.
  Those timers now check the same generation token as the transition timers.
- Buffer number `0` was resolved when a timer ran, potentially clearing a
  different buffer after a window switch. Public highlight functions now
  resolve it to the actual buffer number before scheduling work.

## Configuration

`selection.diff_highlight_instant` defaults to `true` for both streamed
selection edits and Morph edits. Setting it to `false` restores the deletion
flash before applying the edit, followed by the changed-token highlight.

The instant display shows deletions and additions together for
`diff_highlight_timeout_ms` (default 100 ms), then retains only additions for
`diff_highlight_added_timeout_ms` (default 500 ms). Set both durations to zero
to disable instant highlights. In legacy mode, the first duration controls
both flashes and zero disables them; the added-only duration is unused.

## Validation

All 319 Lua tests passed across 25 test files. Coverage includes both toggle
settings for streamed and Morph edits, malformed streaming responses, partial
selections, virtual deletion placement, UTF-8 replacements, timer overlap,
and switching buffers. The production Lua files pass luacheck, and the
changed Lua files pass StyLua and Git whitespace checks.

LuaLS reports no warnings in the changed production files. Its whole-repo
check still exits with eight warnings in files unchanged from `main`, mostly
deprecated `vim.diff` calls under the installed Neovim 0.12 runtime, plus
existing type warnings in `llm.lua` and `pending_edits.lua`.

Tests used existing local plugin dependencies and a temporary Nix shell for
the search-tool dependency and format/lint tools. Full per-test logs remain
in the ignored review worktree's `tmp/` directory.
