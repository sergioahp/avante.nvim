# Selection edit: the drafting model's context was collateral damage

Date: 2026-09-09
Scope: the visual-selection edit path (`selection.lua` -> draft model -> Morph -> guard)

The drafting model was being shown roughly 13 lines of the file for a one-line
selection. This traces why, and changes it.

--------------------------------------------------------------------------------

## 1. What the drafting model was getting

`selection.lua` computed one crop and handed it to two consumers:

```lua
morph_code_lines, ... = Morph.crop_around_selection(...)
morph_code_content  = table.concat(morph_code_lines, "\n")
prompt_code_content = morph_code_content   -- the drafting model's whole view of the file
```

`crop_around_selection` kept `max(6, selection_lines)` on each side, so for a
mid-file selection:

| selection | `<file>` block the drafting model saw | regen `<edit_window>` |
|-----------|--------------------------------------:|----------------------:|
| 1 line    | 13 lines                              | 7 lines               |
| 3 lines   | 15 lines                              | 9 lines               |
| 12 lines  | 36 lines                              | 18 lines              |

Plus selection-scoped LSP diagnostics, and the repo map only on an explicit
`@` mention. The `path` on that file block was `""`.

## 2. Where the crop came from

Commit `a324946` "Crop Morph selection edit context" (2026-07-18 14:20), one-line
message, no report in `reports/`. The bench that drove it survives in a scratch
directory under `tmp/`, written 20 minutes earlier.

The problem it solved was duplicate-occurrence localization: a fixture contained
the same line at two places, the benchmark selected each occurrence in turn and
asked for the same change, and the model could not tell which one was selected.
`<selected_code>` carries content and nothing positional, so edits landed on the
wrong occurrence and the guard rejected them.

Three fixes were benched that afternoon:

| approach                                            | result                       |
|-----------------------------------------------------|------------------------------|
| prompt variants (complete construct / unique anchors / echo N lines) | best 2/6 confined pass at 12-line context |
| `<selection>` markers in the crop, drafting model only | 3/6, "confirming the localization problem" |
| shrink context 12 -> 6 lines until the duplicate falls outside the crop | 5/6, then 4/4 |

The crop won, and the findings note is explicit that the crop and not the prompt
did the work: all four passing drafts in the final cell were unanchored.

So the mechanism was never "less context is better for the model". It was
**disambiguation by amputation**: make the window small enough that the selected
text is unique inside it, and content matching stops being ambiguous. Sharing one
crop between the two consumers was deliberate, because the trick only works if the
drafting model also cannot see the duplicate.

## 3. Why that became a regression

**The marker approach was rejected for a reason that stopped being true 84 minutes
later.** The findings note dropped markers because "the model may copy fake
metadata into the Morph draft". Same afternoon:

```
13:39-13:58  crop/prompt bench
14:00        findings written
14:20        a324946  crop shipped
14:51-15:25  regen bench
15:44        6d016fe  regen protocol shipped, WITH <selection> markers
```

`6d016fe` implemented the rejected idea and solved marker leak by stripping the
markers client-side in `window_to_update`. It was the only 100% cell in that bench,
on a fixture set that included duplicate blocks. Nobody went back to ask whether
the crop was still earning its six lines, so small selections ran with two
localization mechanisms stacked and only one of them measured.

**The bench could not have detected the cost.** The task was a colour replacement
on a known line, which needs no comprehension of the surrounding code. No cell in
either report measures edit quality for an instruction that requires knowing what a
function does or what is defined above the selection.

**The rationale drifted between bench and code.** The bench justified the crop as
duplicate-occurrence localization. The docstring that shipped said "keeping the
apply model away from distant code prevents unrelated normalization" -- a real
Morph property, a different claim, about a different consumer.

## 4. What the evidence does support

The genuine "narrow is better" findings are all about the other two consumers:

- `regen-window-selection-edit_2026-07-18.md` finding 1, "wider context makes the
  ambiguity WORSE, not better": that is Morph's anchor set on the landmark path.
- Finding 2, the treesitter-snapped window reaching into a decoy comment run: that
  is the regen **window**.

Widening what the drafting model sees has never been benched in either direction.

Morph's own context has its own history worth keeping in mind, because it is a
pendulum between two failure modes rather than a free parameter:

| Morph sees      | failure                                                | era |
|-----------------|--------------------------------------------------------|-----|
| selection only  | no anchors, cannot place an unanchored snippet         | `c56d4c0`, 2026-06-20 05:50 |
| whole buffer    | too many anchors, lands on the wrong duplicate         | `17879f6`, 2026-06-20 22:00 |
| crop            | the compromise                                          | `a324946`, 2026-07-18 |

`17879f6` introduced `scoped_region_change` in the same commit that gave Morph the
whole file, explicitly as the price of doing so.

--------------------------------------------------------------------------------

## 5. The change

One drafting protocol for every selection size, three spans sized for their own
consumer:

| span                              | size            | markers | consumer                    |
|-----------------------------------|-----------------|---------|-----------------------------|
| `<selected_files>` block          | selection ± 100 | yes     | drafting model, to understand |
| `<edit_window>`                   | selection ± 3   | yes     | drafting model, to rewrite  |
| Morph `<code>`                    | selection ± 6   | no      | apply model, to merge into  |

Morph's crop is now fixed at `WINDOW_CONTEXT_LINES + 3` rather than growing with
the selection: it only has to cover the edit window plus room for the landmarks
wrapping it to resolve.

Removed with the size split:

- `REGEN_MAX_SELECTION_LINES` and the 12-line branch.
- The landmark drafting path: `edit_file_tool`, its reject feedback, the
  `partial_note` prose that existed only because that path had no markers, and
  `editing_morph.avanterules`.
- The `use_regen` gate on the fuzzy rescue, which is now the only path.

Added:

- `Morph.draft_context_around_selection`, and `mark_range` in `selection.lua` so
  both model-facing spans are marked by the same code.
- A no-op / wholesale-deletion arm on the guard. A merge whose region equals the
  original selected text, or whose region is empty, is rejected and fed back with
  an explanation instead of applied. Both are what a model returns when it could
  not work out what a terse request meant, and applying either reads to the user as
  "the plugin did nothing".
- Prompt rules in `editing_regen.avanterules`: markers appear in both views and are
  never to be written out, the edit must land inside the selection and must be a
  real change, and a fragmentary request is to be interpreted rather than stalled on.
- An `AvanteInspectEdit` trace event for the wide draft context, so the span the
  model actually saw is inspectable next to the crop Morph got.

### Known trade-off

A request that legitimately asks to delete the selection ("remove this") now fails
after three attempts, because emptying the region is unconditionally rejected. This
was requested deliberately; if it bites, the check is `check_region_changed` in
`selection.lua` and only the `emptied` arm needs relaxing.

### Not done

None of the three padding values is exposed in `Config.selection`. They are
file-locals in `morph.lua` (`DRAFT_CONTEXT_LINES`, `WINDOW_CONTEXT_LINES`,
`APPLY_CONTEXT_LINES`).

### Verification

`tests/morph_spec.lua` passes (40), covering the fixed apply crop, the window, the
new draft context, and the ordering invariant between the three. The rest of the
suite is unchanged; `llm_tools_spec` errors in this environment for an unrelated
reason (it writes to `/tmp`). No live model runs yet -- the prompt and context
changes are untested against a real drafting model.
