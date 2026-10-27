# Cursor context and constrained selection review

The auto-applying Morph selection editor already sends two marked views to the
drafting model: the selection with wider context, and a smaller edit window to
regenerate. Partial-line markers delimit the selected columns. The client checks
the resulting merge and restores the file outside the selected region. It does
not send a separate caret position.

The old pending-diff flow sent an unmarked file and an optional selected snippet.
That gave the drafting model no cursor anchor, and the snippet did not impose a
client-side editing boundary.

## Changes

- The no-selection floating prompt captures the source cursor before moving
  focus. Fast sidebar and zen requests use the code window's cursor. Drafting
  context carries an inline `<cursor/>` annotation; Morph receives clean file
  contents. Earlier view-tool results cannot suppress this current context.
- Visual `<leader>ae` keeps the existing prompt toggle, now labeled `edit` /
  `review`. Review uses the auto-applying editor's marked context, rewrite-window
  tool, cropped Morph merge, selection guard, and retry feedback. Its final stage
  renders pending hunks instead of changing the buffer. Visual requests in the
  fast sidebar use the same constrained path.
- Review checks exact boundary bytes, including unselected trailing whitespace.
  The final proposal is reconstructed from the original file and the validated
  selection region. Empty and blockwise ranges are rejected instead of silently
  expanding the scope. Characterwise and linewise selections are supported.
- Buffer changes invalidate in-flight drafts and pending review proposals.
  Accepting a hunk updates the proposal's expected buffer state, allowing the
  remaining hunks to be accepted separately.
- Fast sidebar review bypasses `auto_apply_diff_after_generation`. A prose answer
  without an edit-tool call in review mode is never passed to Morph as code.
- The test launcher now loads Nui as well as Plenary in child Neovim processes,
  so the selection/sidebar integration tests can run from a clean checkout.

## Validation

The suite excluding `llm_tools_spec.lua` passed 317 tests across 25 files. A
subsequent selection test for prose answers increased the selection suite from
19 to 20 passing tests. The remaining unchanged tool suite encountered a fixture
permission error, both with its shared `/tmp` fixture and with an isolated
repo-local fixture; the latter completed 23 tests before the fixture error.

Production Lua passes luacheck with no warnings, changed Lua passes StyLua, and
the shell launcher passes `bash -n`. LuaLS found the same eight existing warnings
as before this work. Drafting and Morph calls were mocked; no paid model
requests were made.

The user's remote plugin configuration remains in place. Deployment is through
the fork's `main` branch and an Avante-only Lazy update.
