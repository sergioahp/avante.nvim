# Regen-window protocol vs landmark drafts for the Morph selection edit

Date: 2026-07-18
Repo: avante.nvim (sergioahp fork, branch main)
Scope: the visual-selection fast-apply path (editing_morph -> draft model -> Morph -> guard),
specifically SMALL selections sitting next to near-identical lines -- the shape where the
drafting model emits a tiny ambiguous update block and ignores "output more lines".

## The idea under test

Instead of instructing the model to output more context (which it ignores), change the
protocol so the CLIENT dictates the drafted span:

- landmark (production today): model sees the big crop and emits an edit_file tool call
  (code_edit with `... existing code ...` landmarks). Update size is the model's choice.
- regen (new): the client picks a small edit window (selection +/- 3 lines, line-level),
  marks the selection inside it with `<selection>`/`</selection>` lines, shows the model
  the big crop plus that marked window, and asks for ONE thing: the whole window
  regenerated. The client wraps the returned window in landmarks itself and hands the big
  crop + constructed update to Morph. The model never sizes anything.

Crossed with crop snapping:
- fixed: production line-count crops (big = sel +/- max(6, sel_lines); small = sel +/- 3).
- ts: each crop boundary that lands inside a top-level treesitter node is snapped outward
  to the node boundary (grow cap 8/16 lines, else shrink past the partial node;
  tmp/snap_crops.lua via headless nvim; parsers: python, lua, typst all available).

Plus a mid-session addition (user idea): fuzzy-discard of model changes outside the
selection, tested in two places:
- regen_fd protocol: BEFORE Morph, align the regenerated window against the original
  (strip-level greedy match) and restore the original context lines, keeping only the
  model's selection region.
- fuzzy guard (counterfactual metric only): on every guard REJECT, would aligning Morph's
  merge against the big crop and restoring everything outside the selection have produced
  the exact expected region? Recorded as fd_correct, never applied.

## Setup

- Draft model: openai/gpt-oss-120b, reasoning medium, OpenRouter routed to
  deepinfra/together/nebius (allow_fallbacks off; groq/cerebras deliberately excluded).
- Apply model: morph/morph-v3-fast via OpenRouter.
- Guard + crop logic: faithful python ports of morph.scoped_region_change (with the
  trailing-ws fix) and morph.crop_around_selection.
- Correctness is EXACT: the confined region must equal a hand-written expected region
  (rstrip-level), not merely pass the guard.
- 5 cases x 6 cells x N=5 = 150 trials. Cases: py-cache (easy control), py-decoy-flags
  (commented-out lookalike block above the target), typst-table (single row selected
  among near-identical rows, mirrors the real typst failure), py-dup-blocks (selected
  line appears verbatim in 3 near-identical dicts; selection is in the second),
  lua-keymaps (one keymap line among a column of near-identical ones).

## Results (25 usable runs per cell)

| proto     | snap  | accept | correct | correct + fuzzy guard | window drift |
|-----------|-------|-------:|--------:|----------------------:|-------------:|
| landmark  | fixed |    96% |     96% |                   96% |            - |
| landmark  | ts    |    80% |     80% |                   80% |            - |
| regen     | fixed |   100% |    100% |                  100% |          52% |
| regen     | ts    |    92% |     92% |                  100% |          52% |
| regen_fd  | fixed |    88% |     88% |                  100% |          40% |
| regen_fd  | ts    |    96% |     96% |                  100% |          64% |

Per case (correct %):

| case           | lm-fixed | lm-ts | regen-fixed | regen-ts | fd-fixed | fd-ts |
|----------------|---------:|------:|------------:|---------:|---------:|------:|
| py-cache       |      100 |   100 |         100 |      100 |      100 |   100 |
| py-decoy-flags |      100 |   100 |         100 |       60 |       80 |    80 |
| typst-table    |      100 |   100 |         100 |      100 |      100 |   100 |
| py-dup-blocks  |       80 |     0 |         100 |      100 |       60 |   100 |
| lua-keymaps    |      100 |   100 |         100 |      100 |      100 |   100 |

Every failure was a guard REJECT; there were zero accepted-but-wrong merges in 150 trials.

## Failure anatomy

1. landmark + duplicates (the original complaint, reproduced): on py-dup-blocks the
   model drafts a tiny update and Morph lands it on the WRONG duplicate (the AUTH_POOL
   timeout above the selection) -- "changed line N (before/after)". 1/5 under the fixed
   crop; 5/5 under the ts crop, because the snapped big crop widens to cover all three
   near-identical blocks, giving Morph strictly more wrong anchors. Wider context makes
   the ambiguity WORSE, not better.
2. regen + ts snap on the decoy case (2/5): comment lines are individual top-level
   nodes, so the snap happily starts the window in the middle of the commented-out decoy
   block. The model then drifts on those decoy comment lines and Morph deletes part of
   the decoy run. The fixed 3-line window never touches the decoy block and never fails.
3. regen_fd (4 rejects across cells): restoring the original context lines re-introduces
   the blank line the model had (helpfully!) dropped right next to the landmark; a
   `}` + blank + `# ... existing code ...` tail makes morph-v3-fast mis-anchor and mangle
   the crop's first line indentation. The model's organic drift was benign -- Morph
   absorbs strip-level drift fine -- and "fixing" it pre-Morph is net harmful.

Window drift confirms the premise: in ~half of all regen trials the model could NOT copy
its 6 context lines byte-for-byte (usually collapsing double blank lines), even with the
instruction reduced to a single "copy exactly" rule. Asking for fidelity does not work;
tolerating and reconciling drift does.

## Fuzzy guard (the discard idea applied POST-Morph)

On the 6 regen-family rejects, aligning Morph's merge against the big crop and keeping
only the selection region would have recovered the EXACT expected region 6/6 times,
taking every regen cell to 100%. On the 8 landmark rejects it recovered the right region
0/8 times -- there Morph edited the wrong duplicate, so the aligned selection region is
simply unchanged and discarding would silently no-op the user's request. So a fuzzy
guard is only safe gated on the regen protocol (where the intended change is provably
inside the window); for landmark drafts the strict reject-and-retry loop remains correct.

## Recommendations for production (selection.lua)

1. Adopt the regen protocol for small selections: client-chosen window (sel +/- 3,
   line-level), `<selection>` markers, one-argument rewrite_window tool, client-side
   landmark wrapping, Morph on the existing big crop. It was the only 100% cell and it
   removes the instruction-following dependency entirely. Keep the landmark path for
   large selections where regenerating the window would be wasteful.
2. Do NOT snap crops with treesitter. It hurt both protocols (landmark: more duplicate
   anchors in scope; regen: windows starting inside comment runs) and helped nothing.
   The blank-line failure it was meant to fix is better handled post-hoc (see 3).
3. Do NOT reconcile window drift before Morph (no regen_fd). Morph absorbs strip-level
   drift; restoring blank lines next to landmarks actively breaks morph-v3-fast.
4. Optionally add the fuzzy guard as a rescue tier, regen path only: on strict-guard
   reject, align the merge against the crop (strip-level greedy, tolerate dropped
   lines), splice the aligned selection region, and fall back to reject-and-retry when
   alignment fails. In this bench it converts every regen reject into the exact
   expected edit.

## Limitations

- One draft model (gpt-oss-120b medium). The earlier A/B showed mini/nano behave very
  differently on landmark drafting; regen should if anything help weaker models more
  (the task is "retype this window"), but that is untested.
- N=5 per cell; the 92-100% differences are a handful of trials. The landmark-ts
  py-dup-blocks 0/5 and regen-fixed 25/25 are the only effects that look decisive.
- Single-attempt trials: production gives the drafting model 3 attempts with reject
  feedback, which would lift landmark numbers somewhat (at latency cost).
- The regen protocol as benched is line-level and single-window; sub-line selections
  ride along because the window always covers whole lines.

## Reproduction / artifacts

- tmp/regen_crop_bench.py -- the harness (now parallel with 429/5xx backoff; this run
  itself was sequential). Env: OPENROUTER_API_KEY, N, PAR.
- tmp/snap_crops.lua -- treesitter snap helper (headless nvim).
- tmp/regen-crop_gpt-oss-120b_N5_2026-07-18_14-56-59/ -- rows.json, per-trial
  update/merged text, log.jsonl (verbose, timestamped).

## Related tooling added this session (committed separately)

- :AvanteInspectEdit -- replays the last ephemeral selection edit (crop shown to the
  models, each edit_file attempt, Morph merge, guard verdict, reject feedback, final
  status) in a chat-style popup. Backed by lua/avante/edit_trace.lua; capture hooks in
  selection.lua.
- CLAUDE.md at the repo root: bench provider policy (no groq/cerebras), parallel
  requests with backoff, keys already in env, Morph via OpenRouter until further notice.
